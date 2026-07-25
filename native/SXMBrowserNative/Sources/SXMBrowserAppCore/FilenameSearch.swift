import Foundation

public struct FilenameSearchCandidate<ID: Hashable & Sendable>: Sendable {
    public let id: ID
    public let sxmFilename: String
    public let associatedDATFilenames: [String]

    public init(
        id: ID,
        sxmFilename: String,
        associatedDATFilenames: [String]
    ) {
        self.id = id
        self.sxmFilename = sxmFilename
        self.associatedDATFilenames = associatedDATFilenames
    }
}

public struct FilenameSearchProjection<ID: Hashable & Sendable>: Sendable {
    public let normalizedQuery: String
    public let matchingIDs: [ID]
    public let scopedCount: Int

    public init(
        query: String,
        candidates: [FilenameSearchCandidate<ID>]
    ) {
        let normalized = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        normalizedQuery = normalized
        scopedCount = candidates.count

        guard !normalized.isEmpty else {
            matchingIDs = candidates.map(\.id)
            return
        }

        matchingIDs = candidates.compactMap { candidate in
            let matchesSXM = candidate.sxmFilename
                .localizedCaseInsensitiveContains(normalized)
            let matchesDAT = candidate.associatedDATFilenames.contains {
                $0.localizedCaseInsensitiveContains(normalized)
            }
            return matchesSXM || matchesDAT ? candidate.id : nil
        }
    }

    public var matchedCount: Int {
        matchingIDs.count
    }
}

public struct FilenameSearchRequest: Sendable, Equatable {
    public let id: UUID
    public let query: String

    public init(id: UUID = UUID(), query: String) {
        self.id = id
        self.query = query
    }
}

public struct FilenameSearchRequestGate: Sendable {
    public private(set) var activeRequest: FilenameSearchRequest?

    public init() {
        activeRequest = nil
    }

    public mutating func begin(
        query: String,
        id: UUID = UUID()
    ) -> FilenameSearchRequest {
        let request = FilenameSearchRequest(id: id, query: query)
        activeRequest = request
        return request
    }

    public mutating func cancel() {
        activeRequest = nil
    }

    public func accepts(_ request: FilenameSearchRequest) -> Bool {
        activeRequest == request
    }
}
