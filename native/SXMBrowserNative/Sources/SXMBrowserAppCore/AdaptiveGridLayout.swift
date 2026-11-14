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

    public static func targetFileID<ID: Hashable>(
        from currentID: ID?,
        direction: GridNavigationDirection,
        columnCount: Int,
        itemFileIDs: [ID?]
    ) -> ID? {
        guard !itemFileIDs.isEmpty else { return nil }
        let columns = max(1, columnCount)

        guard let currentID,
              let currentIndex = itemFileIDs.firstIndex(where: { $0 == currentID }) else {
            switch direction {
            case .left, .up:
                return itemFileIDs.last { $0 != nil } ?? nil
            case .right, .down:
                return itemFileIDs.first { $0 != nil } ?? nil
            }
        }

        switch direction {
        case .left:
            guard currentIndex > 0 else { return nil }
            for index in stride(from: currentIndex - 1, through: 0, by: -1) {
                if let candidate = itemFileIDs[index] {
                    return candidate
                }
            }
            return nil

        case .right:
            guard currentIndex + 1 < itemFileIDs.count else { return nil }
            for index in (currentIndex + 1)..<itemFileIDs.count {
                if let candidate = itemFileIDs[index] {
                    return candidate
                }
            }
            return nil

        case .up, .down:
            let totalRows = (itemFileIDs.count + columns - 1) / columns
            let currentRow = currentIndex / columns
            let currentCol = currentIndex % columns
            let rowStep = direction == .up ? -1 : 1
            var row = currentRow + rowStep

            while row >= 0 && row < totalRows {
                let rowStart = row * columns
                let rowEnd = min(itemFileIDs.count, rowStart + columns)
                let preferredIndex = rowStart + currentCol
                if preferredIndex < rowEnd, let candidate = itemFileIDs[preferredIndex] {
                    return candidate
                }

                // If that grid slot holds a non-SXM card (e.g. a spectroscopy card),
                // snap to the closest selectable SXM card on the same visual row.
                var bestIndex: Int?
                var bestDistance = Int.max
                for index in rowStart..<rowEnd {
                    guard itemFileIDs[index] != nil else { continue }
                    let distance = abs((index - rowStart) - currentCol)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = index
                    }
                }
                if let bestIndex, let candidate = itemFileIDs[bestIndex] {
                    return candidate
                }

                row += rowStep
            }
            return nil
        }
    }
}
