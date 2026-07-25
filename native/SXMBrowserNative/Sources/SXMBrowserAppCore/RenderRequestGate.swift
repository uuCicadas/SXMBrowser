import Foundation
import SXMBrowserCore

public enum RenderScaleRequest: Hashable, Sendable {
    case automatic
    case locked(min: Double?, max: Double?)
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
}

public struct RenderRequestIdentity<ID: Hashable & Sendable>: Hashable, Sendable {
    public let requestID: UUID
    public let datasetRevision: UUID
    public let fileID: ID
    public let configuration: SelectedRenderConfiguration

    public init(
        requestID: UUID = UUID(),
        datasetRevision: UUID,
        fileID: ID,
        configuration: SelectedRenderConfiguration
    ) {
        self.requestID = requestID
        self.datasetRevision = datasetRevision
        self.fileID = fileID
        self.configuration = configuration
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
            configuration: configuration
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
            && request.configuration == currentConfiguration
    }
}
