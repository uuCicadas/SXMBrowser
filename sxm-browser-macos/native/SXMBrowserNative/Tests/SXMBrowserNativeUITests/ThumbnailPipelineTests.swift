import AppKit
import Foundation
import SXMBrowserAppCore
import SXMBrowserCore
import Testing
@testable import SXMBrowserNativeUI

@MainActor
private final class ThumbnailPipelineHarness {
    var startedOrder: [String] = []
    var renderCount = 0
    private var slotContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var activeWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    func waitUntilStarted(_ filename: String) async {
        if slotContinuations[filename] != nil || startedOrder.contains(filename) {
            return
        }
        await withCheckedContinuation { continuation in
            activeWaiters[filename] = continuation
        }
    }

    func recordStart(_ filename: String) async {
        renderCount += 1
        startedOrder.append(filename)
        await withCheckedContinuation { continuation in
            slotContinuations[filename] = continuation
            activeWaiters.removeValue(forKey: filename)?.resume()
        }
    }

    func finish(_ filename: String) {
        slotContinuations.removeValue(forKey: filename)?.resume()
    }
}

@MainActor
@Test
func thumbnailPipelineProcessesWaitingViewportRequestsLIFO() async {
    let harness = ThumbnailPipelineHarness()
    let pipeline = ThumbnailPipeline(concurrencyLimit: 4) { file, _, _, _, _, _ in
        await harness.recordStart(file.filename)
        return UncheckedSendableImage(makeTestImage())
    }

    let initialFiles = (1...4).map { makeTestSXM(filename: "init_\($0).sxm") }
    let queuedFiles = ["q1.sxm", "q2.sxm", "q3.sxm", "q4.sxm"].map {
        makeTestSXM(filename: $0)
    }

    let initialTasks = initialFiles.map { file in
        Task { @MainActor in
            await pipeline.thumbnail(
                for: file,
                channel: "Z",
                direction: .fwd,
                processing: .planeLinear,
                palette: .duskViolet,
                invert: false
            )
        }
    }
    for file in initialFiles {
        await harness.waitUntilStarted(file.filename)
    }

    // Queue q1 -> q2 -> q3 -> q4 deterministically while all 4 limiter slots are occupied.
    var queuedTasks: [Task<NSImage?, Never>] = []
    for (index, file) in queuedFiles.enumerated() {
        let task = Task { @MainActor in
            await pipeline.thumbnail(
                for: file,
                channel: "Z",
                direction: .fwd,
                processing: .planeLinear,
                palette: .duskViolet,
                invert: false
            )
        }
        queuedTasks.append(task)
        let targetWaiterCount = index + 1
        for _ in 0..<200 {
            if await pipeline.waitingCount == targetWaiterCount {
                break
            }
            await Task.yield()
        }
        #expect(await pipeline.waitingCount == targetWaiterCount)
    }

    // Release 1 initial slot at a time so each queued item wakes deterministically in LIFO order.
    let expectedWakeOrder = ["q4.sxm", "q3.sxm", "q2.sxm", "q1.sxm"]
    for (index, expectedName) in expectedWakeOrder.enumerated() {
        harness.finish(initialFiles[index].filename)
        await harness.waitUntilStarted(expectedName)
    }
    for name in expectedWakeOrder {
        harness.finish(name)
    }

    for task in initialTasks {
        _ = await task.value
    }
    for task in queuedTasks {
        _ = await task.value
    }

    let queuedStarted = Array(harness.startedOrder.suffix(4))
    #expect(queuedStarted == expectedWakeOrder)
}

@MainActor
@Test
func thumbnailPipelineDeduplicatesAndCancelsOnlyWhenAllWaitersCancel() async {
    let harness = ThumbnailPipelineHarness()
    let cancellationObserved = LockedFlag()
    let pipeline = ThumbnailPipeline(concurrencyLimit: 4) { file, _, _, _, _, _ in
        await harness.recordStart(file.filename)
        if Task.isCancelled {
            cancellationObserved.trigger()
            return nil
        }
        return UncheckedSendableImage(makeTestImage())
    }

    let sharedFile = makeTestSXM(filename: "shared.sxm")
    let waiter1 = Task { @MainActor in
        await pipeline.thumbnail(
            for: sharedFile,
            channel: "Z",
            direction: .fwd,
            processing: .planeLinear,
            palette: .duskViolet,
            invert: false
        )
    }
    let waiter2 = Task { @MainActor in
        await pipeline.thumbnail(
            for: sharedFile,
            channel: "Z",
            direction: .fwd,
            processing: .planeLinear,
            palette: .duskViolet,
            invert: false
        )
    }

    await harness.waitUntilStarted("shared.sxm")
    #expect(harness.renderCount == 1)

    // Cancelling waiter 1 must leave the shared task alive for waiter 2.
    waiter1.cancel()
    await Task.yield()
    harness.finish("shared.sxm")

    let image1 = await waiter1.value
    let image2 = await waiter2.value
    #expect(image1 == nil)
    #expect(image2 != nil)
    #expect(!cancellationObserved.isTriggered)

    // Cancelling all waiters must cancel the underlying task.
    let cancelledFile = makeTestSXM(filename: "cancelled.sxm")
    let singleWaiter = Task { @MainActor in
        await pipeline.thumbnail(
            for: cancelledFile,
            channel: "Z",
            direction: .fwd,
            processing: .planeLinear,
            palette: .duskViolet,
            invert: false
        )
    }
    await harness.waitUntilStarted("cancelled.sxm")
    singleWaiter.cancel()
    await Task.yield()
    harness.finish("cancelled.sxm")

    let cancelledResult = await singleWaiter.value
    #expect(cancelledResult == nil)
    #expect(cancellationObserved.isTriggered)
}

@MainActor
@Test
func thumbnailPipelineInvalidateAllEvictsCachedImages() async {
    var renderCount = 0
    let pipeline = ThumbnailPipeline(concurrencyLimit: 4) { _, _, _, _, _, _ in
        renderCount += 1
        return UncheckedSendableImage(makeTestImage())
    }

    let file = makeTestSXM(filename: "cache_test.sxm")
    let first = await pipeline.thumbnail(
        for: file,
        channel: "Z",
        direction: .fwd,
        processing: .planeLinear,
        palette: .duskViolet,
        invert: false
    )
    #expect(first != nil)
    #expect(renderCount == 1)

    let second = await pipeline.thumbnail(
        for: file,
        channel: "Z",
        direction: .fwd,
        processing: .planeLinear,
        palette: .duskViolet,
        invert: false
    )
    #expect(second != nil)
    #expect(renderCount == 1)

    pipeline.invalidateAll()

    let third = await pipeline.thumbnail(
        for: file,
        channel: "Z",
        direction: .fwd,
        processing: .planeLinear,
        palette: .duskViolet,
        invert: false
    )
    #expect(third != nil)
    #expect(renderCount == 2)
}
