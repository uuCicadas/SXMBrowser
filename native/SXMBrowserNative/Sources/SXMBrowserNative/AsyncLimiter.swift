import Foundation

actor AsyncLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        self.available = max(1, limit)
    }

    func acquire() async -> Bool {
        if Task.isCancelled {
            return false
        }

        if available > 0 {
            available -= 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        }
    }
}
