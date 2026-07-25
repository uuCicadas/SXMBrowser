public enum PanePlacement: Sendable, Equatable {
    case inline
    case overlay
}

public enum ResponsiveLayoutRegime: Sendable, Equatable {
    case compact
    case medium
    case expanded
}

public struct ResponsivePaneLayout: Sendable, Equatable {
    public static let mediumMinimumWidth = 900.0
    public static let expandedMinimumWidth = 1_200.0

    public let regime: ResponsiveLayoutRegime
    public let sidebarPlacement: PanePlacement
    public let inspectorPlacement: PanePlacement

    public init(containerWidth: Double) {
        if containerWidth >= Self.expandedMinimumWidth {
            regime = .expanded
            sidebarPlacement = .inline
            inspectorPlacement = .inline
        } else if containerWidth >= Self.mediumMinimumWidth {
            regime = .medium
            sidebarPlacement = .inline
            inspectorPlacement = .overlay
        } else {
            regime = .compact
            sidebarPlacement = .overlay
            inspectorPlacement = .overlay
        }
    }
}
