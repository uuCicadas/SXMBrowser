import Foundation

public enum MatrixCacheBudget {
    public static let maximumBytes = 512 * 1_024 * 1_024

    public static var defaultByteLimit: Int {
        byteLimit(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    public static func byteLimit(physicalMemoryBytes: UInt64) -> Int {
        let oneEighth = physicalMemoryBytes / 8
        let capped = min(UInt64(maximumBytes), oneEighth)
        return Int(exactly: capped) ?? Int.max
    }
}
