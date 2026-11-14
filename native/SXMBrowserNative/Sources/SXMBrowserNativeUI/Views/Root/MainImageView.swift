import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI
import UniformTypeIdentifiers

struct MainImageView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.selectionActionPresentation.placement
                == .actionBar {
                SelectionActionBar(model: model)
                    .transition(BrowserMotion.reveal(from: .top, reduceMotion: reduceMotion))
                Divider()
            }

            ZStack {
                browserContent
            }
            .browserMotion(.navigation, value: model.mode)
        }
        .browserMotion(.disclosure, value: model.selectionActionPresentation.placement)
        .background(AppTheme.page)
        .overlay {
            KeyboardCommandOverlay { command in
                switch command {
                case .move(
                    let direction,
                    let extendingSelection
                ):
                    model.moveSelectionForArrow(
                        direction,
                        extendingSelection:
                            extendingSelection
                    )
                    return true
                case .openSelection:
                    guard model.mode == .grid,
                          model.selectedFile != nil else {
                        return false
                    }
                    model.setMode(.single)
                    return true
                case .showGrid:
                    guard model.mode == .single else {
                        return false
                    }
                    model.setMode(.grid)
                    return true
                }
            }
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        switch model.browserContentState {
        case .openFolder:
            BrowserStateView(
                icon: "folder.badge.plus",
                title: "Open an SXM Folder",
                message:
                    "Choose a folder containing SXM files to begin."
            ) {
                Button("Open Folder") {
                    model.chooseFolder()
                }
                .buttonStyle(.borderedProminent)
            }

        case .loadingFolder:
            BrowserStateView(
                icon: "folder",
                title: "Scanning Folder",
                message:
                    "Reading SXM files, spectra, and saved metadata.",
                showsProgress: true
            )

        case .folderFailed(let message):
            BrowserStateView(
                icon: "exclamationmark.triangle",
                title: "Folder Could Not Be Read",
                message: message
            ) {
                Button("Retry") {
                    model.retryCurrentFolder()
                }
                .buttonStyle(.borderedProminent)
                Button("Open Another Folder") {
                    model.chooseFolder()
                }
                .buttonStyle(.bordered)
            }

        case .emptyFolder:
            BrowserStateView(
                icon: "tray",
                title: "No SXM Files",
                message:
                    "This folder contains no readable SXM files."
            ) {
                Button("Open Another Folder") {
                    model.chooseFolder()
                }
                .buttonStyle(.borderedProminent)
                Button("Retry") {
                    model.retryCurrentFolder()
                }
                .buttonStyle(.bordered)
            }

        case .noSearchResults:
            BrowserStateView(
                icon: "magnifyingglass",
                title: "No Matching Files",
                message:
                    "No SXM or associated DAT filename matches this search."
            ) {
                Button("Clear Search") {
                    model.clearFilenameSearch()
                }
                .buttonStyle(.borderedProminent)
            }

        case .noVisibleFiles:
            BrowserStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No Files in This View",
                message:
                    "Choose another tag or return to All files."
            )

        case .gridReady:
            GridBrowserView(model: model)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))

        case .noSelection:
            BrowserStateView(
                icon: "cursorarrow.click",
                title: "No File Selected",
                message:
                    "Select an SXM file, or return to Grid to browse."
            ) {
                Button("Show Grid") {
                    model.setMode(.grid)
                }
                .buttonStyle(.borderedProminent)
            }

        case .renderLoading,
             .renderReady,
             .renderFailed(_, _):
            SingleImageView(model: model)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
    }
}

struct BrowserToolbar: CustomizableToolbarContent {
    @Bindable var model: AppModel

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "sidebar", placement: .navigation) {
            Button {
                model.toggleSidebar()
            } label: {
                Label("File List", systemImage: "sidebar.left")
            }
            .help(model.actualSidebarVisible ? "Hide file list" : "Show file list")
        }
        .customizationBehavior(.disabled)

        ToolbarItem(id: "view-mode") {
            Picker("View mode", selection: Binding(
                get: { model.mode }, set: { model.setMode($0) }
            )) {
                Label("Grid", systemImage: "square.grid.2x2").tag(BrowserMode.grid)
                Label("Single", systemImage: "rectangle").tag(BrowserMode.single)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .frame(width: 84)
            .help("Switch between grid and single-image views")
        }

        ToolbarItem(id: "previous-file") {
            Button {
                model.stepSelection(-1)
            } label: {
                Label("Previous File", systemImage: "chevron.left")
            }
            .disabled(!model.canStepSelection(by: -1))
            .help("Previous visible file")
        }

        ToolbarItem(id: "next-file") {
            Button {
                model.stepSelection(1)
            } label: {
                Label("Next File", systemImage: "chevron.right")
            }
            .disabled(!model.canStepSelection(by: 1))
            .help("Next visible file")
        }

        ToolbarItem(id: "image-zoom") {
            ViewerZoomControls(model: model)
        }

        ToolbarItem(id: "file-position", placement: .status) {
            Text(model.selectedPositionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("File position")
        }

        ToolbarItem(id: "export-png") {
            Button {
                model.exportPNG()
            } label: {
                Label("Export PNG…", systemImage: "square.and.arrow.up")
            }
            .disabled(model.selectedImage == nil)
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "browser-actions", placement: .primaryAction) {
            browserActionsMenu
        }

        ToolbarItem(id: "stm-palette", placement: .primaryAction) {
            Menu {
                Picker("STM preview palette", selection: Binding(
                    get: { model.stmPreviewPalette },
                    set: { model.setSTMPreviewPalette($0) }
                )) {
                    ForEach(PaletteName.allCases, id: \.self) { palette in
                        Text(palette.label).tag(palette)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    PaletteSwatch(palette: model.stmPreviewPalette)
                    Text("STM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("STM preview palette: \(model.stmPreviewPalette.label)")
            .accessibilityLabel("STM preview palette")
        }

        ToolbarItem(id: "inspector", placement: .primaryAction) {
            Button {
                model.toggleInspector()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(model.actualInspectorVisible ? "Hide inspector" : "Show inspector")
        }
        .customizationBehavior(.disabled)
    }

    private var browserActionsMenu: some View {
        Menu {
            if model.mode == .single {
                Menu("Image Zoom") {
                    Button("Fit to Window") {
                        model.fitViewer()
                    }
                    .disabled(!model.canAdjustViewerTransform)

                    Button("Actual Size (100%)") {
                        model.showViewerActualSize()
                    }
                    .disabled(!model.canAdjustViewerTransform)

                    Divider()

                    Button("Zoom In") {
                        model.zoomViewerIn()
                    }
                    .disabled(!model.canZoomViewerIn)

                    Button("Zoom Out") {
                        model.zoomViewerOut()
                    }
                    .disabled(!model.canZoomViewerOut)

                    Divider()

                    ForEach(
                        viewerZoomPresetScales,
                        id: \.self
                    ) { scale in
                        Button(
                            viewerZoomPercentageLabel(
                                for: scale
                            )
                        ) {
                            model.setViewerScale(scale)
                        }
                        .disabled(
                            !model.canAdjustViewerTransform
                        )
                    }
                }

                Divider()
            }

            if model.mode == .grid {
                Picker(
                    "Grid density",
                    selection: $model.gridDensity
                ) {
                    ForEach(GridDensity.allCases) { density in
                        Text(density.label).tag(density)
                    }
                }

                Button {
                    model.toggleGridSpectroscopyCards()
                } label: {
                    Label(
                        model.showsGridSpectroscopyCards
                            ? "Hide Spectrum Cards in Grid"
                            : "Show Spectrum Cards in Grid",
                        systemImage:
                            "waveform.path.ecg.rectangle"
                    )
                }
                .disabled(model.spectra.isEmpty)

                Divider()
            }

            Button {
                model.exportPNG()
            } label: {
                Label(
                    "Export PNG…",
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(model.selectedImage == nil)

            Button {
                model.revealSelectedFilesInFinder()
            } label: {
                Label(
                    "Show in Finder",
                    systemImage: "folder"
                )
            }
            .disabled(model.selectedCount == 0)

            Divider()

            Button {
                model.resetLayout()
            } label: {
                Label("Reset Layout", systemImage: "rectangle.3.group")
            }

            if model.selectionActionPresentation.placement
                == .overflow {
                Divider()
                Button(role: .destructive) {
                    model.deleteSelectedFiles()
                } label: {
                    Label(
                        "Move to Trash…",
                        systemImage: "trash"
                    )
                }
                .disabled(!model.canDeleteSelection)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More browser actions")
        .accessibilityLabel("More browser actions")
    }
}

/// Compact gradient chip that shows the current STM preview palette at a
/// glance; the surrounding menu lists every palette. Drawn as an NSImage so
/// toolbar menu labels keep the bitmap instead of collapsing it to text.
private struct PaletteSwatch: View {
    let palette: PaletteName

    var body: some View {
        Image(nsImage: PaletteSwatchRenderer.image(for: palette))
            .renderingMode(.original)
            .resizable()
            .frame(width: 42, height: 13)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor),
                        lineWidth: 0.5
                    )
            )
            .accessibilityHidden(true)
    }
}

private enum PaletteSwatchRenderer {
    static func image(for palette: PaletteName) -> NSImage {
        let pointSize = NSSize(width: 42, height: 13)
        let pixelWidth = 84
        let pixelHeight = 26
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return NSImage(size: pointSize)
        }
        let stops = PaletteStore.shared.stops(for: palette)
        let colors = stops.map {
            CGColor(
                srgbRed: CGFloat($0.r),
                green: CGFloat($0.g),
                blue: CGFloat($0.b),
                alpha: 1
            )
        }
        let locations = stops.map { CGFloat($0.position) }
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: colors as CFArray,
            locations: locations
        ) else {
            return NSImage(size: pointSize)
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(pixelHeight) / 2),
            end: CGPoint(x: CGFloat(pixelWidth), y: CGFloat(pixelHeight) / 2),
            options: []
        )
        guard let cgImage = context.makeImage() else {
            return NSImage(size: pointSize)
        }
        let image = NSImage(cgImage: cgImage, size: pointSize)
        image.isTemplate = false
        return image
    }
}

private let viewerZoomPresetScales = [
    0.25,
    0.5,
    1,
    2,
    4,
    8,
    16,
]

private func viewerZoomPercentageLabel(
    for scale: Double
) -> String {
    "\(Int((scale * 100).rounded()))%"
}

private struct ViewerZoomControls: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("Zoom In") {
                model.zoomViewerIn()
            }
            .disabled(!model.canZoomViewerIn)

            Button("Zoom Out") {
                model.zoomViewerOut()
            }
            .disabled(!model.canZoomViewerOut)

            Divider()

            Button("Fit to Window") {
                model.fitViewer()
            }
            .disabled(!model.canAdjustViewerTransform)

            Button("Actual Size (100%)") {
                model.showViewerActualSize()
            }
            .disabled(!model.canAdjustViewerTransform)

            Divider()

            ForEach(
                viewerZoomPresetScales,
                id: \.self
            ) { scale in
                Button(
                    viewerZoomPercentageLabel(
                        for: scale
                    )
                ) {
                    model.setViewerScale(scale)
                }
                .disabled(!model.canAdjustViewerTransform)
            }
        } label: {
            Text(model.viewerZoomLabel)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 62)
        }
        .menuStyle(.borderlessButton)
        .disabled(!model.canAdjustViewerTransform)
        .fixedSize()
        .help("Choose image zoom")
        .accessibilityLabel("Image zoom")
        .accessibilityValue(model.viewerZoomLabel)
    }
}

private struct SelectionActionBar: View {
    let model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                selectionSummary.fixedSize()
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    selectionActions
                }
                .fixedSize()
            }

            HStack(spacing: 10) {
                selectionSummary
                Spacer(minLength: 8)
                Menu {
                    selectionActions
                } label: {
                    Label("Selection Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.separator).frame(height: 1)
        }
    }

    private var selectionSummary: some View {
        Label("\(model.selectedCount) selected", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .accessibilityLabel("\(model.selectedCount) files selected")
    }

    @ViewBuilder
    private var selectionActions: some View {
        Menu {
            if model.tags.isEmpty {
                Button("New Tag…") {
                    model.promptForNewTagForSelection()
                }
            } else {
                ForEach(model.tags) { tag in
                    Button(tag.name) {
                        model.addTagToSelection(tag.id)
                    }
                }
                Divider()
                Button("New Tag…") {
                    model.promptForNewTagForSelection()
                }
            }
        } label: {
            Label("Add Tag", systemImage: "tag")
        }
        .disabled(!model.canModifyTags)

        Menu {
            let removableTags = model.removableTagsForSelection()
            if removableTags.isEmpty {
                Text("No Tags")
            } else {
                ForEach(removableTags) { tag in
                    Button(tag.name) {
                        model.removeTagFromSelection(tag.id)
                    }
                }
            }
        } label: {
            Label("Remove Tag", systemImage: "tag.slash")
        }
        .disabled(
            !model.canModifyTags
                || model.removableTagsForSelection().isEmpty
        )

        Button {
            model.revealSelectedFilesInFinder()
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .help("Reveal selected files in Finder")

        Button(role: .destructive) {
            model.deleteSelectedFiles()
        } label: {
            Label("Move to Trash…", systemImage: "trash")
        }
        .disabled(!model.canDeleteSelection)
        .help("Move selected visible files to the system Trash")
    }
}

struct BrowserStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    var showsProgress = false
    @ViewBuilder let actions: Actions

    init(
        icon: String,
        title: String,
        message: String,
        showsProgress: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.showsProgress = showsProgress
        self.actions = actions()
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
                        .frame(width: 56, height: 56)
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                actions
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.elevatedCard(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
                )
        )
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.stage)
    }
}

extension BrowserStateView where Actions == EmptyView {
    init(
        icon: String,
        title: String,
        message: String,
        showsProgress: Bool = false
    ) {
        self.init(
            icon: icon,
            title: title,
            message: message,
            showsProgress: showsProgress
        ) {
            EmptyView()
        }
    }
}

struct KeyboardCommandOverlay: NSViewRepresentable {
    let onCommand: (BrowserKeyboardCommand) -> Bool

    func makeNSView(context: Context) -> KeyboardCommandCatcherView {
        let view = KeyboardCommandCatcherView()
        view.onCommand = onCommand
        return view
    }

    func updateNSView(
        _ nsView: KeyboardCommandCatcherView,
        context: Context
    ) {
        nsView.onCommand = onCommand
    }

    static func dismantleNSView(
        _ nsView: KeyboardCommandCatcherView,
        coordinator: ()
    ) {
        nsView.stopMonitoring()
    }
}

@MainActor
final class KeyboardCommandCatcherView: NSView {
    var onCommand: ((BrowserKeyboardCommand) -> Bool)?
    private var eventMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            installEventMonitor()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isEventForThisWindow(event) else {
            return false
        }
        guard let command = BrowserKeyboardRouting.command(
            forMacVirtualKeyCode: event.keyCode,
            hasCommandModifiers:
                hasCommandModifiers(event),
            isShiftPressed:
                event.modifierFlags.contains(.shift),
            interactiveControlHasFocus:
                interactiveControlHasFocus
        ) else {
            return false
        }
        return onCommand?(command) ?? false
    }

    private func isEventForThisWindow(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        if let eventWindow = event.window {
            return eventWindow === window
        }
        return NSApp.keyWindow === window
    }

    private func hasCommandModifiers(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        return !modifiers.isEmpty
    }

    private var interactiveControlHasFocus: Bool {
        guard let firstResponder =
            window?.firstResponder as? NSView else {
            return false
        }
        var view: NSView? = firstResponder
        while let current = view {
            if current is NSTextView
                || current is NSControl {
                return true
            }
            view = current.superview
        }
        return false
    }

}

