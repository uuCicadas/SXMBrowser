import AppKit
import Foundation

public enum SpectroscopyKind: String, Codable, Sendable {
    case z
    case bias
    case other

    public var label: String {
        switch self {
        case .z: "Z"
        case .bias: "Bias"
        case .other: "Spectrum"
        }
    }
}

public enum SpectroscopyExperimentIdentity {
    public static func make(
        experiment: String?,
        fallbackKind kind: SpectroscopyKind
    ) -> String {
        let normalized = (experiment ?? "")
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return normalized.isEmpty ? kind.rawValue : normalized
    }
}

public struct SpectroscopyColumnSchema: Codable, Hashable, Sendable {
    public let normalizedColumns: [String]
    public let fingerprint: String

    public init(columns: [String]) {
        let normalizedColumns = columns.map(Self.normalize)
        self.normalizedColumns = normalizedColumns
        self.fingerprint = Self.makeFingerprint(for: normalizedColumns)
    }

    public static func normalize(_ column: String) -> String {
        column
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func makeFingerprint(for columns: [String]) -> String {
        let identity = columns
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

public struct SpectroscopyGroupKey: Codable, Hashable, Sendable {
    public let kind: SpectroscopyKind
    public let experimentIdentity: String
    public let columnSchema: SpectroscopyColumnSchema
    public let fingerprint: String

    public init(
        kind: SpectroscopyKind,
        experiment: String?,
        columnSchema: SpectroscopyColumnSchema
    ) {
        self.kind = kind
        self.experimentIdentity = SpectroscopyExperimentIdentity.make(
            experiment: experiment,
            fallbackKind: kind
        )
        self.columnSchema = columnSchema
        self.fingerprint = deterministicFingerprint(
            [
                kind.rawValue,
                experimentIdentity,
                columnSchema.fingerprint,
            ]
        )
    }

    public init(
        kind: SpectroscopyKind,
        columnSchema: SpectroscopyColumnSchema
    ) {
        self.init(
            kind: kind,
            experiment: nil,
            columnSchema: columnSchema
        )
    }
}

public struct SpectroscopyCurve: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let filename: String
    public let modifiedTime: Date
    public let columns: [String]
    public let valuesByColumn: [String: [Double]]
    public let x: [Double]
    public let y: [Double]

    public init(
        id: UUID = UUID(),
        filename: String,
        modifiedTime: Date,
        columns: [String],
        valuesByColumn: [String: [Double]],
        x: [Double],
        y: [Double]
    ) {
        self.id = id
        self.filename = filename
        self.modifiedTime = modifiedTime
        self.columns = columns
        self.valuesByColumn = valuesByColumn
        self.x = x
        self.y = y
    }

    public var columnSchema: SpectroscopyColumnSchema {
        SpectroscopyColumnSchema(columns: columns)
    }

    public func points(xColumn: String, yColumn: String) -> [(x: Double, y: Double)]? {
        guard let xKey = columnKey(matching: xColumn),
              let yKey = columnKey(matching: yColumn),
              let xs = valuesByColumn[xKey],
              let ys = valuesByColumn[yKey] else {
            return nil
        }
        return Array(zip(xs, ys)).map { (x: $0.0, y: $0.1) }
    }

    fileprivate func points(xColumnIndex: Int, yColumnIndex: Int) -> [(x: Double, y: Double)]? {
        guard columns.indices.contains(xColumnIndex),
              columns.indices.contains(yColumnIndex),
              let xs = valuesByColumn[columns[xColumnIndex]],
              let ys = valuesByColumn[columns[yColumnIndex]] else {
            return nil
        }
        return Array(zip(xs, ys)).map { (x: $0.0, y: $0.1) }
    }

    private func columnKey(matching requestedColumn: String) -> String? {
        if valuesByColumn[requestedColumn] != nil {
            return requestedColumn
        }
        let normalizedRequested = SpectroscopyColumnSchema.normalize(requestedColumn)
        let matches = columns.filter {
            SpectroscopyColumnSchema.normalize($0) == normalizedRequested
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

public struct SpectroscopyFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: URL
    public let filename: String
    public let kind: SpectroscopyKind
    public let experiment: String
    public let experimentIdentity: String
    public let modifiedTime: Date
    public let savedTime: Date?
    public let position: (x: Double, y: Double)?
    public let xLabel: String
    public let yLabel: String
    public let colorIndex: Int
    public let curve: SpectroscopyCurve

    public init(
        id: UUID = UUID(),
        path: URL,
        filename: String,
        kind: SpectroscopyKind,
        experiment: String,
        experimentIdentity: String? = nil,
        modifiedTime: Date,
        savedTime: Date?,
        position: (x: Double, y: Double)?,
        xLabel: String,
        yLabel: String,
        colorIndex: Int,
        curve: SpectroscopyCurve
    ) {
        self.id = id
        self.path = path
        self.filename = filename
        self.kind = kind
        self.experiment = experiment
        self.experimentIdentity = SpectroscopyExperimentIdentity.make(
            experiment: experimentIdentity ?? experiment,
            fallbackKind: kind
        )
        self.modifiedTime = modifiedTime
        self.savedTime = savedTime
        self.position = position
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.colorIndex = colorIndex
        self.curve = curve
    }

    public static func == (lhs: SpectroscopyFile, rhs: SpectroscopyFile) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct SpectroscopyGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let sxmID: SXMMetadata.ID
    public let sxmFilename: String
    public let kind: SpectroscopyKind
    public let experiment: String
    public let experimentIdentity: String
    public let columnSchema: SpectroscopyColumnSchema
    public let xLabel: String
    public let yLabel: String
    public let spectra: [SpectroscopyFile]
    public let renderID: String

    public init?(sxm: SXMMetadata, key: SpectroscopyGroupKey, spectra: [SpectroscopyFile]) {
        guard !spectra.isEmpty,
              spectra.allSatisfy({
                  $0.kind == key.kind
                      && $0.experimentIdentity == key.experimentIdentity
                      && $0.curve.columnSchema == key.columnSchema
              }) else {
            return nil
        }
        let ordered = spectra.sorted { lhs, rhs in
            lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
        let stableID = "\(sxm.id.uuidString)-\(key.fingerprint)"
        self.id = stableID
        self.sxmID = sxm.id
        self.sxmFilename = sxm.filename
        self.kind = key.kind
        self.experiment = ordered[0].experiment
        self.experimentIdentity = key.experimentIdentity
        self.columnSchema = key.columnSchema
        self.xLabel = ordered.first?.xLabel ?? "X"
        self.yLabel = ordered.first?.yLabel ?? "Y"
        self.spectra = ordered
        self.renderID = "\(stableID)-\(ordered.map { $0.id.uuidString }.joined(separator: ","))"
    }

    public static func compatibleGroups(
        sxm: SXMMetadata,
        spectra: [SpectroscopyFile]
    ) -> [SpectroscopyGroup] {
        let buckets = Dictionary(grouping: spectra) { spectrum in
            SpectroscopyGroupKey(
                kind: spectrum.kind,
                experiment: spectrum.experimentIdentity,
                columnSchema: spectrum.curve.columnSchema
            )
        }
        return buckets.compactMap { key, spectra in
            SpectroscopyGroup(sxm: sxm, key: key, spectra: spectra)
        }
        .sorted(by: groupOrderedBefore)
    }

    public var title: String {
        experiment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(kind.label) spectroscopy"
            : experiment
    }

    public var curveCountText: String {
        "\(spectra.count) line\(spectra.count == 1 ? "" : "s")"
    }

    public var availableColumns: [String] {
        spectra.first?.curve.columns ?? []
    }

    public func canonicalColumn(matching column: String) -> String? {
        if availableColumns.contains(column) {
            return column
        }
        let normalizedColumn = SpectroscopyColumnSchema.normalize(column)
        let matches = availableColumns.filter {
            SpectroscopyColumnSchema.normalize($0) == normalizedColumn
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    public func points(
        for spectrum: SpectroscopyFile,
        xColumn: String,
        yColumn: String
    ) -> [(x: Double, y: Double)]? {
        guard spectra.contains(where: { $0.id == spectrum.id }),
              spectrum.kind == kind,
              spectrum.curve.columnSchema == columnSchema,
              let canonicalX = canonicalColumn(matching: xColumn),
              let canonicalY = canonicalColumn(matching: yColumn),
              let xIndex = availableColumns.firstIndex(of: canonicalX),
              let yIndex = availableColumns.firstIndex(of: canonicalY) else {
            return nil
        }
        return spectrum.curve.points(
            xColumnIndex: xIndex,
            yColumnIndex: yIndex
        )
    }

    /// Returns the stored column arrays without rebuilding a point array.
    /// Plot redraws use this to avoid allocating and copying every sample on
    /// each layout pass.
    public func columnSeries(
        for spectrum: SpectroscopyFile,
        xColumn: String,
        yColumn: String
    ) -> (x: [Double], y: [Double])? {
        guard spectra.contains(where: { $0.id == spectrum.id }),
              spectrum.kind == kind,
              spectrum.curve.columnSchema == columnSchema,
              let canonicalX = canonicalColumn(matching: xColumn),
              let canonicalY = canonicalColumn(matching: yColumn),
              let xValues = spectrum.curve.valuesByColumn[canonicalX],
              let yValues = spectrum.curve.valuesByColumn[canonicalY] else {
            return nil
        }
        return (xValues, yValues)
    }

    public static func == (lhs: SpectroscopyGroup, rhs: SpectroscopyGroup) -> Bool {
        lhs.renderID == rhs.renderID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(renderID)
    }
}

private func groupOrderedBefore(
    _ lhs: SpectroscopyGroup,
    _ rhs: SpectroscopyGroup
) -> Bool {
    let lhsRank = spectroscopyKindRank(lhs.kind)
    let rhsRank = spectroscopyKindRank(rhs.kind)
    if lhsRank != rhsRank {
        return lhsRank < rhsRank
    }
    if lhs.experimentIdentity != rhs.experimentIdentity {
        return lhs.experimentIdentity < rhs.experimentIdentity
    }
    if lhs.columnSchema.normalizedColumns != rhs.columnSchema.normalizedColumns {
        return lhs.columnSchema.normalizedColumns.lexicographicallyPrecedes(
            rhs.columnSchema.normalizedColumns
        )
    }
    return lhs.id < rhs.id
}

private func spectroscopyKindRank(_ kind: SpectroscopyKind) -> Int {
    switch kind {
    case .z: 0
    case .bias: 1
    case .other: 2
    }
}

private func deterministicFingerprint(_ components: [String]) -> String {
    let identity = components
        .map { "\($0.utf8.count):\($0)" }
        .joined(separator: "|")
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in identity.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}
