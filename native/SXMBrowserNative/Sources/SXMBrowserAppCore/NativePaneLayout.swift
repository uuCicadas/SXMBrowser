import Foundation

public enum NativePanePriority: Sendable {
    case sidebar
    case inspector
}

/// Fits native split panes without changing the user's visibility or width preferences.
public struct NativePaneLayout: Sendable, Equatable {
    public static let minimumContentWidth = 320.0
    public static let sidebarWidthRange = 220.0...460.0
    public static let inspectorWidthRange = 260.0...430.0

    public let showsSidebar: Bool
    public let showsInspector: Bool
    public let sidebarWidth: Double
    public let inspectorWidth: Double

    public init(
        containerWidth: Double,
        wantsSidebar: Bool,
        wantsInspector: Bool,
        preferredSidebarWidth: Double,
        preferredInspectorWidth: Double,
        priority: NativePanePriority = .sidebar,
        dividerThickness: Double = 1
    ) {
        let available = containerWidth.isFinite ? max(0, containerWidth) : 0
        let divider = dividerThickness.isFinite ? max(0, dividerThickness) : 1
        var sidebar = Self.clamp(preferredSidebarWidth, to: Self.sidebarWidthRange, fallback: 300)
        var inspector = Self.clamp(preferredInspectorWidth, to: Self.inspectorWidthRange, fallback: 320)
        let bothFit = available >= Self.minimumContentWidth
            + Self.sidebarWidthRange.lowerBound + Self.inspectorWidthRange.lowerBound
            + 2 * divider

        if wantsSidebar && wantsInspector && bothFit {
            let budget = available - Self.minimumContentWidth - 2 * divider
            var excess = max(0, sidebar + inspector - budget)
            if priority == .sidebar {
                let reduction = min(excess, inspector - Self.inspectorWidthRange.lowerBound)
                inspector -= reduction
                excess -= reduction
                sidebar -= min(excess, sidebar - Self.sidebarWidthRange.lowerBound)
            } else {
                let reduction = min(excess, sidebar - Self.sidebarWidthRange.lowerBound)
                sidebar -= reduction
                excess -= reduction
                inspector -= min(excess, inspector - Self.inspectorWidthRange.lowerBound)
            }
            showsSidebar = true
            showsInspector = true
        } else {
            let sidebarFits = wantsSidebar && available >= Self.minimumContentWidth
                + Self.sidebarWidthRange.lowerBound + divider
            let inspectorFits = wantsInspector && available >= Self.minimumContentWidth
                + Self.inspectorWidthRange.lowerBound + divider
            showsSidebar = sidebarFits && (priority == .sidebar || !inspectorFits)
            showsInspector = inspectorFits && !showsSidebar
            if showsSidebar {
                sidebar = min(sidebar, available - Self.minimumContentWidth - divider)
            }
            if showsInspector {
                inspector = min(inspector, available - Self.minimumContentWidth - divider)
            }
        }
        sidebarWidth = sidebar
        inspectorWidth = inspector
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback))
    }
}
