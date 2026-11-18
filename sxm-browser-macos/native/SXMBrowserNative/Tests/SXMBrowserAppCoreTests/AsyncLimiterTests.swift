import Foundation
import Testing
@testable import SXMBrowserAppCore

@Test
func asyncLimiterEnforcesCapacityAndReleasesWaiters() async {
    let limiter = AsyncLimiter(limit: 1)

    let first = await limiter.acquire()
    #expect(first)

    let acquiredSecond = Task {
        await limiter.acquire()
    }
    await Task.yield()
    await limiter.release()

    let second = await acquiredSecond.value
    #expect(second)
    await limiter.release()
}

@Test
func asyncLimiterCancellationUnblocksWithoutLeakingPermits() async {
    let limiter = AsyncLimiter(limit: 1)
    #expect(await limiter.acquire())

    let waiter = Task {
        await limiter.acquire()
    }
    waiter.cancel()
    let waiterResult = await waiter.value
    #expect(!waiterResult)

    await limiter.release()
    let nextResult = await limiter.acquire()
    #expect(nextResult)
    await limiter.release()
}

private actor RecordedOrder {
    private(set) var events: [Int] = []

    func append(_ value: Int) {
        events.append(value)
    }
}

private func waitUntilWaiterCount(
    _ expected: Int,
    on limiter: AsyncLimiter
) async {
    for _ in 0..<200 {
        if await limiter.waiterCount == expected {
            return
        }
        await Task.yield()
    }
}

@Test
func asyncLimiterFIFOAndLIFOWakeWaitersInExpectedOrder() async {
    for (order, expected) in [
        (AsyncLimiter.AcquisitionOrder.fifo, [1, 2, 3]),
        (AsyncLimiter.AcquisitionOrder.lifo, [3, 2, 1]),
    ] {
        let limiter = AsyncLimiter(limit: 1, order: order)
        #expect(await limiter.acquire())

        let recorded = RecordedOrder()
        let first = Task {
            let ok = await limiter.acquire()
            #expect(ok)
            await recorded.append(1)
            await limiter.release()
        }
        await waitUntilWaiterCount(1, on: limiter)

        let second = Task {
            let ok = await limiter.acquire()
            #expect(ok)
            await recorded.append(2)
            await limiter.release()
        }
        await waitUntilWaiterCount(2, on: limiter)

        let third = Task {
            let ok = await limiter.acquire()
            #expect(ok)
            await recorded.append(3)
            await limiter.release()
        }
        await waitUntilWaiterCount(3, on: limiter)

        await limiter.release()
        await first.value
        await second.value
        await third.value

        #expect(await recorded.events == expected)
    }
}

@Test
func asyncLimiterLIFOCancellingQueuedWaiterWakesNextNewestWithoutLeak() async {
    let limiter = AsyncLimiter(limit: 1, order: .lifo)
    #expect(await limiter.acquire())

    let recorded = RecordedOrder()
    let oldest = Task {
        let ok = await limiter.acquire()
        #expect(ok)
        await recorded.append(1)
        await limiter.release()
    }
    await waitUntilWaiterCount(1, on: limiter)

    let middle = Task {
        let ok = await limiter.acquire()
        #expect(ok)
        await recorded.append(2)
        await limiter.release()
    }
    await waitUntilWaiterCount(2, on: limiter)

    let newest = Task { () -> Bool in
        let ok = await limiter.acquire()
        if ok {
            await recorded.append(3)
            await limiter.release()
        }
        return ok
    }
    await waitUntilWaiterCount(3, on: limiter)

    newest.cancel()
    #expect(await newest.value == false)
    await waitUntilWaiterCount(2, on: limiter)

    await limiter.release()
    await middle.value
    await oldest.value

    #expect(await recorded.events == [2, 1])
    #expect(await limiter.acquire())
    await limiter.release()
}
