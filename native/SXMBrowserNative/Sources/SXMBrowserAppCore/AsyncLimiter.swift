import Foundation

/// Bounded concurrency gate supporting deterministic structured task cancellation
/// and configurable waiter scheduling order.
public actor AsyncLimiter {
    public enum AcquisitionOrder: Sendable {
        case fifo
        case lifo
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private let order: AcquisitionOrder
    private var available: Int
    private var waiters: [Waiter] = []
    private var activeWaiterScopes: Set<UUID> = []
    private var cancelledWaiterIDs: Set<UUID> = []

    public init(limit: Int, order: AcquisitionOrder = .fifo) {
        self.limit = max(1, limit)
        self.order = order
        self.available = max(1, limit)
    }

    public func acquire() async -> Bool {
        if Task.isCancelled {
            return false
        }

        if available > 0 {
            available -= 1
            return true
        }

        let id = UUID()
        activeWaiterScopes.insert(id)
        defer {
            activeWaiterScopes.remove(id)
            cancelledWaiterIDs.remove(id)
        }

        return await withTaskCancellationHandler {
            if Task.isCancelled || cancelledWaiterIDs.contains(id) {
                return false
            }
            if available > 0 {
                available -= 1
                return true
            }
            return await withCheckedContinuation { continuation in
                if cancelledWaiterIDs.remove(id) != nil || Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    public func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            let waiter = order == .lifo ? waiters.removeLast() : waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        }
    }

    /// Snapshot of currently waiting tasks (used in tests for deterministic scheduling assertions).
    public var waiterCount: Int {
        waiters.count
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        } else if activeWaiterScopes.contains(id) {
            cancelledWaiterIDs.insert(id)
        }
    }
}
