import SXMBrowserCore

public struct AxisSelection: Codable, Equatable, Hashable, Sendable {
    public let xColumn: String
    public let yColumn: String

    public init(xColumn: String, yColumn: String) {
        self.xColumn = xColumn
        self.yColumn = yColumn
    }
}

public struct SpectroscopyAxisState: Equatable, Sendable {
    private var selectionsByGroupID: [String: AxisSelection]

    public init() {
        selectionsByGroupID = [:]
    }

    public func selection(forGroupID groupID: String) -> AxisSelection? {
        selectionsByGroupID[groupID]
    }

    @discardableResult
    public mutating func ensureSelection(
        forGroupID groupID: String,
        availableColumns: [String],
        preferredX: String,
        preferredY: String
    ) -> AxisSelection? {
        guard let fallbackX = canonicalColumn(
            matching: preferredX,
            in: availableColumns
        ) ?? availableColumns.first else {
            selectionsByGroupID.removeValue(forKey: groupID)
            return nil
        }
        let fallbackY = canonicalColumn(
            matching: preferredY,
            in: availableColumns
        ) ?? availableColumns.dropFirst().first
            ?? fallbackX
        let existing = selectionsByGroupID[groupID]
        let selection = AxisSelection(
            xColumn: existing.flatMap {
                canonicalColumn(matching: $0.xColumn, in: availableColumns)
            } ?? fallbackX,
            yColumn: existing.flatMap {
                canonicalColumn(matching: $0.yColumn, in: availableColumns)
            } ?? fallbackY
        )
        selectionsByGroupID[groupID] = selection
        return selection
    }

    @discardableResult
    public mutating func setXColumn(
        _ column: String,
        forGroupID groupID: String,
        availableColumns: [String],
        preferredX: String,
        preferredY: String
    ) -> Bool {
        guard let canonical = canonicalColumn(
            matching: column,
            in: availableColumns
        ), let current = ensureSelection(
            forGroupID: groupID,
            availableColumns: availableColumns,
            preferredX: preferredX,
            preferredY: preferredY
        ) else {
            return false
        }
        selectionsByGroupID[groupID] = AxisSelection(
            xColumn: canonical,
            yColumn: current.yColumn
        )
        return true
    }

    @discardableResult
    public mutating func setYColumn(
        _ column: String,
        forGroupID groupID: String,
        availableColumns: [String],
        preferredX: String,
        preferredY: String
    ) -> Bool {
        guard let canonical = canonicalColumn(
            matching: column,
            in: availableColumns
        ), let current = ensureSelection(
            forGroupID: groupID,
            availableColumns: availableColumns,
            preferredX: preferredX,
            preferredY: preferredY
        ) else {
            return false
        }
        selectionsByGroupID[groupID] = AxisSelection(
            xColumn: current.xColumn,
            yColumn: canonical
        )
        return true
    }

    public mutating func clear() {
        selectionsByGroupID.removeAll()
    }

    private func canonicalColumn(
        matching requestedColumn: String,
        in availableColumns: [String]
    ) -> String? {
        if availableColumns.contains(requestedColumn) {
            return requestedColumn
        }
        let normalizedRequested = SpectroscopyColumnSchema.normalize(
            requestedColumn
        )
        let matches = availableColumns.filter {
            SpectroscopyColumnSchema.normalize($0) == normalizedRequested
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}
