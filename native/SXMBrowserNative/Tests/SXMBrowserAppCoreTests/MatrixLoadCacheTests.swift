import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private enum MatrixLoadTestError: Error {
    case expectedFailure
}

private actor ControlledMatrixLoader {
    private(set) var invocationCount = 0
    private var continuation: CheckedContinuation<Matrix, Never>?

    func load() async -> Matrix {
        invocationCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed(with matrix: Matrix) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: matrix)
    }
}

private actor FailingOnceMatrixLoader {
    private(set) var invocationCount = 0

    func load() async throws -> Matrix {
        invocationCount += 1
        if invocationCount == 1 {
            throw MatrixLoadTestError.expectedFailure
        }
        return Matrix(width: 1, height: 1, values: [7])
    }
}

private actor ImmediateMatrixLoader {
    private(set) var invocationCount = 0

    func load(value: Float) -> Matrix {
        invocationCount += 1
        return Matrix(width: 1, height: 1, values: [value])
    }
}

private actor CancellableMatrixLoader {
    private(set) var invocationCount = 0
    private(set) var cancellationCount = 0

    func load() async throws -> Matrix {
        invocationCount += 1
        do {
            try await Task.sleep(for: .seconds(30))
            return Matrix(width: 1, height: 1, values: [1])
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

private func matrixCacheKey(
    revision: UUID = UUID(),
    fileID: UUID = UUID(),
    path: URL = URL(fileURLWithPath: "/tmp/cache-test.sxm"),
    modifiedTime: Date = Date(timeIntervalSince1970: 1),
    channel: String = "Z",
    direction: ScanDirection = .fwd
) -> MatrixCacheKey {
    MatrixCacheKey(
        datasetRevision: revision,
        fileID: fileID,
        path: path,
        modifiedTime: modifiedTime,
        matrixKey: MatrixKey(channel: channel, direction: direction)
    )
}

private func eventually(
    attempts: Int = 2_000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return false
}

@Test
func twentyConcurrentMatrixRequestsUseOneLoader() async throws {
    let cache = MatrixLoadCache(byteLimit: 1_024)
    let key = matrixCacheKey()
    let loader = ControlledMatrixLoader()

    let requests = (0..<20).map { _ in
        Task {
            try await cache.matrix(for: key) {
                await loader.load()
            }
        }
    }

    #expect(
        await eventually {
            await cache.activeWaiterCount(for: key) == 20
        }
    )
    #expect(await loader.invocationCount == 1)

    await loader.succeed(
        with: Matrix(width: 2, height: 1, values: [4, 5])
    )
    for request in requests {
        let matrix = try await request.value
        #expect(matrix.values == [4, 5])
    }
    #expect(await loader.invocationCount == 1)
    #expect(await cache.cachedCount == 1)
    #expect(await cache.cachedByteCount == 8)
    #expect(await cache.inFlightCount == 0)
}

@Test
func failedMatrixLoadIsRemovedAndCanRetry() async throws {
    let cache = MatrixLoadCache(byteLimit: 1_024)
    let key = matrixCacheKey()
    let loader = FailingOnceMatrixLoader()

    do {
        _ = try await cache.matrix(for: key) {
            try await loader.load()
        }
        Issue.record("First load should fail")
    } catch MatrixLoadTestError.expectedFailure {
        // Expected.
    }

    #expect(await cache.inFlightCount == 0)
    #expect(await cache.cachedCount == 0)
    let recovered = try await cache.matrix(for: key) {
        try await loader.load()
    }
    #expect(recovered.values == [7])
    #expect(await loader.invocationCount == 2)
    #expect(await cache.cachedCount == 1)
}

@Test
func matrixCacheUsesByteBudgetAndLRUEviction() async throws {
    let cache = MatrixLoadCache(byteLimit: 8)
    let firstKey = matrixCacheKey(channel: "First")
    let secondKey = matrixCacheKey(channel: "Second")

    _ = try await cache.matrix(for: firstKey) {
        Matrix(width: 2, height: 1, values: [1, 2])
    }
    _ = try await cache.matrix(for: secondKey) {
        Matrix(width: 2, height: 1, values: [3, 4])
    }

    #expect(await cache.cachedByteCount == 8)
    #expect(await cache.cachedCount == 1)
    #expect(await cache.cachedKeysFromLeastToMostRecent == [secondKey])
}

@Test
func revisionAndModificationTimeIsolateMatrixEntries() async throws {
    let cache = MatrixLoadCache(byteLimit: 1_024)
    let loader = ImmediateMatrixLoader()
    let firstRevision = UUID()
    let secondRevision = UUID()
    let fileID = UUID()
    let path = URL(fileURLWithPath: "/tmp/folder/../matrix.sxm")
    let firstTime = Date(timeIntervalSince1970: 10)
    let secondTime = Date(timeIntervalSince1970: 11)
    let firstKey = matrixCacheKey(
        revision: firstRevision,
        fileID: fileID,
        path: path,
        modifiedTime: firstTime
    )
    let sameStandardizedKey = matrixCacheKey(
        revision: firstRevision,
        fileID: fileID,
        path: URL(fileURLWithPath: "/tmp/matrix.sxm"),
        modifiedTime: firstTime
    )
    let revisionKey = matrixCacheKey(
        revision: secondRevision,
        fileID: fileID,
        path: path,
        modifiedTime: firstTime
    )
    let modifiedKey = matrixCacheKey(
        revision: firstRevision,
        fileID: fileID,
        path: path,
        modifiedTime: secondTime
    )

    #expect(firstKey == sameStandardizedKey)
    _ = try await cache.matrix(for: firstKey) {
        await loader.load(value: 1)
    }
    _ = try await cache.matrix(for: sameStandardizedKey) {
        await loader.load(value: 99)
    }
    _ = try await cache.matrix(for: revisionKey) {
        await loader.load(value: 2)
    }
    _ = try await cache.matrix(for: modifiedKey) {
        await loader.load(value: 3)
    }

    #expect(await loader.invocationCount == 3)
    #expect(await cache.cachedCount == 3)
}

@Test
func oneWaiterCancellationDoesNotCancelSharedMatrixLoad() async throws {
    let cache = MatrixLoadCache(byteLimit: 1_024)
    let key = matrixCacheKey()
    let loader = ControlledMatrixLoader()
    let operation: @Sendable () async throws -> Matrix = {
        await loader.load()
    }

    let cancelledRequest = Task {
        do {
            _ = try await cache.matrix(for: key, loader: operation)
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }
    let survivingRequest = Task {
        try await cache.matrix(for: key, loader: operation)
    }
    #expect(
        await eventually {
            await cache.activeWaiterCount(for: key) == 2
        }
    )

    cancelledRequest.cancel()
    #expect(await cancelledRequest.value)
    #expect(await cache.activeWaiterCount(for: key) == 1)
    #expect(await loader.invocationCount == 1)

    await loader.succeed(
        with: Matrix(width: 1, height: 1, values: [8])
    )
    let survivingMatrix = try await survivingRequest.value
    #expect(survivingMatrix.values == [8])
    #expect(await loader.invocationCount == 1)
}

@Test
func cancellingLastWaiterCancelsAndRemovesUnderlyingLoad() async throws {
    let cache = MatrixLoadCache(byteLimit: 1_024)
    let key = matrixCacheKey()
    let loader = CancellableMatrixLoader()
    let operation: @Sendable () async throws -> Matrix = {
        try await loader.load()
    }
    let first = Task {
        do {
            _ = try await cache.matrix(for: key, loader: operation)
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }
    let second = Task {
        do {
            _ = try await cache.matrix(for: key, loader: operation)
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }
    #expect(
        await eventually {
            await cache.activeWaiterCount(for: key) == 2
        }
    )

    first.cancel()
    #expect(await first.value)
    #expect(await cache.activeWaiterCount(for: key) == 1)
    #expect(await loader.cancellationCount == 0)

    second.cancel()
    #expect(await second.value)
    #expect(
        await eventually {
            let cancellationCount = await loader.cancellationCount
            let inFlightCount = await cache.inFlightCount
            return cancellationCount == 1 && inFlightCount == 0
        }
    )
    #expect(await loader.invocationCount == 1)
    #expect(await cache.cachedCount == 0)
}

@Test
func clearingCacheRejectsLateCompletionFromOlderGeneration() async throws {
    let cache = MatrixLoadCache(byteLimit: 1_024)
    let key = matrixCacheKey()
    let loader = ControlledMatrixLoader()
    let request = Task {
        try await cache.matrix(for: key) {
            await loader.load()
        }
    }
    #expect(
        await eventually {
            await cache.activeWaiterCount(for: key) == 1
        }
    )

    await cache.clear(cancelInFlight: false)
    await loader.succeed(
        with: Matrix(width: 1, height: 1, values: [12])
    )
    let lateMatrix = try await request.value
    #expect(lateMatrix.values == [12])
    #expect(await cache.cachedCount == 0)
    #expect(await cache.cachedByteCount == 0)
    #expect(await cache.inFlightCount == 0)
}
