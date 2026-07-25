import Dispatch
import Testing
@testable import SXMBrowserAppCore

private final class WorkerGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        semaphore.wait()
    }

    func release() {
        semaphore.signal()
    }
}

@Test
func preCancelledParentRejectsDetachedWork() async {
    let wasCancelled = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try await runDetachedCancellable {
                try Task.checkCancellation()
                return 1
            }
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }.value

    #expect(wasCancelled)
}

@Test
func cancellingParentCancelsRunningDetachedWorker() async {
    let gate = WorkerGate()
    let (starts, continuation) = AsyncStream<Void>.makeStream()
    let parent = Task {
        do {
            _ = try await runDetachedCancellable {
                continuation.yield()
                gate.wait()
                try Task.checkCancellation()
                return 1
            }
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }

    var iterator = starts.makeAsyncIterator()
    _ = await iterator.next()
    parent.cancel()
    gate.release()
    let wasCancelled = await parent.value
    continuation.finish()

    #expect(wasCancelled)
}
