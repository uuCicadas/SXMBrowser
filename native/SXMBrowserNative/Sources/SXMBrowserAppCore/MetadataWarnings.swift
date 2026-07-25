import Foundation

public struct MetadataWarningCollection: Equatable, Sendable {
    public private(set) var messages: [String]

    public init(messages: [String] = []) {
        var normalizedMessages: [String] = []
        var seen: Set<String> = []
        for message in messages {
            guard let normalized = Self.normalize(message),
                  seen.insert(normalized).inserted else {
                continue
            }
            normalizedMessages.append(normalized)
        }
        self.messages = normalizedMessages
    }

    @discardableResult
    public mutating func append(_ message: String?) -> Bool {
        guard let message,
              let normalized = Self.normalize(message),
              !messages.contains(normalized) else {
            return false
        }
        messages.append(normalized)
        return true
    }

    public var isEmpty: Bool {
        messages.isEmpty
    }

    public var count: Int {
        messages.count
    }

    public var detailText: String {
        messages.joined(separator: "\n\n")
    }

    private static func normalize(_ message: String) -> String? {
        let normalizedNewlines = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let normalized = normalizedNewlines
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct MetadataWarningPresentationState: Equatable, Sendable {
    public private(set) var collection: MetadataWarningCollection
    public private(set) var isDismissed: Bool

    public init(
        collection: MetadataWarningCollection = MetadataWarningCollection(),
        isDismissed: Bool = false
    ) {
        self.collection = collection
        self.isDismissed = collection.isEmpty ? false : isDismissed
    }

    @discardableResult
    public mutating func append(_ message: String?) -> Bool {
        guard collection.append(message) else {
            return false
        }
        isDismissed = false
        return true
    }

    public mutating func dismiss() {
        guard !collection.isEmpty else { return }
        isDismissed = true
    }

    public mutating func reset(with message: String? = nil) {
        collection = MetadataWarningCollection()
        _ = collection.append(message)
        isDismissed = false
    }

    public var isPresented: Bool {
        !collection.isEmpty && !isDismissed
    }
}
