import Foundation
import SXMBrowserCore

public struct MatrixCacheKey: Hashable, Sendable {
    public let datasetRevision: UUID
    public let fileID: SXMMetadata.ID
    public let standardizedPath: String
    public let modifiedTime: Date
    public let matrixKey: MatrixKey

    public init(
        datasetRevision: UUID,
        fileID: SXMMetadata.ID,
        path: URL,
        modifiedTime: Date,
        matrixKey: MatrixKey
    ) {
        self.datasetRevision = datasetRevision
        self.fileID = fileID
        self.standardizedPath = path.standardizedFileURL.path
        self.modifiedTime = modifiedTime
        self.matrixKey = matrixKey
    }
}

public actor MatrixLoadCache {
    public typealias Loader = @Sendable () async throws -> Matrix

    private struct InFlight {
        let token: UUID
        let generation: UInt64
        let task: Task<Matrix, any Error>
        var waiterCount: Int
    }

    private let cache: ByteLRUCache<MatrixCacheKey, Matrix>
    private var inFlight: [MatrixCacheKey: InFlight] = [:]
    private var generation: UInt64 = 0

    public init(byteLimit: Int = MatrixCacheBudget.defaultByteLimit) {
        cache = ByteLRUCache(byteLimit: byteLimit)
    }

    public var cachedCount: Int {
        cache.count
    }

    public var cachedByteCount: Int {
        cache.totalCost
    }

    public var inFlightCount: Int {
        inFlight.count
    }

    public var cachedKeysFromLeastToMostRecent: [MatrixCacheKey] {
        cache.keysFromLeastToMostRecent
    }

    public func activeWaiterCount(for key: MatrixCacheKey) -> Int {
        inFlight[key]?.waiterCount ?? 0
    }

    public func matrix(
        for key: MatrixCacheKey,
        priority: TaskPriority? = nil,
        loader: @escaping Loader
    ) async throws -> Matrix {
        try Task.checkCancellation()
        if let cached = cache.value(forKey: key) {
            return cached
        }

        let entry: InFlight
        if var existing = inFlight[key] {
            existing.waiterCount += 1
            inFlight[key] = existing
            entry = existing
        } else {
            let token = UUID()
            let entryGeneration = generation
            let task = Task.detached(priority: priority) {
                try await loader()
            }
            entry = InFlight(
                token: token,
                generation: entryGeneration,
                task: task,
                waiterCount: 1
            )
            inFlight[key] = entry

            Task.detached { [weak self] in
                let result = await task.result
                await self?.complete(
                    result,
                    for: key,
                    token: token,
                    generation: entryGeneration
                )
            }
        }

        let outcome = await MatrixTaskWaiter.outcome(of: entry.task)
        switch outcome {
        case .waiterCancelled:
            cancelWaiter(
                for: key,
                token: entry.token,
                generation: entry.generation
            )
            throw CancellationError()
        case .result(let result):
            complete(
                result,
                for: key,
                token: entry.token,
                generation: entry.generation
            )
            try Task.checkCancellation()
            return try result.get()
        }
    }

    public func removeEntries(forStandardizedPath path: String) {
        let matchingCacheKeys = cache.keysFromLeastToMostRecent.filter {
            $0.standardizedPath == path
        }
        for key in matchingCacheKeys {
            cache.removeValue(forKey: key)
        }

        let matchingLoads = inFlight.filter {
            $0.key.standardizedPath == path
        }
        for (key, entry) in matchingLoads {
            inFlight.removeValue(forKey: key)
            entry.task.cancel()
        }
    }

    public func clear(cancelInFlight: Bool = true) {
        generation &+= 1
        cache.removeAll()
        let activeLoads = Array(inFlight.values)
        inFlight.removeAll()
        if cancelInFlight {
            for entry in activeLoads {
                entry.task.cancel()
            }
        }
    }

    private func complete(
        _ result: Result<Matrix, any Error>,
        for key: MatrixCacheKey,
        token: UUID,
        generation entryGeneration: UInt64
    ) {
        guard entryGeneration == generation,
              inFlight[key]?.token == token else {
            return
        }
        inFlight.removeValue(forKey: key)
        guard case .success(let matrix) = result else {
            return
        }
        cache.insert(
            matrix,
            forKey: key,
            cost: matrixByteCost(matrix)
        )
    }

    private func cancelWaiter(
        for key: MatrixCacheKey,
        token: UUID,
        generation entryGeneration: UInt64
    ) {
        guard entryGeneration == generation,
              var entry = inFlight[key],
              entry.token == token else {
            return
        }
        entry.waiterCount -= 1
        if entry.waiterCount > 0 {
            inFlight[key] = entry
        } else {
            inFlight.removeValue(forKey: key)
            entry.task.cancel()
        }
    }

    private func matrixByteCost(_ matrix: Matrix) -> Int {
        let (cost, overflowed) = matrix.values.count.multipliedReportingOverflow(
            by: MemoryLayout<Float>.stride
        )
        return overflowed ? Int.max : cost
    }
}

private enum MatrixTaskOutcome: @unchecked Sendable {
    case result(Result<Matrix, any Error>)
    case waiterCancelled
}

private final class MatrixTaskWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MatrixTaskOutcome, Never>?
    private var completedOutcome: MatrixTaskOutcome?

    static func outcome(
        of task: Task<Matrix, any Error>
    ) async -> MatrixTaskOutcome {
        let waiter = MatrixTaskWaiter()
        return await withTaskCancellationHandler {
            if Task.isCancelled {
                return .waiterCancelled
            }
            return await withCheckedContinuation { continuation in
                waiter.install(continuation)
                Task.detached {
                    waiter.resolve(.result(await task.result))
                }
            }
        } onCancel: {
            waiter.resolve(.waiterCancelled)
        }
    }

    private func install(
        _ continuation: CheckedContinuation<MatrixTaskOutcome, Never>
    ) {
        lock.lock()
        if let completedOutcome {
            lock.unlock()
            continuation.resume(returning: completedOutcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func resolve(_ outcome: MatrixTaskOutcome) {
        lock.lock()
        guard completedOutcome == nil else {
            lock.unlock()
            return
        }
        completedOutcome = outcome
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}
