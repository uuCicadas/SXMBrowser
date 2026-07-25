public struct CancellationCheckpoint: Sendable {
    private let operation: @Sendable () throws -> Void

    public init(_ operation: @escaping @Sendable () throws -> Void) {
        self.operation = operation
    }

    public func check() throws {
        try operation()
    }

    public static let none = CancellationCheckpoint {}
    public static let task = CancellationCheckpoint {
        try Task.checkCancellation()
    }
}
