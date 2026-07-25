import AppKit
import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private enum TestCoordinatorError: Error, LocalizedError, Sendable {
    case stage(RenderFailureStage)

    var errorDescription: String? {
        switch self {
        case .stage(let stage):
            "Injected \(stage.rawValue) failure"
        }
    }
}

private enum GateCancellationMode: Equatable, Sendable {
    case cooperative
    case ignore
}

private struct GateCall<Input: Sendable>: Sendable {
    let id: Int
    let input: Input
}

private actor SuspensionGate<Input: Sendable, Output: Sendable> {
    nonisolated let starts: AsyncStream<GateCall<Input>>

    private let startContinuation:
        AsyncStream<GateCall<Input>>.Continuation
    private let cancellationMode: GateCancellationMode
    private var nextID = 0
    private var pending: [
        Int: CheckedContinuation<
            Result<Output, any Error>,
            Never
        >
    ] = [:]
    private var cancelledBeforeInstall: Set<Int> = []

    init(
        cancellationMode: GateCancellationMode = .cooperative
    ) {
        let pair = AsyncStream<GateCall<Input>>.makeStream()
        starts = pair.stream
        startContinuation = pair.continuation
        self.cancellationMode = cancellationMode
    }

    func invoke(_ input: Input) async throws -> Output {
        let id = nextID
        nextID += 1
        startContinuation.yield(GateCall(id: id, input: input))

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancellationMode == .cooperative,
                   cancelledBeforeInstall.remove(id) != nil {
                    continuation.resume(
                        returning:
                            Result<Output, any Error>.failure(
                                CancellationError()
                            )
                    )
                    return
                }
                pending[id] = continuation
            }
        } onCancel: {
            Task {
                await self.cancel(id: id)
            }
        }
        return try result.get()
    }

    func succeed(id: Int, with output: Output) {
        pending.removeValue(forKey: id)?
            .resume(returning: .success(output))
    }

    func fail(
        id: Int,
        with error: TestCoordinatorError
    ) {
        pending.removeValue(forKey: id)?
            .resume(returning: .failure(error))
    }

    func cancelAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        cancelledBeforeInstall.removeAll()
        for continuation in continuations {
            continuation.resume(
                returning:
                    Result<Output, any Error>.failure(
                        CancellationError()
                    )
            )
        }
        startContinuation.finish()
    }

    private func cancel(id: Int) {
        guard cancellationMode == .cooperative else { return }
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(
                returning:
                    Result<Output, any Error>.failure(
                        CancellationError()
                    )
            )
        } else {
            cancelledBeforeInstall.insert(id)
        }
    }
}

private struct MatrixReadCall: Sendable {
    let metadata: SXMMetadata
    let key: MatrixKey
}

private actor TestMatrixReader: SXMMatrixReading {
    private let gate:
        SuspensionGate<MatrixReadCall, Matrix>?
    private let failure: TestCoordinatorError?
    private(set) var invocationCount = 0

    init(
        gate: SuspensionGate<MatrixReadCall, Matrix>? = nil,
        failure: TestCoordinatorError? = nil
    ) {
        self.gate = gate
        self.failure = failure
    }

    func loadMatrix(
        _ metadata: SXMMetadata,
        key: MatrixKey
    ) async throws -> Matrix {
        invocationCount += 1
        if let failure {
            throw failure
        }
        if let gate {
            return try await gate.invoke(
                MatrixReadCall(metadata: metadata, key: key)
            )
        }
        let marker = Float(metadata.header["marker"] ?? "1")
            ?? 1
        return Matrix(
            width: 1,
            height: 1,
            values: [marker]
        )
    }
}

private struct ProcessCall: Sendable {
    let matrix: Matrix
    let mode: ProcessingMode
}

private struct ImageCall: Sendable {
    let matrix: Matrix
    let options: RenderOptions
}

private struct HistogramCall: Sendable {
    let matrix: Matrix
    let statistics: MatrixStatistics
    let bins: Int
}

private struct BackendCounts: Equatable, Sendable {
    let process: Int
    let statistics: Int
    let histogram: Int
    let image: Int
}

private actor TestRenderBackend: RenderBackend {
    private let processGate:
        SuspensionGate<ProcessCall, Matrix>?
    private let imageGate:
        SuspensionGate<ImageCall, NSImage>?
    private let histogramGate:
        SuspensionGate<HistogramCall, HistogramDistribution>?
    private let nilStatistics: Bool
    private let failureStage: RenderFailureStage?
    private var histogramFailuresRemaining: Int

    private var processCount = 0
    private var statisticsCount = 0
    private var histogramCount = 0
    private var imageCount = 0
    private var options: [RenderOptions] = []

    init(
        processGate:
            SuspensionGate<ProcessCall, Matrix>? = nil,
        imageGate:
            SuspensionGate<ImageCall, NSImage>? = nil,
        histogramGate:
            SuspensionGate<
                HistogramCall,
                HistogramDistribution
            >? = nil,
        nilStatistics: Bool = false,
        failureStage: RenderFailureStage? = nil,
        histogramFailures: Int = 0
    ) {
        self.processGate = processGate
        self.imageGate = imageGate
        self.histogramGate = histogramGate
        self.nilStatistics = nilStatistics
        self.failureStage = failureStage
        histogramFailuresRemaining = histogramFailures
    }

    func process(
        _ matrix: Matrix,
        mode: ProcessingMode
    ) async throws -> Matrix {
        processCount += 1
        if failureStage == .processing {
            throw TestCoordinatorError.stage(.processing)
        }
        if let processGate {
            return try await processGate.invoke(
                ProcessCall(matrix: matrix, mode: mode)
            )
        }
        return matrix
    }

    func statistics(
        _ matrix: Matrix
    ) async throws -> MatrixStatistics? {
        statisticsCount += 1
        if failureStage == .statistics {
            throw TestCoordinatorError.stage(.statistics)
        }
        if nilStatistics {
            return nil
        }
        let marker = Double(matrix.values.first ?? 0)
        return MatrixStatistics(
            count: matrix.values.count,
            min: marker,
            max: marker + 1,
            p1: marker,
            p99: marker + 1,
            mean: marker,
            std: 0
        )
    }

    func histogram(
        _ matrix: Matrix,
        statistics: MatrixStatistics,
        bins: Int
    ) async throws -> HistogramDistribution {
        histogramCount += 1
        if histogramFailuresRemaining > 0 {
            histogramFailuresRemaining -= 1
            throw TestCoordinatorError.stage(.histogram)
        }
        if let histogramGate {
            return try await histogramGate.invoke(
                HistogramCall(
                    matrix: matrix,
                    statistics: statistics,
                    bins: bins
                )
            )
        }
        return distribution(bins: bins)
    }

    func image(
        _ matrix: Matrix,
        options: RenderOptions
    ) async throws -> NSImage {
        imageCount += 1
        self.options.append(options)
        if failureStage == .imageRender {
            throw TestCoordinatorError.stage(.imageRender)
        }
        if let imageGate {
            return try await imageGate.invoke(
                ImageCall(matrix: matrix, options: options)
            )
        }
        let marker = max(
            1,
            CGFloat(matrix.values.first ?? 1)
        )
        return NSImage(
            size: NSSize(width: marker, height: 1)
        )
    }

    func counts() -> BackendCounts {
        BackendCounts(
            process: processCount,
            statistics: statisticsCount,
            histogram: histogramCount,
            image: imageCount
        )
    }

    func imageOptions() -> [RenderOptions] {
        options
    }

    private func distribution(
        bins: Int
    ) -> HistogramDistribution {
        HistogramDistribution(
            bins: bins,
            counts: [bins],
            edges: [0, 1]
        )
    }
}

@MainActor
private final class CoordinatorProbe {
    private(set) var started:
        [RenderRequestIdentity<SXMMetadata.ID>] = []
    private(set) var images: [CoordinatorRenderedFrame] = []
    private(set) var histograms: [CoordinatorRenderedFrame] = []
    private(set) var failures: [RenderFailure] = []
    private(set) var begunWork: [RenderCoordinatorWorkID] = []
    private(set) var endedWork: Set<RenderCoordinatorWorkID> = []

    private var imageWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private var histogramWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private var failureWaiters: [
        (Int, CheckedContinuation<Void, Never>)
    ] = []
    private var endWaiters: [
        RenderCoordinatorWorkID:
            [CheckedContinuation<Void, Never>]
    ] = [:]

    var hooks: RenderCoordinatorTestHooks {
        RenderCoordinatorTestHooks(
            didBegin: { [weak self] workID in
                self?.didBegin(workID)
            },
            didEnd: { [weak self] workID in
                self?.didEnd(workID)
            }
        )
    }

    func record(_ event: RenderCoordinatorEvent) {
        switch event {
        case .started(let request, _):
            started.append(request)
        case .imageReady(let frame):
            images.append(frame)
            resolveImageWaiters()
        case .histogramReady(let frame):
            histograms.append(frame)
            resolveHistogramWaiters()
        case .failed(let failure):
            failures.append(failure)
            resolveFailureWaiters()
        case .cleared:
            break
        }
    }

    func waitForImages(_ count: Int) async {
        guard images.count < count else { return }
        await withCheckedContinuation { continuation in
            imageWaiters.append((count, continuation))
        }
    }

    func waitForHistograms(_ count: Int) async {
        guard histograms.count < count else { return }
        await withCheckedContinuation { continuation in
            histogramWaiters.append((count, continuation))
        }
    }

    func waitForFailures(_ count: Int) async {
        guard failures.count < count else { return }
        await withCheckedContinuation { continuation in
            failureWaiters.append((count, continuation))
        }
    }

    func waitUntilEnded(_ workID: RenderCoordinatorWorkID) async {
        guard !endedWork.contains(workID) else { return }
        await withCheckedContinuation { continuation in
            endWaiters[workID, default: []].append(continuation)
        }
    }

    private func didBegin(_ workID: RenderCoordinatorWorkID) {
        begunWork.append(workID)
    }

    private func didEnd(_ workID: RenderCoordinatorWorkID) {
        endedWork.insert(workID)
        let waiters = endWaiters.removeValue(forKey: workID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resolveImageWaiters() {
        let ready = imageWaiters.filter { $0.0 <= images.count }
        imageWaiters.removeAll { $0.0 <= images.count }
        for (_, waiter) in ready {
            waiter.resume()
        }
    }

    private func resolveHistogramWaiters() {
        let ready = histogramWaiters.filter {
            $0.0 <= histograms.count
        }
        histogramWaiters.removeAll {
            $0.0 <= histograms.count
        }
        for (_, waiter) in ready {
            waiter.resume()
        }
    }

    private func resolveFailureWaiters() {
        let ready = failureWaiters.filter {
            $0.0 <= failures.count
        }
        failureWaiters.removeAll {
            $0.0 <= failures.count
        }
        for (_, waiter) in ready {
            waiter.resume()
        }
    }
}

private func metadata(
    id: UUID = UUID(),
    marker: Int = 1
) -> SXMMetadata {
    SXMMetadata(
        id: id,
        path: URL(
            fileURLWithPath: "/tmp/coordinator-\(marker).sxm"
        ),
        filename: "coordinator-\(marker).sxm",
        header: ["marker": String(marker)],
        recordedTime: nil,
        modifiedTime: Date(timeIntervalSince1970: 100),
        pixels: (width: 1, height: 1),
        scanRange: nil,
        scanOffset: nil,
        scanAngle: nil,
        scanDir: nil,
        zControllerOn: nil,
        channels: [
            SXMChannel(
                name: "Z",
                unit: "m",
                directions: [.fwd, .bwd],
                kind: .stm
            ),
        ],
        defaultChannel: "Z"
    )
}

private func renderConfiguration(
    direction: ScanDirection = .fwd,
    processing: ProcessingMode = .raw,
    palette: PaletteName = .gray,
    invert: Bool = false,
    bins: Int = 256,
    scale: RenderScaleRequest = .automatic
) -> SelectedRenderConfiguration {
    SelectedRenderConfiguration(
        channel: "Z",
        direction: direction,
        processing: processing,
        palette: palette,
        invert: invert,
        histogramBins: bins,
        scale: scale
    )
}

@MainActor
private func coordinator(
    reader: any SXMMatrixReading,
    backend: any RenderBackend,
    probe: CoordinatorProbe
) -> RenderCoordinator {
    let coordinator = RenderCoordinator(
        matrixReader: reader,
        backend: backend,
        makeMatrixCache: {
            MatrixLoadCache(byteLimit: 1_024)
        },
        testHooks: probe.hooks
    )
    coordinator.onEvent = { [weak probe] event in
        probe?.record(event)
    }
    return coordinator
}

private func histogramDistribution(
    bins: Int
) -> HistogramDistribution {
    HistogramDistribution(
        bins: bins,
        counts: [bins],
        edges: [0, 1]
    )
}

@Test
@MainActor
func rapidImageChangesUseOneProcessingPipelineAndPublishNewest()
    async throws
{
    let processGate =
        SuspensionGate<ProcessCall, Matrix>(
            cancellationMode: .ignore
        )
    let reader = TestMatrixReader()
    let backend = TestRenderBackend(processGate: processGate)
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )
    var processStarts = processGate.starts.makeAsyncIterator()
    let file = metadata(marker: 7)

    _ = coordinator.render(
        file: file,
        configuration: renderConfiguration()
    )
    let processCall = try #require(await processStarts.next())

    var newest: RenderRequestIdentity<SXMMetadata.ID>?
    var newestConfiguration = renderConfiguration()
    for index in 1..<100 {
        newestConfiguration = renderConfiguration(
            palette: index.isMultiple(of: 2) ? .gold : .viridis,
            invert: !index.isMultiple(of: 2),
            scale: .locked(
                min: Double(index),
                max: Double(index + 10)
            )
        )
        newest = coordinator.render(
            file: file,
            configuration: newestConfiguration
        )
    }

    await processGate.succeed(
        id: processCall.id,
        with: processCall.input.matrix
    )
    await probe.waitForImages(1)

    let expected = try #require(newest)
    let frame = try #require(probe.images.last)
    #expect(probe.started.count == 100)
    #expect(Set(probe.started.map(\.requestID)).count == 100)
    #expect(probe.images.count == 1)
    #expect(frame.request == expected)
    #expect(frame.configuration == newestConfiguration)
    #expect(await reader.invocationCount == 1)
    #expect(
        await backend.counts()
            == BackendCounts(
                process: 1,
                statistics: 1,
                histogram: 1,
                image: 1
            )
    )
    let options = try #require(await backend.imageOptions().last)
    #expect(options.vmin == 99)
    #expect(options.vmax == 109)
}

@Test
@MainActor
func nilStatisticsAreMemoizedAndAlwaysResolveImageBounds()
    async throws
{
    let reader = TestMatrixReader()
    let backend = TestRenderBackend(nilStatistics: true)
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )
    let file = metadata()
    let configurations = [
        renderConfiguration(),
        renderConfiguration(palette: .gold),
        renderConfiguration(invert: true),
        renderConfiguration(
            palette: .viridis,
            scale: .locked(min: nil, max: nil)
        ),
    ]

    for (index, configuration) in configurations.enumerated() {
        coordinator.render(
            file: file,
            configuration: configuration
        )
        await probe.waitForImages(index + 1)
    }

    #expect(
        await backend.counts()
            == BackendCounts(
                process: 1,
                statistics: 1,
                histogram: 0,
                image: 4
            )
    )
    #expect(await reader.invocationCount == 1)
    let options = await backend.imageOptions()
    #expect(options.count == 4)
    #expect(options.allSatisfy { $0.vmin == 0 && $0.vmax == 1 })
    #expect(probe.images.allSatisfy { $0.stats == nil })
}

@Test
@MainActor
func binChangesOnlyRebinAndLateHistogramsCannotOverwriteLatest()
    async throws
{
    let histogramGate =
        SuspensionGate<
            HistogramCall,
            HistogramDistribution
        >(cancellationMode: .ignore)
    let reader = TestMatrixReader()
    let backend = TestRenderBackend(
        histogramGate: histogramGate
    )
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )
    let file = metadata()
    var starts = histogramGate.starts.makeAsyncIterator()

    let imageRequest = coordinator.render(
        file: file,
        configuration: renderConfiguration()
    )
    let initial = try #require(await starts.next())
    await probe.waitForImages(1)
    await histogramGate.succeed(
        id: initial.id,
        with: histogramDistribution(bins: initial.input.bins)
    )
    await probe.waitForHistograms(1)

    var staleCalls: [GateCall<HistogramCall>] = []
    for bins in [64, 512] {
        coordinator.updateHistogram(
            fileID: file.id,
            configuration: renderConfiguration(bins: bins)
        )
        staleCalls.append(
            try #require(await starts.next())
        )
    }
    coordinator.updateHistogram(
        fileID: file.id,
        configuration: renderConfiguration(bins: 1_024)
    )
    let latestCall = try #require(await starts.next())
    let histogramWork = probe.begunWork.filter {
        if case .histogram = $0 { true } else { false }
    }

    await histogramGate.succeed(
        id: latestCall.id,
        with: histogramDistribution(bins: 1_024)
    )
    await probe.waitForHistograms(2)
    for call in staleCalls.reversed() {
        await histogramGate.succeed(
            id: call.id,
            with: histogramDistribution(bins: call.input.bins)
        )
    }
    for workID in histogramWork {
        await probe.waitUntilEnded(workID)
    }

    #expect(probe.histograms.count == 2)
    #expect(probe.histograms.last?.stats?.bins == 1_024)
    #expect(probe.histograms.last?.request == imageRequest)
    #expect(
        await backend.counts()
            == BackendCounts(
                process: 1,
                statistics: 1,
                histogram: 4,
                image: 1
            )
    )
}

@Test
@MainActor
func histogramFailureKeepsImageAndAllowsSameBinsRetry()
    async throws
{
    let reader = TestMatrixReader()
    let backend = TestRenderBackend(histogramFailures: 1)
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )
    let file = metadata()

    coordinator.render(
        file: file,
        configuration: renderConfiguration()
    )
    await probe.waitForImages(1)
    let firstHistogramWork = try #require(
        probe.begunWork.first {
            if case .histogram = $0 { true } else { false }
        }
    )
    await probe.waitUntilEnded(firstHistogramWork)

    coordinator.updateHistogram(
        fileID: file.id,
        configuration: renderConfiguration()
    )
    await probe.waitForHistograms(1)

    #expect(probe.images.count == 1)
    #expect(probe.failures.isEmpty)
    #expect(probe.histograms.last?.stats?.bins == 256)
    #expect(
        await backend.counts()
            == BackendCounts(
                process: 1,
                statistics: 1,
                histogram: 2,
                image: 1
            )
    )
}

@Test
@MainActor
func staleHistogramUpdateCannotCancelCurrentFileWork()
    async throws
{
    let histogramGate =
        SuspensionGate<
            HistogramCall,
            HistogramDistribution
        >()
    let reader = TestMatrixReader()
    let backend = TestRenderBackend(
        histogramGate: histogramGate
    )
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )
    let currentFile = metadata(marker: 2)
    let staleFile = metadata(marker: 1)
    var starts = histogramGate.starts.makeAsyncIterator()

    coordinator.render(
        file: currentFile,
        configuration: renderConfiguration()
    )
    let call = try #require(await starts.next())
    await probe.waitForImages(1)
    let workID = try #require(
        probe.begunWork.first {
            if case .histogram = $0 { true } else { false }
        }
    )

    coordinator.updateHistogram(
        fileID: staleFile.id,
        configuration: renderConfiguration(bins: 512)
    )
    await histogramGate.succeed(
        id: call.id,
        with: histogramDistribution(bins: call.input.bins)
    )
    await probe.waitUntilEnded(workID)

    #expect(probe.histograms.count == 1)
    #expect(probe.histograms.first?.request.fileID == currentFile.id)
    #expect(probe.histograms.first?.stats?.bins == 256)
}

@Test
@MainActor
func beginDatasetRejectsAnImageThatIgnoresCancellation()
    async throws
{
    let imageGate =
        SuspensionGate<ImageCall, NSImage>(
            cancellationMode: .ignore
        )
    let reader = TestMatrixReader()
    let backend = TestRenderBackend(imageGate: imageGate)
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )
    var starts = imageGate.starts.makeAsyncIterator()

    let oldRequest = coordinator.render(
        file: metadata(),
        configuration: renderConfiguration()
    )
    let oldCall = try #require(await starts.next())
    coordinator.beginDataset(revision: UUID())

    await imageGate.succeed(
        id: oldCall.id,
        with: NSImage(size: NSSize(width: 99, height: 1))
    )
    await probe.waitUntilEnded(.image(oldRequest.requestID))

    #expect(probe.images.isEmpty)
    #expect(probe.histograms.isEmpty)
    #expect(probe.failures.isEmpty)
}

@Test(
    arguments: [
        RenderFailureStage.matrixLoad,
        .processing,
        .statistics,
        .imageRender,
    ]
)
@MainActor
func stageFailuresAreAttributedToTheActiveRequest(
    stage: RenderFailureStage
) async throws {
    let reader = TestMatrixReader(
        failure: stage == .matrixLoad
            ? .stage(.matrixLoad)
            : nil
    )
    let backend = TestRenderBackend(
        failureStage: stage == .matrixLoad ? nil : stage
    )
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )

    let request = coordinator.render(
        file: metadata(),
        configuration: renderConfiguration()
    )
    await probe.waitForFailures(1)

    let failure = try #require(probe.failures.first)
    #expect(probe.failures.count == 1)
    #expect(failure.request == request)
    #expect(failure.stage == stage)
    #expect(failure.message.contains("Injected"))
    #expect(probe.images.isEmpty)
}

@Test
@MainActor
func matrixNotFoundUsesFriendlyDirectionMessage() async throws {
    let file = metadata()
    let reader = MatrixNotFoundReader()
    let backend = TestRenderBackend()
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )

    coordinator.render(
        file: file,
        configuration: renderConfiguration(direction: .bwd)
    )
    await probe.waitForFailures(1)

    let failure = try #require(probe.failures.first)
    #expect(failure.stage == .matrixLoad)
    #expect(
        failure.message
            == "Direction is not available for this channel."
    )
}

private struct MatrixNotFoundReader: SXMMatrixReading {
    func loadMatrix(
        _ metadata: SXMMetadata,
        key: MatrixKey
    ) async throws -> Matrix {
        throw SXMParserError.matrixNotFound(
            metadata.path,
            channel: key.channel,
            direction: key.direction
        )
    }
}

@Test
@MainActor
func staleOrdinaryImageFailureCannotClearNewerFrame()
    async throws
{
    let imageGate =
        SuspensionGate<ImageCall, NSImage>(
            cancellationMode: .ignore
        )
    let reader = TestMatrixReader()
    let backend = TestRenderBackend(imageGate: imageGate)
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )
    var starts = imageGate.starts.makeAsyncIterator()
    let firstFile = metadata(marker: 1)
    let secondFile = metadata(marker: 2)

    let firstRequest = coordinator.render(
        file: firstFile,
        configuration: renderConfiguration()
    )
    let firstCall = try #require(await starts.next())
    let secondRequest = coordinator.render(
        file: secondFile,
        configuration: renderConfiguration()
    )
    let secondCall = try #require(await starts.next())

    await imageGate.succeed(
        id: secondCall.id,
        with: NSImage(size: NSSize(width: 2, height: 1))
    )
    await probe.waitForImages(1)
    await imageGate.fail(
        id: firstCall.id,
        with: .stage(.imageRender)
    )
    await probe.waitUntilEnded(.image(firstRequest.requestID))

    #expect(probe.images.count == 1)
    #expect(probe.images.first?.request == secondRequest)
    #expect(probe.failures.isEmpty)
}

@Test
@MainActor
func renderAndExternalMatrixAccessShareTheMatrixCache()
    async throws
{
    let reader = TestMatrixReader()
    let backend = TestRenderBackend()
    let probe = CoordinatorProbe()
    let coordinator = coordinator(
        reader: reader,
        backend: backend,
        probe: probe
    )
    let file = metadata(marker: 8)
    let key = MatrixKey(channel: "Z", direction: .fwd)

    coordinator.render(
        file: file,
        configuration: renderConfiguration()
    )
    await probe.waitForImages(1)
    let cached = try await coordinator.matrix(
        for: file,
        key: key
    )

    #expect(cached.values == [8])
    #expect(await reader.invocationCount == 1)

    coordinator.beginDataset(revision: UUID())
    let reloaded = try await coordinator.matrix(
        for: file,
        key: key
    )
    #expect(reloaded.values == [8])
    #expect(await reader.invocationCount == 2)
}
