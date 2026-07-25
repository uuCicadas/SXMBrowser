public func runDetachedCancellable<Success: Sendable>(
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable () throws -> Success
) async throws -> Success {
    let worker = Task.detached(priority: priority) {
        try operation()
    }

    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await worker.value
    } onCancel: {
        worker.cancel()
    }
}
