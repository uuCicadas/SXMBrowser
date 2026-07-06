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

    public func points(xColumn: String, yColumn: String) -> [(x: Double, y: Double)] {
        guard let xs = valuesByColumn[xColumn],
              let ys = valuesByColumn[yColumn] else {
            return Array(zip(x, y)).map { (x: $0.0, y: $0.1) }
        }
        return Array(zip(xs, ys)).map { (x: $0.0, y: $0.1) }
    }
}

public struct SpectroscopyFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: URL
    public let filename: String
    public let kind: SpectroscopyKind
    public let experiment: String
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
    public let xLabel: String
    public let yLabel: String
    public let spectra: [SpectroscopyFile]
    public let renderID: String

    public init(sxm: SXMMetadata, kind: SpectroscopyKind, spectra: [SpectroscopyFile]) {
        let ordered = spectra.sorted { lhs, rhs in
            lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
        let stableID = "\(sxm.id.uuidString)-\(kind.rawValue)"
        self.id = stableID
        self.sxmID = sxm.id
        self.sxmFilename = sxm.filename
        self.kind = kind
        self.xLabel = ordered.first?.xLabel ?? "X"
        self.yLabel = ordered.first?.yLabel ?? "Y"
        self.spectra = ordered
        self.renderID = "\(stableID)-\(ordered.map { $0.id.uuidString }.joined(separator: ","))"
    }

    public var title: String {
        "\(kind.label) spectroscopy"
    }

    public var curveCountText: String {
        "\(spectra.count) line\(spectra.count == 1 ? "" : "s")"
    }

    public var availableColumns: [String] {
        var columns: [String] = []
        var seen: Set<String> = []
        for spectrum in spectra {
            for column in spectrum.curve.columns where !seen.contains(column) {
                columns.append(column)
                seen.insert(column)
            }
        }
        return columns
    }

    public static func == (lhs: SpectroscopyGroup, rhs: SpectroscopyGroup) -> Bool {
        lhs.renderID == rhs.renderID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(renderID)
    }
}
