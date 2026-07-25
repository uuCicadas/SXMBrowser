import Foundation

public struct FolderBookmarkResolution: Equatable, Sendable {
    public let folderURL: URL
    public let isStale: Bool

    public init(folderURL: URL, isStale: Bool) {
        self.folderURL = folderURL
        self.isStale = isStale
    }
}

public protocol FolderBookmarking: Sendable {
    func createBookmark(for folderURL: URL) throws -> Data?
    func resolveBookmark(
        _ bookmarkData: Data?
    ) throws -> FolderBookmarkResolution?
}

public struct MacOSFolderBookmarker: FolderBookmarking, Sendable {
    public init() {}

    public func createBookmark(for folderURL: URL) throws -> Data? {
        try folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolveBookmark(
        _ bookmarkData: Data?
    ) throws -> FolderBookmarkResolution? {
        guard let bookmarkData else { return nil }
        var isStale = false
        let folderURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return FolderBookmarkResolution(
            folderURL: folderURL,
            isStale: isStale
        )
    }
}
