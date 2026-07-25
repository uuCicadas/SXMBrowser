import AppKit
import Foundation
import SXMBrowserCore

public protocol SXMMatrixReading: Sendable {
    func loadMatrix(
        _ metadata: SXMMetadata,
        key: MatrixKey
    ) async throws -> Matrix
}

public struct DefaultSXMMatrixReader: SXMMatrixReading, Sendable {
    private let parser: SXMParser

    public init(parser: SXMParser = SXMParser()) {
        self.parser = parser
    }

    public func loadMatrix(
        _ metadata: SXMMetadata,
        key: MatrixKey
    ) async throws -> Matrix {
        try Task.checkCancellation()
        return try parser.loadMatrix(metadata, key: key)
    }
}

public protocol RenderBackend: Sendable {
    func process(
        _ matrix: Matrix,
        mode: ProcessingMode
    ) async throws -> Matrix

    func statistics(
        _ matrix: Matrix
    ) async throws -> MatrixStatistics?

    func histogram(
        _ matrix: Matrix,
        statistics: MatrixStatistics,
        bins: Int
    ) async throws -> HistogramDistribution

    func image(
        _ matrix: Matrix,
        options: RenderOptions
    ) async throws -> NSImage
}

public struct DefaultRenderBackend: RenderBackend, Sendable {
    public init() {}

    public func process(
        _ matrix: Matrix,
        mode: ProcessingMode
    ) async throws -> Matrix {
        try await runDetachedCancellable(priority: .userInitiated) {
            try SXMRenderer.processedMatrix(
                matrix,
                processing: mode,
                cancellation: .task
            )
        }
    }

    public func statistics(
        _ matrix: Matrix
    ) async throws -> MatrixStatistics? {
        try await runDetachedCancellable(priority: .userInitiated) {
            try SXMRenderer.statistics(
                matrix,
                cancellation: .task
            )
        }
    }

    public func histogram(
        _ matrix: Matrix,
        statistics: MatrixStatistics,
        bins: Int
    ) async throws -> HistogramDistribution {
        try await runDetachedCancellable(priority: .userInitiated) {
            try SXMRenderer.histogram(
                matrix,
                statistics: statistics,
                bins: bins,
                cancellation: .task
            )
        }
    }

    public func image(
        _ matrix: Matrix,
        options: RenderOptions
    ) async throws -> NSImage {
        try await runDetachedCancellable(priority: .userInitiated) {
            try SXMRenderer.renderProcessedImage(
                matrix: matrix,
                options: options,
                cancellation: .task
            )
        }
    }
}

public struct CoordinatorRenderedFrame {
    public let request: RenderRequestIdentity<SXMMetadata.ID>
    public let configuration: SelectedRenderConfiguration
    public let image: NSImage
    public let stats: HistogramStats?
    public let automaticScaleMin: Double?
    public let automaticScaleMax: Double?

    public init(
        request: RenderRequestIdentity<SXMMetadata.ID>,
        configuration: SelectedRenderConfiguration,
        image: NSImage,
        stats: HistogramStats?,
        automaticScaleMin: Double?,
        automaticScaleMax: Double?
    ) {
        self.request = request
        self.configuration = configuration
        self.image = image
        self.stats = stats
        self.automaticScaleMin = automaticScaleMin
        self.automaticScaleMax = automaticScaleMax
    }
}

public enum RenderFailureStage: String, Equatable, Sendable {
    case matrixLoad
    case processing
    case statistics
    case histogram
    case imageRender
}

public struct RenderFailure: Equatable, Sendable {
    public let request: RenderRequestIdentity<SXMMetadata.ID>
    public let stage: RenderFailureStage
    public let message: String

    public init(
        request: RenderRequestIdentity<SXMMetadata.ID>,
        stage: RenderFailureStage,
        message: String
    ) {
        self.request = request
        self.stage = stage
        self.message = message
    }
}

public enum RenderCoordinatorEvent {
    case started(
        request: RenderRequestIdentity<SXMMetadata.ID>,
        configuration: SelectedRenderConfiguration
    )
    case imageReady(CoordinatorRenderedFrame)
    case histogramReady(CoordinatorRenderedFrame)
    case failed(RenderFailure)
    case cleared
}

enum RenderCoordinatorWorkID: Hashable, Sendable {
    case processing(UUID)
    case image(UUID)
    case histogram(UUID)
}

struct RenderCoordinatorTestHooks: Sendable {
    let didBegin:
        @MainActor @Sendable (RenderCoordinatorWorkID) -> Void
    let didEnd:
        @MainActor @Sendable (RenderCoordinatorWorkID) -> Void
}

@MainActor
public final class RenderCoordinator {
    public typealias EventHandler =
        @MainActor (RenderCoordinatorEvent) -> Void
    public typealias MatrixCacheFactory =
        @Sendable () -> MatrixLoadCache

    public var onEvent: EventHandler?

    public var datasetRevision: UUID {
        renderRequestGate.datasetRevision
    }

    private struct ActiveContext {
        let fileID: SXMMetadata.ID
        var configuration: SelectedRenderConfiguration
    }

    private struct ProcessedPayload: Sendable {
        let matrix: Matrix
        let statistics: MatrixStatistics?
    }

    private struct CachedHistogram: Sendable {
        let bins: Int
        let stats: HistogramStats?
    }

    private struct ProcessedRenderCache: Sendable {
        let key: ProcessedRenderKey<SXMMetadata.ID>
        let payload: ProcessedPayload
        var histogram: CachedHistogram?
    }

    private enum ProcessedEntry {
        case loading(
            key: ProcessedRenderKey<SXMMetadata.ID>,
            token: UUID,
            task: Task<ProcessedPayload, any Error>
        )
        case ready(ProcessedRenderCache)

        var key: ProcessedRenderKey<SXMMetadata.ID> {
            switch self {
            case .loading(let key, _, _):
                key
            case .ready(let cache):
                cache.key
            }
        }
    }

    private struct PipelineFailure: Error, Sendable {
        let stage: RenderFailureStage
        let message: String
    }

    private let matrixReader: any SXMMatrixReading
    private let backend: any RenderBackend
    private let makeMatrixCache: MatrixCacheFactory
    private let testHooks: RenderCoordinatorTestHooks?

    private var matrixCache: MatrixLoadCache
    private var renderRequestGate: RenderRequestGate<SXMMetadata.ID>
    private var histogramRequestGate:
        HistogramRequestGate<SXMMetadata.ID>
    private var activeContext: ActiveContext?
    private var processedEntry: ProcessedEntry?
    private var frame: CoordinatorRenderedFrame?
    private var processingCompletionTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?

    public convenience init(
        matrixReader: any SXMMatrixReading =
            DefaultSXMMatrixReader(),
        backend: any RenderBackend = DefaultRenderBackend(),
        makeMatrixCache: @escaping MatrixCacheFactory = {
            MatrixLoadCache()
        }
    ) {
        self.init(
            matrixReader: matrixReader,
            backend: backend,
            makeMatrixCache: makeMatrixCache,
            testHooks: nil
        )
    }

    init(
        matrixReader: any SXMMatrixReading,
        backend: any RenderBackend,
        makeMatrixCache: @escaping MatrixCacheFactory,
        testHooks: RenderCoordinatorTestHooks?
    ) {
        let revision = UUID()
        self.matrixReader = matrixReader
        self.backend = backend
        self.makeMatrixCache = makeMatrixCache
        self.testHooks = testHooks
        matrixCache = makeMatrixCache()
        renderRequestGate = RenderRequestGate(
            datasetRevision: revision
        )
        histogramRequestGate = HistogramRequestGate(
            datasetRevision: revision
        )
    }

    public func beginDataset(revision: UUID = UUID()) {
        imageTask?.cancel()
        imageTask = nil
        cancelHistogram()
        cancelAndDiscardProcessing()
        activeContext = nil
        frame = nil

        renderRequestGate.beginNewDataset(revision: revision)
        histogramRequestGate.beginNewDataset(revision: revision)

        let previousCache = matrixCache
        matrixCache = makeMatrixCache()
        Task {
            await previousCache.clear()
        }
        onEvent?(.cleared)
    }

    @discardableResult
    public func render(
        file: SXMMetadata,
        configuration: SelectedRenderConfiguration
    ) -> RenderRequestIdentity<SXMMetadata.ID> {
        imageTask?.cancel()
        imageTask = nil

        activeContext = ActiveContext(
            fileID: file.id,
            configuration: configuration
        )
        let request = renderRequestGate.begin(
            fileID: file.id,
            configuration: configuration
        )
        frame = nil
        onEvent?(
            .started(
                request: request,
                configuration: configuration
            )
        )

        let processedKey = request.processedKey
        if processedEntry?.key != processedKey {
            cancelHistogram()
            cancelAndDiscardProcessing()
        }

        switch processedEntry {
        case .ready(let cache) where cache.key == processedKey:
            startImageRender(for: processedKey)
        case .loading(let key, _, _) where key == processedKey:
            break
        default:
            startProcessing(for: processedKey, file: file)
        }

        return request
    }

    public func updateHistogram(
        fileID: SXMMetadata.ID,
        configuration: SelectedRenderConfiguration
    ) {
        guard var context = activeContext,
              context.fileID == fileID,
              let activeRequest = renderRequestGate.activeRequest,
              activeRequest.fileID == fileID,
              activeRequest.configuration
                == configuration.imageConfiguration else {
            return
        }

        context.configuration = configuration
        activeContext = context
        refreshHistogram(
            for: activeRequest.processedKey,
            fileID: fileID
        )
    }

    public func invalidate(clearFrame: Bool) {
        imageTask?.cancel()
        imageTask = nil
        cancelHistogram()
        cancelAndDiscardLoadingOnly()
        renderRequestGate.invalidate()
        activeContext = nil

        if clearFrame {
            frame = nil
            onEvent?(.cleared)
        }
    }

    public func discardProcessedData() {
        imageTask?.cancel()
        imageTask = nil
        cancelHistogram()
        cancelAndDiscardProcessing()
    }

    public func matrix(
        for file: SXMMetadata,
        key: MatrixKey,
        priority: TaskPriority? = nil
    ) async throws -> Matrix {
        let cache = matrixCache
        let revision = renderRequestGate.datasetRevision
        let reader = matrixReader
        let matrix = try await Self.loadMatrix(
            for: file,
            key: key,
            datasetRevision: revision,
            cache: cache,
            reader: reader,
            priority: priority
        )
        try Task.checkCancellation()
        guard revision == renderRequestGate.datasetRevision,
              cache === matrixCache else {
            throw CancellationError()
        }
        return matrix
    }

    public func removeMatrixEntries(
        forStandardizedPath path: String
    ) {
        let cache = matrixCache
        Task {
            await cache.removeEntries(forStandardizedPath: path)
        }
    }

    private func startProcessing(
        for key: ProcessedRenderKey<SXMMetadata.ID>,
        file: SXMMetadata
    ) {
        cancelAndDiscardProcessing()
        let token = UUID()
        let task = makeProcessedTask(for: key, file: file)
        processedEntry = .loading(
            key: key,
            token: token,
            task: task
        )

        let workID = RenderCoordinatorWorkID.processing(token)
        testHooks?.didBegin(workID)
        let hooks = testHooks
        processingCompletionTask = Task { [weak self] in
            defer { hooks?.didEnd(workID) }
            let result = await task.result
            guard !Task.isCancelled, let self else { return }
            finishProcessing(
                result,
                for: key,
                token: token
            )
        }
    }

    private func makeProcessedTask(
        for key: ProcessedRenderKey<SXMMetadata.ID>,
        file: SXMMetadata
    ) -> Task<ProcessedPayload, any Error> {
        let cache = matrixCache
        let reader = matrixReader
        let backend = backend
        let matrixKey = MatrixKey(
            channel: key.configuration.channel,
            direction: key.configuration.direction
        )

        return Task.detached(priority: .userInitiated) {
            let source: Matrix
            do {
                source = try await Self.loadMatrix(
                    for: file,
                    key: matrixKey,
                    datasetRevision: key.datasetRevision,
                    cache: cache,
                    reader: reader,
                    priority: .userInitiated
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SXMParserError {
                if case .matrixNotFound = error {
                    throw PipelineFailure(
                        stage: .matrixLoad,
                        message:
                            "Direction is not available for this channel."
                    )
                }
                throw PipelineFailure(
                    stage: .matrixLoad,
                    message: error.localizedDescription
                )
            } catch {
                throw PipelineFailure(
                    stage: .matrixLoad,
                    message: error.localizedDescription
                )
            }

            try Task.checkCancellation()
            let processed: Matrix
            do {
                processed = try await backend.process(
                    source,
                    mode: key.configuration.processing
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PipelineFailure(
                    stage: .processing,
                    message: error.localizedDescription
                )
            }

            try Task.checkCancellation()
            let statistics: MatrixStatistics?
            do {
                statistics = try await backend.statistics(
                    processed
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PipelineFailure(
                    stage: .statistics,
                    message: error.localizedDescription
                )
            }
            try Task.checkCancellation()
            return ProcessedPayload(
                matrix: processed,
                statistics: statistics
            )
        }
    }

    private func finishProcessing(
        _ result: Result<ProcessedPayload, any Error>,
        for key: ProcessedRenderKey<SXMMetadata.ID>,
        token: UUID
    ) {
        guard case let .loading(
            currentKey,
            currentToken,
            _
        ) = processedEntry,
              currentKey == key,
              currentToken == token else {
            return
        }

        processingCompletionTask = nil
        switch result {
        case .success(let payload):
            processedEntry = .ready(
                ProcessedRenderCache(
                    key: key,
                    payload: payload,
                    histogram: nil
                )
            )
            startImageRender(for: key)

        case .failure(let error):
            processedEntry = nil
            guard !(error is CancellationError),
                  let request = currentRenderRequest(
                      for: key
                  ) else {
                return
            }
            if let failure = error as? PipelineFailure {
                publishFailure(
                    request,
                    stage: failure.stage,
                    message: failure.message
                )
            } else {
                publishFailure(
                    request,
                    stage: .processing,
                    message: error.localizedDescription
                )
            }
        }
    }

    private nonisolated static func loadMatrix(
        for file: SXMMetadata,
        key: MatrixKey,
        datasetRevision: UUID,
        cache: MatrixLoadCache,
        reader: any SXMMatrixReading,
        priority: TaskPriority?
    ) async throws -> Matrix {
        let cacheKey = MatrixCacheKey(
            datasetRevision: datasetRevision,
            fileID: file.id,
            path: file.path,
            modifiedTime: file.modifiedTime,
            matrixKey: key
        )
        return try await cache.matrix(
            for: cacheKey,
            priority: priority
        ) {
            try await reader.loadMatrix(file, key: key)
        }
    }

    private func startImageRender(
        for processedKey: ProcessedRenderKey<SXMMetadata.ID>
    ) {
        guard let request = currentRenderRequest(for: processedKey),
              let cache = readyCache(for: processedKey),
              let context = activeContext else {
            return
        }

        imageTask?.cancel()
        imageTask = nil
        refreshHistogram(
            for: processedKey,
            fileID: request.fileID
        )

        let automaticScale = cache.payload.statistics.map {
            SXMRenderer.automaticScale($0)
        }
        let bounds = resolvedBounds(
            for: request.configuration.scale,
            automaticScale: automaticScale
        )
        let options = RenderOptions(
            channel: request.configuration.processed.channel,
            direction: request.configuration.processed.direction,
            processing: request.configuration.processed.processing,
            palette: request.configuration.palette,
            vmin: bounds.min,
            vmax: bounds.max,
            invert: request.configuration.invert
        )
        let matrix = cache.payload.matrix
        let backend = backend
        let expectedConfiguration = context.configuration
        let workID = RenderCoordinatorWorkID.image(
            request.requestID
        )
        testHooks?.didBegin(workID)
        let hooks = testHooks

        imageTask = Task { [weak self] in
            defer { hooks?.didEnd(workID) }
            let image: NSImage
            do {
                image = try await backend.image(
                    matrix,
                    options: options
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                publishFailure(
                    request,
                    stage: .imageRender,
                    message: error.localizedDescription
                )
                return
            }

            guard !Task.isCancelled, let self,
                  acceptsRenderRequest(request),
                  let currentContext = activeContext,
                  currentContext.configuration.imageConfiguration
                    == expectedConfiguration.imageConfiguration,
                  let currentCache = readyCache(
                      for: processedKey
                  ) else {
                return
            }
            let stats = currentCache.histogram?.bins
                == currentContext.configuration.histogramBins
                ? currentCache.histogram?.stats
                : nil
            let rendered = CoordinatorRenderedFrame(
                request: request,
                configuration: currentContext.configuration,
                image: image,
                stats: stats,
                automaticScaleMin: automaticScale?.vmin,
                automaticScaleMax: automaticScale?.vmax
            )
            frame = rendered
            imageTask = nil
            onEvent?(.imageReady(rendered))
        }
    }

    private func refreshHistogram(
        for processedKey: ProcessedRenderKey<SXMMetadata.ID>,
        fileID: SXMMetadata.ID
    ) {
        guard let context = activeContext,
              context.fileID == fileID,
              var cache = readyCache(for: processedKey) else {
            return
        }

        if let activeRequest = histogramRequestGate.activeRequest,
           activeRequest.processedKey == processedKey,
           histogramRequestGate.accepts(
               activeRequest,
               currentFileID: context.fileID,
               currentConfiguration: context.configuration
           ) {
            return
        }

        cancelHistogram()

        if cache.histogram?.bins
            == context.configuration.histogramBins {
            publishHistogram(
                cache.histogram?.stats,
                for: processedKey
            )
            return
        }

        guard let statistics = cache.payload.statistics else {
            cache.histogram = CachedHistogram(
                bins: context.configuration.histogramBins,
                stats: nil
            )
            processedEntry = .ready(cache)
            publishHistogram(nil, for: processedKey)
            return
        }

        let request = histogramRequestGate.begin(
            fileID: fileID,
            configuration: context.configuration
        )
        let matrix = cache.payload.matrix
        let backend = backend
        let workID = RenderCoordinatorWorkID.histogram(
            request.requestID
        )
        testHooks?.didBegin(workID)
        let hooks = testHooks
        histogramTask = Task { [weak self] in
            defer { hooks?.didEnd(workID) }
            let distribution: HistogramDistribution
            do {
                distribution = try await backend.histogram(
                    matrix,
                    statistics: statistics,
                    bins: request.configuration.bins
                )
            } catch is CancellationError {
                guard let self else { return }
                clearFailedHistogramRequest(request)
                return
            } catch {
                guard let self else { return }
                clearFailedHistogramRequest(request)
                return
            }

            guard !Task.isCancelled, let self,
                  acceptsHistogramRequest(request),
                  var currentCache = readyCache(
                      for: request.processedKey
                  ) else {
                return
            }
            let stats = HistogramStats(
                statistics: statistics,
                distribution: distribution
            )
            currentCache.histogram = CachedHistogram(
                bins: request.configuration.bins,
                stats: stats
            )
            processedEntry = .ready(currentCache)
            histogramTask = nil
            histogramRequestGate.invalidate()
            publishHistogram(
                stats,
                for: request.processedKey
            )
        }
    }

    private func clearFailedHistogramRequest(
        _ request: HistogramRequestIdentity<SXMMetadata.ID>
    ) {
        guard acceptsHistogramRequest(request) else { return }
        histogramTask = nil
        histogramRequestGate.invalidate()
    }

    private func readyCache(
        for key: ProcessedRenderKey<SXMMetadata.ID>
    ) -> ProcessedRenderCache? {
        guard case .ready(let cache) = processedEntry,
              cache.key == key else {
            return nil
        }
        return cache
    }

    private func publishHistogram(
        _ stats: HistogramStats?,
        for processedKey: ProcessedRenderKey<SXMMetadata.ID>
    ) {
        guard let currentFrame = frame,
              currentFrame.request.processedKey == processedKey,
              acceptsRenderRequest(currentFrame.request),
              let context = activeContext else {
            return
        }
        let updated = CoordinatorRenderedFrame(
            request: currentFrame.request,
            configuration: context.configuration,
            image: currentFrame.image,
            stats: stats,
            automaticScaleMin:
                currentFrame.automaticScaleMin,
            automaticScaleMax:
                currentFrame.automaticScaleMax
        )
        frame = updated
        onEvent?(.histogramReady(updated))
    }

    private func currentRenderRequest(
        for key: ProcessedRenderKey<SXMMetadata.ID>
    ) -> RenderRequestIdentity<SXMMetadata.ID>? {
        guard let request = renderRequestGate.activeRequest,
              request.processedKey == key,
              acceptsRenderRequest(request) else {
            return nil
        }
        return request
    }

    private func acceptsRenderRequest(
        _ request: RenderRequestIdentity<SXMMetadata.ID>
    ) -> Bool {
        guard let context = activeContext else { return false }
        return renderRequestGate.accepts(
            request,
            currentFileID: context.fileID,
            currentConfiguration: context.configuration
        )
    }

    private func acceptsHistogramRequest(
        _ request:
            HistogramRequestIdentity<SXMMetadata.ID>
    ) -> Bool {
        guard let context = activeContext else { return false }
        return histogramRequestGate.accepts(
            request,
            currentFileID: context.fileID,
            currentConfiguration: context.configuration
        )
    }

    private func publishFailure(
        _ request: RenderRequestIdentity<SXMMetadata.ID>,
        stage: RenderFailureStage,
        message: String
    ) {
        guard acceptsRenderRequest(request) else { return }
        renderRequestGate.invalidate()
        imageTask?.cancel()
        imageTask = nil
        cancelHistogram()
        activeContext = nil
        frame = nil
        onEvent?(
            .failed(
                RenderFailure(
                    request: request,
                    stage: stage,
                    message: message
                )
            )
        )
    }

    private func cancelHistogram() {
        histogramTask?.cancel()
        histogramTask = nil
        histogramRequestGate.invalidate()
    }

    private func cancelAndDiscardLoadingOnly() {
        processingCompletionTask?.cancel()
        processingCompletionTask = nil
        if case .loading(_, _, let task) = processedEntry {
            task.cancel()
            processedEntry = nil
        }
    }

    private func cancelAndDiscardProcessing() {
        processingCompletionTask?.cancel()
        processingCompletionTask = nil
        if case .loading(_, _, let task) = processedEntry {
            task.cancel()
        }
        processedEntry = nil
    }

    private func resolvedBounds(
        for scale: RenderScaleRequest,
        automaticScale: (vmin: Double, vmax: Double)?
    ) -> (min: Double, max: Double) {
        switch scale {
        case .automatic:
            return (
                automaticScale?.vmin ?? 0,
                automaticScale?.vmax ?? 1
            )
        case .locked(let min, let max):
            return (
                min ?? automaticScale?.vmin ?? 0,
                max ?? automaticScale?.vmax ?? 1
            )
        }
    }
}
