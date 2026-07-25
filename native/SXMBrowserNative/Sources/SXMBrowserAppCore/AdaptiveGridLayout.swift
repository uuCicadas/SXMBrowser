public enum GridDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case comfortable
    case large

    public var id: String {
        rawValue
    }

    public var minimumCardWidth: Double {
        switch self {
        case .compact:
            120
        case .comfortable:
            160
        case .large:
            220
        }
    }

    public static func migrating(
        legacyColumnCount: Int
    ) -> GridDensity {
        switch legacyColumnCount {
        case 2:
            .large
        case 3...4:
            .comfortable
        case 5...8:
            .compact
        default:
            .comfortable
        }
    }
}

public struct AdaptiveGridMetrics: Sendable, Equatable {
    public static let defaultHorizontalPadding = 18.0
    public static let defaultSpacing = 14.0
    public static let maximumColumnCount = 10_000

    public let density: GridDensity
    public let minimumCardWidth: Double
    public let horizontalPadding: Double
    public let spacing: Double
    public let columnCount: Int

    public init(
        containerWidth: Double,
        density: GridDensity,
        horizontalPadding: Double = Self.defaultHorizontalPadding,
        spacing: Double = Self.defaultSpacing
    ) {
        self.density = density
        minimumCardWidth = density.minimumCardWidth
        self.horizontalPadding = horizontalPadding
        self.spacing = spacing

        guard containerWidth.isFinite,
              horizontalPadding.isFinite,
              horizontalPadding >= 0,
              spacing.isFinite,
              spacing >= 0,
              containerWidth > 0 else {
            columnCount = 1
            return
        }

        let usableWidth = max(
            0,
            containerWidth - 2 * horizontalPadding
        )
        let rawCount = (usableWidth + spacing)
            / (minimumCardWidth + spacing)
        let boundedCount = min(
            Double(Self.maximumColumnCount),
            max(1, rawCount.rounded(.down))
        )
        columnCount = Int(boundedCount)
    }
}

public enum GridNavigationDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum AdaptiveGridNavigation {
    public static func selectionDelta(
        for direction: GridNavigationDirection,
        columnCount: Int
    ) -> Int {
        let columns = max(1, columnCount)
        switch direction {
        case .left:
            return -1
        case .right:
            return 1
        case .up:
            return -columns
        case .down:
            return columns
        }
    }
}
