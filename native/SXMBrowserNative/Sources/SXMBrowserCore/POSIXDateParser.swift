import Foundation

/// Thread-safe cache of `DateFormatter` instances for fixed POSIX header timestamps.
final class POSIXDateParser: @unchecked Sendable {
    private let lock = NSLock()
    private let formatters: [DateFormatter]

    init(formats: [String]) {
        self.formatters = formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }

    func date(from raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        for formatter in formatters {
            if let parsed = formatter.date(from: raw) {
                return parsed
            }
        }
        return nil
    }
}
