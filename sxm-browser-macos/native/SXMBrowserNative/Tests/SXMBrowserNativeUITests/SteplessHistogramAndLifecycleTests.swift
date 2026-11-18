import AppKit
import Foundation
import SXMBrowserAppCore
import SXMBrowserCore
import Testing
@testable import SXMBrowserNativeUI

private struct StaticTestMatrixReader: SXMMatrixReading {
    let matrix: Matrix

    func loadMatrix(
        _ metadata: SXMMetadata,
        key: MatrixKey
    ) async throws -> Matrix {
        matrix
    }
}

private actor ScaleCoalescingProbe {
    struct RecordedScale: Equatable, Sendable {
        let vmin: Double?
        let vmax: Double?
    }

    private var holdImageRenders = false
    private(set) var recordedScales: [RecordedScale] = []
    private var pausedContinuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func setHoldImageRenders(_ value: Bool) {
        holdImageRenders = value
    }

    func enterImageRender(vmin: Double?, vmax: Double?) async {
        recordedScales.append(RecordedScale(vmin: vmin, vmax: vmax))
        let currentCount = recordedScales.count
        var remainingWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if currentCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        countWaiters = remainingWaiters

        if holdImageRenders {
            await withCheckedContinuation { continuation in
                pausedContinuations.append(continuation)
            }
        }
    }

    func resumeNextImageRender() {
        guard !pausedContinuations.isEmpty else { return }
        pausedContinuations.removeFirst().resume()
    }

    func resumeAll() {
        let pending = pausedContinuations
        pausedContinuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitUntilImageCount(_ target: Int) async {
        if recordedScales.count >= target { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((target: target, continuation: continuation))
        }
    }
}

private struct CoalescingTestRenderBackend: RenderBackend {
    let probe: ScaleCoalescingProbe

    func process(
        _ matrix: Matrix,
        mode: ProcessingMode
    ) async throws -> Matrix {
        matrix
    }

    func statistics(
        _ matrix: Matrix
    ) async throws -> MatrixStatistics? {
        try SXMRenderer.statistics(matrix, cancellation: .task)
    }

    func histogram(
        _ matrix: Matrix,
        statistics: MatrixStatistics,
        bins: Int
    ) async throws -> HistogramDistribution {
        try SXMRenderer.histogram(
            matrix,
            statistics: statistics,
            bins: bins,
            cancellation: .task
        )
    }

    func image(
        _ matrix: Matrix,
        options: RenderOptions
    ) async throws -> NSImage {
        await probe.enterImageRender(vmin: options.vmin, vmax: options.vmax)
        return NSImage(size: NSSize(width: matrix.width, height: matrix.height))
    }
}

@MainActor
@Test
func applicationShouldTerminateAfterLastWindowClosedReturnsTrue() {
    let delegate = AppTerminationDelegate()
    #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
}

@MainActor
@Test
func updateScaleKeepsFrameAndStatsVisibleAndCoalescesInFlightDrags() async {
    let matrix = Matrix(
        width: 4,
        height: 4,
        values: (0..<16).map(Float.init)
    )
    let probe = ScaleCoalescingProbe()
    let coordinator = RenderCoordinator(
        matrixReader: StaticTestMatrixReader(matrix: matrix),
        backend: CoalescingTestRenderBackend(probe: probe)
    )
    let model = AppModel(renderCoordinator: coordinator)
    let file = makeTestSXM(filename: "stepless_drag.sxm")

    model.dataset.files = [file]
    model.mode = .single
    model.select(file)

    await probe.waitUntilImageCount(1)
    for _ in 0..<50 where model.selectedStats == nil || model.selectedImage == nil {
        await Task.yield()
    }
    let initialImage = model.selectedImage
    #expect(initialImage != nil)
    #expect(model.selectedStats != nil)
    #expect(model.selectedRenderState == .ready(fileID: file.id))

    await probe.setHoldImageRenders(true)

    // First drag sample dispatches immediately without debounce delay and retains image + stats.
    model.updateScale(min: 1.0, max: 14.0)
    #expect(model.viewer.inFlightCoalescedRequestID != nil)
    #expect(!model.viewer.hasPendingScaleRender)
    #expect(model.selectedImage === initialImage)
    #expect(model.selectedStats != nil)
    #expect(model.selectedRenderState == .ready(fileID: file.id))

    await probe.waitUntilImageCount(2)

    // Subsequent rapid drag samples coalesce to the latest bounds without cancelling the active job.
    model.updateScale(min: 2.0, max: 12.0)
    model.updateScale(min: 3.5, max: 10.5)
    #expect(model.viewer.hasPendingScaleRender)
    #expect(model.scaleMin == 3.5)
    #expect(model.scaleMax == 10.5)
    #expect(model.selectedImage === initialImage)
    #expect(model.selectedStats != nil)
    #expect(await probe.recordedScales.count == 2)

    // Finishing the first drag request publishes the progressive frame and immediately dispatches the latest bounds.
    await probe.resumeNextImageRender()
    await probe.waitUntilImageCount(3)
    for _ in 0..<50 where model.selectedImage === initialImage {
        await Task.yield()
    }
    let progressiveImage = model.selectedImage
    #expect(progressiveImage != nil)
    #expect(progressiveImage !== initialImage)
    #expect(model.scaleMin == 3.5)
    #expect(model.scaleMax == 10.5)
    #expect(model.selectedStats != nil)

    // Finish the final coalesced render.
    await probe.setHoldImageRenders(false)
    await probe.resumeAll()
    for _ in 0..<50 where model.viewer.inFlightCoalescedRequestID != nil {
        await Task.yield()
    }

    #expect(model.viewer.inFlightCoalescedRequestID == nil)
    #expect(!model.viewer.hasPendingScaleRender)
    #expect(model.selectedImage !== progressiveImage)
    #expect(model.selectedStats != nil)
    #expect(model.selectedRenderState == .ready(fileID: file.id))
    #expect(model.scaleMin == 3.5)
    #expect(model.scaleMax == 10.5)
    #expect(
        await probe.recordedScales == [
            .init(vmin: 0.0, vmax: 15.0),
            .init(vmin: 1.0, vmax: 14.0),
            .init(vmin: 3.5, vmax: 10.5),
        ]
    )
}

@MainActor
@Test
func switchingToGridOrChangingPaletteCancelsCoalescedScaleTracking() async {
    let matrix = Matrix(
        width: 4,
        height: 4,
        values: (0..<16).map(Float.init)
    )
    let probe = ScaleCoalescingProbe()
    let coordinator = RenderCoordinator(
        matrixReader: StaticTestMatrixReader(matrix: matrix),
        backend: CoalescingTestRenderBackend(probe: probe)
    )
    let model = AppModel(renderCoordinator: coordinator)
    let file = makeTestSXM(filename: "coalesced_cancel.sxm")

    model.dataset.files = [file]
    model.mode = .single
    model.select(file)
    await probe.waitUntilImageCount(1)
    for _ in 0..<50 where model.selectedStats == nil {
        await Task.yield()
    }

    await probe.setHoldImageRenders(true)
    model.updateScale(min: 1.0, max: 14.0)
    await probe.waitUntilImageCount(2)
    model.updateScale(min: 4.0, max: 9.0)
    #expect(model.viewer.inFlightCoalescedRequestID != nil)
    #expect(model.viewer.hasPendingScaleRender)

    model.setMode(.grid)
    #expect(model.viewer.inFlightCoalescedRequestID == nil)
    #expect(!model.viewer.hasPendingScaleRender)

    await probe.setHoldImageRenders(false)
    await probe.resumeAll()
}
