import Foundation

public enum ScanDirection: String, CaseIterable, Codable, Sendable {
    case fwd
    case bwd

    public var label: String {
        switch self {
        case .fwd: "Forward"
        case .bwd: "Backward"
        }
    }
}

public enum ChannelKind: String, Codable, Sendable {
    case topography
    case conductanceOrCurrent
    case afm

    public var usesSTMPalette: Bool {
        self != .afm
    }
}

public enum ProcessingMode: String, CaseIterable, Codable, Sendable {
    case raw
    case lineMean
    case lineSlope
    case lineLinear
    case lineDerivative
    case planeLinear

    public var label: String {
        switch self {
        case .raw: "Raw"
        case .lineMean: "Subtract average"
        case .lineSlope: "Subtract slope"
        case .lineLinear: "Subtract linear fit"
        case .lineDerivative: "Differentiate"
        case .planeLinear: "Plane linear fit"
        }
    }
}

public enum PaletteName: String, CaseIterable, Codable, Sendable {
    case blueViolet
    case duskViolet
    case ember
    case gray

    public var label: String {
        switch self {
        case .blueViolet: "Ink Violet"
        case .duskViolet: "Dusk Violet"
        case .ember: "Ember"
        case .gray: "Basic gray"
        }
    }
}

public struct SXMChannel: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let unit: String
    public let directions: [ScanDirection]
    public let kind: ChannelKind

    public init(name: String, unit: String, directions: [ScanDirection], kind: ChannelKind) {
        self.name = name
        self.unit = unit
        self.directions = directions
        self.kind = kind
    }
}

public struct SXMMetadata: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: URL
    public let filename: String
    public let header: [String: String]
    public let recordedTime: Date?
    public let modifiedTime: Date
    public let pixels: (width: Int, height: Int)
    public let scanRange: (x: Double, y: Double)?
    public let scanOffset: (x: Double, y: Double)?
    public let scanAngle: Double?
    public let scanDir: String?
    public let zControllerOn: Bool?
    public let channels: [SXMChannel]
    public let defaultChannel: String?

    public init(
        id: UUID = UUID(),
        path: URL,
        filename: String,
        header: [String: String],
        recordedTime: Date?,
        modifiedTime: Date,
        pixels: (width: Int, height: Int),
        scanRange: (x: Double, y: Double)?,
        scanOffset: (x: Double, y: Double)?,
        scanAngle: Double?,
        scanDir: String?,
        zControllerOn: Bool?,
        channels: [SXMChannel],
        defaultChannel: String?
    ) {
        self.id = id
        self.path = path
        self.filename = filename
        self.header = header
        self.recordedTime = recordedTime
        self.modifiedTime = modifiedTime
        self.pixels = pixels
        self.scanRange = scanRange
        self.scanOffset = scanOffset
        self.scanAngle = scanAngle
        self.scanDir = scanDir
        self.zControllerOn = zControllerOn
        self.channels = channels
        self.defaultChannel = defaultChannel
    }

    public static func == (lhs: SXMMetadata, rhs: SXMMetadata) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct Matrix: Sendable {
    public let width: Int
    public let height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    public subscript(x: Int, y: Int) -> Float {
        get { values[y * width + x] }
        set { values[y * width + x] = newValue }
    }
}

public struct MatrixKey: Hashable, Sendable {
    public let channel: String
    public let direction: ScanDirection

    public init(channel: String, direction: ScanDirection) {
        self.channel = channel
        self.direction = direction
    }
}

public struct SXMFullFile: Sendable {
    public let metadata: SXMMetadata
    public let matrices: [MatrixKey: Matrix]

    public init(metadata: SXMMetadata, matrices: [MatrixKey: Matrix]) {
        self.metadata = metadata
        self.matrices = matrices
    }
}

public struct MatrixStatistics: Equatable, Sendable {
    public let count: Int
    public let min: Double
    public let max: Double
    public let p1: Double
    public let p99: Double
    public let mean: Double
    public let std: Double

    public init(
        count: Int,
        min: Double,
        max: Double,
        p1: Double,
        p99: Double,
        mean: Double,
        std: Double
    ) {
        self.count = count
        self.min = min
        self.max = max
        self.p1 = p1
        self.p99 = p99
        self.mean = mean
        self.std = std
    }
}

public struct HistogramDistribution: Equatable, Sendable {
    public let bins: Int
    public let counts: [Int]
    public let edges: [Double]

    public init(bins: Int, counts: [Int], edges: [Double]) {
        self.bins = bins
        self.counts = counts
        self.edges = edges
    }
}

public struct HistogramStats: Sendable {
    public let statistics: MatrixStatistics
    public let distribution: HistogramDistribution

    public var count: Int { statistics.count }
    public var min: Double { statistics.min }
    public var max: Double { statistics.max }
    public var p1: Double { statistics.p1 }
    public var p99: Double { statistics.p99 }
    public var mean: Double { statistics.mean }
    public var std: Double { statistics.std }
    public var bins: Int { distribution.bins }
    public var hist: [Int] { distribution.counts }
    public var edges: [Double] { distribution.edges }

    public init(
        statistics: MatrixStatistics,
        distribution: HistogramDistribution
    ) {
        self.statistics = statistics
        self.distribution = distribution
    }
}

public struct RenderOptions: Hashable, Sendable {
    public let channel: String
    public let direction: ScanDirection
    public let processing: ProcessingMode
    public let palette: PaletteName
    public let vmin: Double?
    public let vmax: Double?
    public let outputSize: Int?
    public let invert: Bool

    public init(
        channel: String,
        direction: ScanDirection,
        processing: ProcessingMode,
        palette: PaletteName,
        vmin: Double? = nil,
        vmax: Double? = nil,
        outputSize: Int? = nil,
        invert: Bool = false
    ) {
        self.channel = channel
        self.direction = direction
        self.processing = processing
        self.palette = palette
        self.vmin = vmin
        self.vmax = vmax
        self.outputSize = outputSize
        self.invert = invert
    }
}

/// Returns `true` when `:SCAN_DIR:` explicitly specifies an upward scan.
public func isUpwardScanDirection(_ scanDir: String?) -> Bool {
    guard let scanDir else { return false }
    return scanDir
        .split(whereSeparator: { !$0.isLetter })
        .contains { $0.lowercased() == "up" }
}

public func classifyChannel(_ name: String) -> ChannelKind {
    let folded = name.lowercased()
    let afmKeywords = ["frequency shift", "freq", "df", "delta f", "amplitude", "excitation", "pll", "oc_"]
    if afmKeywords.contains(where: { folded.contains($0) }) || name.contains("Δf") {
        return .afm
    }
    let tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    if tokens.contains("z") || folded.contains("topograph") || folded.contains("height") {
        return .topography
    }
    return .conductanceOrCurrent
}

public func defaultPalette(for channelName: String) -> PaletteName {
    classifyChannel(channelName).usesSTMPalette ? .duskViolet : .gray
}

public func defaultProcessing(for channelName: String) -> ProcessingMode {
    classifyChannel(channelName) == .topography ? .planeLinear : .raw
}
