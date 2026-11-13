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
