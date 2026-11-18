import Foundation
import SXMBrowserCore

public enum RenderScaleRequest: Hashable, Sendable {
    case automatic
    case locked(min: Double?, max: Double?)
}

public struct ProcessedRenderConfiguration: Hashable, Sendable {
    public let channel: String
    public let direction: ScanDirection
    public let processing: ProcessingMode

    public init(
        channel: String,
        direction: ScanDirection,
        processing: ProcessingMode
    ) {
        self.channel = channel
        self.direction = direction
        self.processing = processing
    }
}

public struct ImageRenderConfiguration: Hashable, Sendable {
    public let processed: ProcessedRenderConfiguration
    public let palette: PaletteName
    public let invert: Bool
    public let scale: RenderScaleRequest

    public init(
        processed: ProcessedRenderConfiguration,
        palette: PaletteName,
        invert: Bool,
        scale: RenderScaleRequest
    ) {
        self.processed = processed
        self.palette = palette
        self.invert = invert
        self.scale = scale
    }
}

public struct HistogramRenderConfiguration: Hashable, Sendable {
    public let processed: ProcessedRenderConfiguration
    public let bins: Int

    public init(
        processed: ProcessedRenderConfiguration,
        bins: Int
    ) {
        self.processed = processed
        self.bins = bins
    }
}

public struct SelectedRenderConfiguration: Hashable, Sendable {
    public let channel: String
    public let direction: ScanDirection
    public let processing: ProcessingMode
    public let palette: PaletteName
    public let invert: Bool
    public let histogramBins: Int
    public let scale: RenderScaleRequest

    public init(
        channel: String,
        direction: ScanDirection,
        processing: ProcessingMode,
        palette: PaletteName,
        invert: Bool,
        histogramBins: Int,
        scale: RenderScaleRequest
    ) {
        self.channel = channel
        self.direction = direction
        self.processing = processing
        self.palette = palette
        self.invert = invert
        self.histogramBins = histogramBins
        self.scale = scale
    }

    public var processedConfiguration: ProcessedRenderConfiguration {
        ProcessedRenderConfiguration(
            channel: channel,
            direction: direction,
            processing: processing
        )
    }

    public var imageConfiguration: ImageRenderConfiguration {
        ImageRenderConfiguration(
            processed: processedConfiguration,
            palette: palette,
            invert: invert,
            scale: scale
        )
    }

    public var histogramConfiguration: HistogramRenderConfiguration {
        HistogramRenderConfiguration(
            processed: processedConfiguration,
            bins: histogramBins
        )
    }
}

public struct ProcessedRenderKey<ID: Hashable & Sendable>: Hashable, Sendable {
    public let datasetRevision: UUID
    public let fileID: ID
    public let configuration: ProcessedRenderConfiguration

    public init(
        datasetRevision: UUID,
        fileID: ID,
        configuration: ProcessedRenderConfiguration
    ) {
        self.datasetRevision = datasetRevision
        self.fileID = fileID
        self.configuration = configuration
    }
}

public struct RenderRequestIdentity<ID: Hashable & Sendable>: Hashable, Sendable {
    public let requestID: UUID
    public let datasetRevision: UUID
    public let fileID: ID
    public let configuration: ImageRenderConfiguration

    public init(
        requestID: UUID = UUID(),
        datasetRevision: UUID,
        fileID: ID,
        configuration: ImageRenderConfiguration
    ) {
        self.requestID = requestID
        self.datasetRevision = datasetRevision
        self.fileID = fileID
        self.configuration = configuration
    }

    public var processedKey: ProcessedRenderKey<ID> {
        ProcessedRenderKey(
            datasetRevision: datasetRevision,
            fileID: fileID,
            configuration: configuration.processed
        )
    }
}

public struct RenderRequestGate<ID: Hashable & Sendable>: Sendable {
    public private(set) var datasetRevision: UUID
    public private(set) var activeRequest: RenderRequestIdentity<ID>?

    public init(datasetRevision: UUID = UUID()) {
        self.datasetRevision = datasetRevision
        activeRequest = nil
    }

    public mutating func begin(
        fileID: ID,
        configuration: SelectedRenderConfiguration,
        requestID: UUID = UUID()
    ) -> RenderRequestIdentity<ID> {
        let request = RenderRequestIdentity(
            requestID: requestID,
            datasetRevision: datasetRevision,
            fileID: fileID,
            configuration: configuration.imageConfiguration
        )
        activeRequest = request
        return request
    }

    public mutating func invalidate() {
        activeRequest = nil
    }

    public mutating func beginNewDataset(revision: UUID = UUID()) {
        datasetRevision = revision
        activeRequest = nil
    }

    public func accepts(
        _ request: RenderRequestIdentity<ID>,
        currentFileID: ID?,
        currentConfiguration: SelectedRenderConfiguration
    ) -> Bool {
        activeRequest == request
            && request.datasetRevision == datasetRevision
            && request.fileID == currentFileID
            && request.configuration == currentConfiguration.imageConfiguration
    }
}

public struct HistogramRequestIdentity<ID: Hashable & Sendable>: Hashable, Sendable {
    public let requestID: UUID
    public let datasetRevision: UUID
    public let fileID: ID
    public let configuration: HistogramRenderConfiguration

    public init(
        requestID: UUID = UUID(),
        datasetRevision: UUID,
        fileID: ID,
        configuration: HistogramRenderConfiguration
    ) {
        self.requestID = requestID
        self.datasetRevision = datasetRevision
        self.fileID = fileID
        self.configuration = configuration
    }

    public var processedKey: ProcessedRenderKey<ID> {
        ProcessedRenderKey(
            datasetRevision: datasetRevision,
            fileID: fileID,
            configuration: configuration.processed
        )
    }
}

public struct HistogramRequestGate<ID: Hashable & Sendable>: Sendable {
    public private(set) var datasetRevision: UUID
    public private(set) var activeRequest: HistogramRequestIdentity<ID>?

    public init(datasetRevision: UUID = UUID()) {
        self.datasetRevision = datasetRevision
        activeRequest = nil
    }

    public mutating func begin(
        fileID: ID,
        configuration: SelectedRenderConfiguration,
        requestID: UUID = UUID()
    ) -> HistogramRequestIdentity<ID> {
        let request = HistogramRequestIdentity(
            requestID: requestID,
            datasetRevision: datasetRevision,
            fileID: fileID,
            configuration: configuration.histogramConfiguration
        )
        activeRequest = request
        return request
    }

    public mutating func invalidate() {
        activeRequest = nil
    }

    public mutating func beginNewDataset(revision: UUID = UUID()) {
        datasetRevision = revision
        activeRequest = nil
    }

    public func accepts(
        _ request: HistogramRequestIdentity<ID>,
        currentFileID: ID?,
        currentConfiguration: SelectedRenderConfiguration
    ) -> Bool {
        activeRequest == request
            && request.datasetRevision == datasetRevision
            && request.fileID == currentFileID
            && request.configuration
                == currentConfiguration.histogramConfiguration
    }
}
