import AppKit
import SXMBrowserAppCore
import SwiftUI

/// Shared timing for native pane collapse/expand. A slightly longer,
/// decelerating curve reads smoother than the previous 0.20s ease-in-ease-out.
private enum PaneAnimation {
    static let duration: TimeInterval = 0.26
}

struct NativeBrowserSplitView<Sidebar: View, Content: View, Inspector: View>: NSViewControllerRepresentable {
    @Binding var sidebarVisible: Bool
    @Binding var inspectorVisible: Bool
    @Binding var sidebarWidth: CGFloat
    @Binding var inspectorWidth: CGFloat
    let sidebarVisibilityRequestID: UUID?
    let inspectorVisibilityRequestID: UUID?
    let onVisibilityChanged: (Bool, Bool) -> Void
    let onWidthsChanged: () -> Void
    let onLayoutInteractionChanged: (Bool) -> Void
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var content: () -> Content
    @ViewBuilder var inspector: () -> Inspector

    func makeNSViewController(context: Context) -> NativeBrowserSplitController {
        let controller = NativeBrowserSplitController()
        updateNSViewController(controller, context: context)
        return controller
    }

    func updateNSViewController(_ controller: NativeBrowserSplitController, context: Context) {
        controller.update(
            sidebar: AnyView(sidebar()),
            content: AnyView(content()),
            inspector: AnyView(inspector()),
            wantsSidebar: sidebarVisible,
            wantsInspector: inspectorVisible,
            sidebarWidth: sidebarWidth,
            inspectorWidth: inspectorWidth,
            sidebarRequest: sidebarVisibilityRequestID,
            inspectorRequest: inspectorVisibilityRequestID,
            onVisibilityChanged: onVisibilityChanged,
            onUserSidebarChange: { sidebarVisible = $0 },
            onUserInspectorChange: { inspectorVisible = $0 },
            onWidthsChanged: { left, right in
                sidebarWidth = left
                inspectorWidth = right
                onWidthsChanged()
            },
            onLayoutInteractionChanged: onLayoutInteractionChanged
        )
    }
}

/// Uses AppKit's sidebar/inspector split items for native dividers and pane behavior.
@MainActor
final class NativeBrowserSplitController: NSSplitViewController {
    private let sidebarHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let contentHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let inspectorHost = NSHostingController(rootView: AnyView(EmptyView()))
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var wantsSidebar = true
    private var wantsInspector = true
    private var preferredSidebarWidth: CGFloat = 300
    private var preferredInspectorWidth: CGFloat = 320
    private var sidebarRequest: UUID?
    private var inspectorRequest: UUID?
    private var priority: NativePanePriority = .sidebar
    private var applyingLayout = false
    private var animatedLayout: NativePaneLayout?
    private var layoutAnimationID: UUID?
    private var animationContainerWidth: CGFloat = 0
    private var dragStartVisibility: (Bool, Bool)?
    private var draggedDividerIndex: Int?
    private var dragStartWidths: (CGFloat, CGFloat)?
    private var lastLayout: NativePaneLayout?
    private var pendingVisibility: (Bool, Bool)?
    private var lastReportedVisibility: (Bool, Bool)?
    private var onVisibilityChanged: ((Bool, Bool) -> Void)?
    private var onUserSidebarChange: ((Bool) -> Void)?
    private var onUserInspectorChange: ((Bool) -> Void)?
    private var onWidthsChanged: ((CGFloat, CGFloat) -> Void)?
    private var onLayoutInteractionChanged: ((Bool) -> Void)?
    private var pendingPaneViews: (sidebar: AnyView, content: AnyView, inspector: AnyView)?

    override func loadView() {
        let nativeSplit = BrowserDividerSplitView()
        nativeSplit.isVertical = true
        nativeSplit.dividerStyle = .thin
        nativeSplit.onDragBegin = { [weak self] dividerIndex in
            guard let self else { return }
            self.finishLayoutAnimation()
            self.dragStartVisibility = (!self.sidebarItem.isCollapsed, !self.inspectorItem.isCollapsed)
            self.draggedDividerIndex = dividerIndex
            self.dragStartWidths = (self.sidebarHost.view.frame.width, self.inspectorHost.view.frame.width)
            self.reportLayoutInteraction(true)
        }
        nativeSplit.onDragEnd = { [weak self] in self?.finishDividerDrag() }
        splitView = nativeSplit
        super.loadView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for host in [sidebarHost, contentHost, inspectorHost] {
            host.sizingOptions = []
        }
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = CGFloat(NativePaneLayout.sidebarWidthRange.lowerBound)
        sidebarItem.maximumThickness = CGFloat(NativePaneLayout.sidebarWidthRange.upperBound)
        sidebarItem.holdingPriority = .init(rawValue: 251)
        sidebarItem.canCollapseFromWindowResize = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.allowsFullHeightLayout = false

        let contentItem = NSSplitViewItem(viewController: contentHost)
        contentItem.minimumThickness = CGFloat(NativePaneLayout.minimumContentWidth)
        contentItem.holdingPriority = .init(rawValue: 249)

        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = CGFloat(NativePaneLayout.inspectorWidthRange.lowerBound)
        inspectorItem.maximumThickness = CGFloat(NativePaneLayout.inspectorWidthRange.upperBound)
        inspectorItem.holdingPriority = .init(rawValue: 250)
        inspectorItem.canCollapseFromWindowResize = true
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspectorItem.allowsFullHeightLayout = false

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
    }

    func update(
        sidebar: AnyView, content: AnyView, inspector: AnyView,
        wantsSidebar: Bool, wantsInspector: Bool,
        sidebarWidth: CGFloat, inspectorWidth: CGFloat,
        sidebarRequest: UUID?, inspectorRequest: UUID?,
        onVisibilityChanged: @escaping (Bool, Bool) -> Void,
        onUserSidebarChange: @escaping (Bool) -> Void,
        onUserInspectorChange: @escaping (Bool) -> Void,
        onWidthsChanged: @escaping (CGFloat, CGFloat) -> Void,
        onLayoutInteractionChanged: @escaping (Bool) -> Void
    ) {
        _ = view
        let views = (sidebar: sidebar, content: content, inspector: inspector)
        if layoutAnimationID == nil {
            install(views)
        } else {
            // Replacing the hosting roots mid-animation forces a full SwiftUI
            // rebuild on the animation path; install them once it settles.
            pendingPaneViews = views
        }
        let hasVisibilityRequest = lastLayout != nil && (
            (sidebarRequest != nil && sidebarRequest != self.sidebarRequest)
                || (inspectorRequest != nil && inspectorRequest != self.inspectorRequest)
        )
        if sidebarRequest == nil && inspectorRequest == nil {
            priority = .sidebar
        } else {
            if sidebarRequest != self.sidebarRequest && wantsSidebar { priority = .sidebar }
            if inspectorRequest != self.inspectorRequest && wantsInspector { priority = .inspector }
        }
        self.sidebarRequest = sidebarRequest
        self.inspectorRequest = inspectorRequest
        self.wantsSidebar = wantsSidebar
        self.wantsInspector = wantsInspector
        preferredSidebarWidth = sidebarWidth
        preferredInspectorWidth = inspectorWidth
        self.onVisibilityChanged = onVisibilityChanged
        self.onUserSidebarChange = onUserSidebarChange
        self.onUserInspectorChange = onUserInspectorChange
        self.onWidthsChanged = onWidthsChanged
        self.onLayoutInteractionChanged = onLayoutInteractionChanged
        applyLayout(animated: hasVisibilityRequest)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyLayout()
    }

    private func applyLayout(animated: Bool = false) {
        guard !applyingLayout, dragStartVisibility == nil, isViewLoaded,
              splitView.bounds.width > 0 else { return }
        let layout = NativePaneLayout(
            containerWidth: Double(splitView.bounds.width),
            wantsSidebar: wantsSidebar,
            wantsInspector: wantsInspector,
            preferredSidebarWidth: Double(preferredSidebarWidth),
            preferredInspectorWidth: Double(preferredInspectorWidth),
            priority: priority,
            dividerThickness: Double(splitView.dividerThickness)
        )
        // AppKit lays out every frame of a collapse. Do not fight those intermediate frames.
        guard animatedLayout != layout || animationContainerWidth != splitView.bounds.width
            || view.inLiveResize else { return }
        guard lastLayout != layout || layoutAnimationID != nil
            || sidebarItem.isCollapsed == layout.showsSidebar
            || inspectorItem.isCollapsed == layout.showsInspector else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        let changesVisibility = sidebarItem.isCollapsed == layout.showsSidebar
            || inspectorItem.isCollapsed == layout.showsInspector
        let shouldAnimate = animated && changesVisibility && layoutAnimationID == nil
            && view.window != nil && !view.inLiveResize
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lastLayout = layout

        if shouldAnimate {
            let animationID = UUID()
            layoutAnimationID = animationID
            animatedLayout = layout
            animationContainerWidth = splitView.bounds.width
            reportLayoutInteraction(true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PaneAnimation.duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                setPaneVisibility(layout, animated: true)
            } completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.layoutAnimationID == animationID else { return }
                    self.layoutAnimationID = nil
                    self.animatedLayout = nil
                    self.installPendingPaneViews()
                    self.lastLayout = nil
                    self.applyLayout()
                    self.reportLayoutInteraction(false)
                }
            }
            // Commands should toggle the destination state even while the pane is moving.
            reportVisibility(layout.showsSidebar, layout.showsInspector)
            return
        }

        if layoutAnimationID != nil {
            // A repeated command or a resize takes precedence over an in-flight animation.
            layoutAnimationID = nil
            animatedLayout = nil
            installPendingPaneViews()
            reportLayoutInteraction(false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                setPaneVisibility(layout, animated: false)
            }
        }
        setPaneVisibility(layout, animated: false)
        splitView.layoutSubtreeIfNeeded()
        if layout.showsSidebar,
           abs(sidebarHost.view.frame.width - CGFloat(layout.sidebarWidth)) > 0.5 {
            splitView.setPosition(CGFloat(layout.sidebarWidth), ofDividerAt: 0)
        }
        if layout.showsInspector,
           abs(inspectorHost.view.frame.width - CGFloat(layout.inspectorWidth)) > 0.5 {
            splitView.setPosition(
                splitView.bounds.width - CGFloat(layout.inspectorWidth),
                ofDividerAt: 1
            )
        }
        reportVisibility(!sidebarItem.isCollapsed, !inspectorItem.isCollapsed)
    }

    private func setPaneVisibility(_ layout: NativePaneLayout, animated: Bool) {
        let sidebar = animated ? sidebarItem.animator() : sidebarItem!
        let inspector = animated ? inspectorItem.animator() : inspectorItem!
        // Collapse first, so revealing the requested pane never demands a wider window.
        if !layout.showsSidebar { sidebar.isCollapsed = true }
        if !layout.showsInspector { inspector.isCollapsed = true }
        if layout.showsSidebar { sidebar.isCollapsed = false }
        if layout.showsInspector { inspector.isCollapsed = false }
    }

    private func finishLayoutAnimation() {
        guard layoutAnimationID != nil else { return }
        layoutAnimationID = nil
        animatedLayout = nil
        installPendingPaneViews()
        reportLayoutInteraction(false)
        lastLayout = nil
        applyLayout()
    }

    private func install(
        _ views: (sidebar: AnyView, content: AnyView, inspector: AnyView)
    ) {
        sidebarHost.rootView = views.sidebar
        contentHost.rootView = views.content
        inspectorHost.rootView = views.inspector
    }

    private func installPendingPaneViews() {
        guard let views = pendingPaneViews else { return }
        pendingPaneViews = nil
        install(views)
    }

    private func reportLayoutInteraction(_ animating: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onLayoutInteractionChanged?(animating)
        }
    }

    private func finishDividerDrag() {
        guard let start = dragStartVisibility,
              let startWidths = dragStartWidths,
              let dividerIndex = draggedDividerIndex else { return }
        dragStartVisibility = nil
        dragStartWidths = nil
        draggedDividerIndex = nil
        let left = !sidebarItem.isCollapsed
        let right = !inspectorItem.isCollapsed
        let changedLeftVisibility = dividerIndex == 0 && start.0 != left
        let changedRightVisibility = dividerIndex == 1 && start.1 != right
        let changedLeftWidth = dividerIndex == 0 && left
            && (changedLeftVisibility || abs(sidebarHost.view.frame.width - startWidths.0) > 0.5)
        let changedRightWidth = dividerIndex == 1 && right
            && (changedRightVisibility || abs(inspectorHost.view.frame.width - startWidths.1) > 0.5)
        // Only the pane beside the grabbed divider expresses a user width preference.
        // Its sibling may also resize to satisfy constraints, but that remains temporary.
        if changedLeftWidth { preferredSidebarWidth = sidebarHost.view.frame.width }
        if changedRightWidth { preferredInspectorWidth = inspectorHost.view.frame.width }
        if changedLeftVisibility {
            wantsSidebar = left
            if left { priority = .sidebar }
        }
        if changedRightVisibility {
            wantsInspector = right
            if right { priority = .inspector }
        }
        let widths = (preferredSidebarWidth, preferredInspectorWidth)
        // Publishing bindings after the AppKit tracking loop avoids SwiftUI update reentrancy.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if changedLeftVisibility { self.onUserSidebarChange?(left) }
            if changedRightVisibility { self.onUserInspectorChange?(right) }
            if changedLeftWidth || changedRightWidth {
                self.onWidthsChanged?(widths.0, widths.1)
            }
        }
        lastLayout = nil
        reportVisibility(left, right)
        applyLayout()
        reportLayoutInteraction(false)
    }

    private func reportVisibility(_ left: Bool, _ right: Bool) {
        pendingVisibility = (left, right)
        DispatchQueue.main.async { [weak self] in
            guard let self, let value = self.pendingVisibility else { return }
            self.pendingVisibility = nil
            if let previous = self.lastReportedVisibility,
               previous.0 == value.0, previous.1 == value.1 { return }
            self.lastReportedVisibility = value
            self.onVisibilityChanged?(value.0, value.1)
        }
    }
}

@MainActor
private final class BrowserDividerSplitView: NSSplitView {
    var onDragBegin: ((Int) -> Void)?
    var onDragEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let dividerIndex = dividerIndex(at: point) else {
            super.mouseDown(with: event)
            return
        }
        onDragBegin?(dividerIndex)
        defer { onDragEnd?() }
        super.mouseDown(with: event)
    }

    func dividerIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point), arrangedSubviews.count > 1 else { return nil }
        // Thin system dividers have a wider grab area than their painted line.
        // The two candidates are separated by the main pane's minimum width.
        return (0..<(arrangedSubviews.count - 1)).compactMap { index -> (Int, CGFloat)? in
            let leading = arrangedSubviews[index].frame.maxX
            let trailing = arrangedSubviews[index + 1].frame.minX
            let center = (leading + trailing) / 2
            let distance = abs(point.x - center)
            return distance <= max(12, dividerThickness) ? (index, distance) : nil
        }.min { $0.1 < $1.1 }?.0
    }
}
