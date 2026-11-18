import Foundation
import SXMBrowserCore

public struct DatasetPathItem<ID: Hashable & Sendable>: Hashable, Sendable {
    public let id: ID
    public let url: URL

    public init(id: ID, url: URL) {
        self.id = id
        self.url = url
    }
}

public enum DatasetPathIndexError: Error, Equatable, Sendable {
    case folderIsNotFileURL(URL)
    case itemIsNotFileURL(kind: DatasetFileKind, url: URL)
    case itemOutsideFolder(
        kind: DatasetFileKind,
        url: URL,
        folderURL: URL
    )
    case invalidRelativePath(
        kind: DatasetFileKind,
        url: URL,
        error: DatasetMetadataValidationError
    )
    case duplicateID(kind: DatasetFileKind, id: UUID)
    case duplicateRelativePath(
        kind: DatasetFileKind,
        path: DatasetRelativePath
    )
}

extension DatasetPathIndexError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .folderIsNotFileURL(url):
            "Dataset folder is not a file URL: \(url.absoluteString)"
        case let .itemIsNotFileURL(kind, url):
            "The \(kind.rawValue.uppercased()) item is not a file URL: "
                + url.absoluteString
        case let .itemOutsideFolder(kind, url, folderURL):
            "The \(kind.rawValue.uppercased()) item \(url.path) is outside "
                + "the dataset folder \(folderURL.path)."
        case let .invalidRelativePath(kind, url, error):
            "The \(kind.rawValue.uppercased()) item \(url.path) cannot be "
                + "indexed: \(error.localizedDescription)"
        case let .duplicateID(kind, id):
            "The \(kind.rawValue.uppercased()) file ID \(id.uuidString) "
                + "occurs more than once."
        case let .duplicateRelativePath(kind, path):
            "The \(kind.rawValue.uppercased()) relative path "
                + "“\(path.rawValue)” occurs more than once."
        }
    }
}

public struct DatasetPathIndex: Equatable, Sendable {
    public let folderURL: URL
    public let sxmPathByID: [UUID: DatasetRelativePath]
    public let sxmIDByPath: [DatasetRelativePath: UUID]
    public let datPathByID: [UUID: DatasetRelativePath]
    public let datIDByPath: [DatasetRelativePath: UUID]

    public init(
        folderURL: URL,
        sxmItems: [DatasetPathItem<UUID>],
        datItems: [DatasetPathItem<UUID>]
    ) throws {
        guard folderURL.isFileURL else {
            throw DatasetPathIndexError.folderIsNotFileURL(folderURL)
        }
        let canonicalFolderURL = Self.canonicalFileURL(
            folderURL,
            isDirectory: true
        )
        let sxmIndex = try Self.makeIndex(
            items: sxmItems,
            kind: .sxm,
            folderURL: canonicalFolderURL
        )
        let datIndex = try Self.makeIndex(
            items: datItems,
            kind: .dat,
            folderURL: canonicalFolderURL
        )

        self.folderURL = canonicalFolderURL
        sxmPathByID = sxmIndex.pathByID
        sxmIDByPath = sxmIndex.idByPath
        datPathByID = datIndex.pathByID
        datIDByPath = datIndex.idByPath
    }

    public init(
        folderURL: URL,
        sxmFiles: [SXMMetadata],
        spectroscopyFiles: [SpectroscopyFile]
    ) throws {
        try self.init(
            folderURL: folderURL,
            sxmItems: sxmFiles.map {
                DatasetPathItem(id: $0.id, url: $0.path)
            },
            datItems: spectroscopyFiles.map {
                DatasetPathItem(id: $0.id, url: $0.path)
            }
        )
    }

    public func sxmPath(for id: UUID) -> DatasetRelativePath? {
        sxmPathByID[id]
    }

    public func sxmID(for path: DatasetRelativePath) -> UUID? {
        sxmIDByPath[path]
    }

    public func datPath(for id: UUID) -> DatasetRelativePath? {
        datPathByID[id]
    }

    public func datID(for path: DatasetRelativePath) -> UUID? {
        datIDByPath[path]
    }

    private static func makeIndex(
        items: [DatasetPathItem<UUID>],
        kind: DatasetFileKind,
        folderURL: URL
    ) throws -> (
        pathByID: [UUID: DatasetRelativePath],
        idByPath: [DatasetRelativePath: UUID]
    ) {
        var pathByID: [UUID: DatasetRelativePath] = [:]
        var idByPath: [DatasetRelativePath: UUID] = [:]
        pathByID.reserveCapacity(items.count)
        idByPath.reserveCapacity(items.count)

        for item in items {
            guard item.url.isFileURL else {
                throw DatasetPathIndexError.itemIsNotFileURL(
                    kind: kind,
                    url: item.url
                )
            }
            guard pathByID[item.id] == nil else {
                throw DatasetPathIndexError.duplicateID(
                    kind: kind,
                    id: item.id
                )
            }

            let path = try relativePath(
                for: item.url,
                kind: kind,
                folderURL: folderURL
            )
            guard idByPath[path] == nil else {
                throw DatasetPathIndexError.duplicateRelativePath(
                    kind: kind,
                    path: path
                )
            }
            pathByID[item.id] = path
            idByPath[path] = item.id
        }
        return (pathByID, idByPath)
    }

    private static func relativePath(
        for itemURL: URL,
        kind: DatasetFileKind,
        folderURL: URL
    ) throws -> DatasetRelativePath {
        let canonicalItemURL = canonicalFileURL(
            itemURL,
            isDirectory: false
        )
        let folderComponents = canonicalPathComponents(folderURL)
        let itemComponents = canonicalPathComponents(canonicalItemURL)
        guard itemComponents.count > folderComponents.count,
              itemComponents.prefix(folderComponents.count)
                .elementsEqual(folderComponents) else {
            throw DatasetPathIndexError.itemOutsideFolder(
                kind: kind,
                url: canonicalItemURL,
                folderURL: folderURL
            )
        }

        let rawPath = itemComponents
            .dropFirst(folderComponents.count)
            .joined(separator: "/")
        do {
            return try DatasetRelativePath(rawPath, requiring: kind)
        } catch let error as DatasetMetadataValidationError {
            throw DatasetPathIndexError.invalidRelativePath(
                kind: kind,
                url: canonicalItemURL,
                error: error
            )
        }
    }

    private static func canonicalFileURL(
        _ url: URL,
        isDirectory: Bool
    ) -> URL {
        let path = url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        return URL(
            fileURLWithPath: path,
            isDirectory: isDirectory
        ).standardizedFileURL
    }

    private static func canonicalPathComponents(_ url: URL) -> [String] {
        url.pathComponents.map {
            $0.precomposedStringWithCanonicalMapping
        }
    }
}

public enum ActiveDatasetSessionError: Error, Equatable, Sendable {
    case datasetIdentityMismatch(expected: UUID, actual: UUID)
    case recordFolderMismatch(expected: String, actual: String)
    case pathIndexFolderMismatch(expected: String, actual: String)
}

extension ActiveDatasetSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .datasetIdentityMismatch(expected, actual):
            "Dataset session expected \(expected.uuidString), but the "
                + "verified record is \(actual.uuidString)."
        case let .recordFolderMismatch(expected, actual):
            "Dataset session folder \(expected) does not match the "
                + "verified record folder \(actual)."
        case let .pathIndexFolderMismatch(expected, actual):
            "Dataset session folder \(expected) does not match the path "
                + "index folder \(actual)."
        }
    }
}

public struct DatasetSessionIdentity: Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let datasetID: UUID
    public let folderPath: String

    public init(sessionID: UUID, datasetID: UUID, folderPath: String) {
        self.sessionID = sessionID
        self.datasetID = datasetID
        self.folderPath = folderPath
    }
}

public struct ActiveDatasetSession: Equatable, Sendable {
    public let sessionID: UUID
    public let datasetID: UUID
    public let folderURL: URL
    public let verifiedRecord: DatasetRecordV1
    public let pathIndex: DatasetPathIndex

    public init(
        sessionID: UUID = UUID(),
        datasetID: UUID,
        folderURL: URL,
        verifiedRecord: DatasetRecordV1,
        pathIndex: DatasetPathIndex
    ) throws {
        guard datasetID == verifiedRecord.id else {
            throw ActiveDatasetSessionError.datasetIdentityMismatch(
                expected: datasetID,
                actual: verifiedRecord.id
            )
        }
        let folderPath = try DatasetMetadataStore.standardizedFolderPath(
            for: folderURL
        )
        guard verifiedRecord.lastKnownPath == folderPath else {
            throw ActiveDatasetSessionError.recordFolderMismatch(
                expected: folderPath,
                actual: verifiedRecord.lastKnownPath
            )
        }
        let indexFolderPath = try DatasetMetadataStore
            .standardizedFolderPath(for: pathIndex.folderURL)
        guard indexFolderPath == folderPath else {
            throw ActiveDatasetSessionError.pathIndexFolderMismatch(
                expected: folderPath,
                actual: indexFolderPath
            )
        }

        self.sessionID = sessionID
        self.datasetID = datasetID
        self.folderURL = pathIndex.folderURL
        self.verifiedRecord = verifiedRecord
        self.pathIndex = pathIndex
    }

    public var identity: DatasetSessionIdentity {
        DatasetSessionIdentity(
            sessionID: sessionID,
            datasetID: datasetID,
            folderPath: verifiedRecord.lastKnownPath
        )
    }

    public func matches(_ identity: DatasetSessionIdentity) -> Bool {
        self.identity == identity
    }
}

public struct DatasetSessionGate: Equatable, Sendable {
    public private(set) var expectedSessionID: UUID?
    public private(set) var activeIdentity: DatasetSessionIdentity?

    public init() {}

    @discardableResult
    public mutating func begin(sessionID: UUID = UUID()) -> UUID {
        expectedSessionID = sessionID
        activeIdentity = nil
        return sessionID
    }

    public func acceptsOpeningResult(sessionID: UUID) -> Bool {
        expectedSessionID == sessionID
    }

    @discardableResult
    public mutating func activate(_ session: ActiveDatasetSession) -> Bool {
        guard acceptsOpeningResult(sessionID: session.sessionID) else {
            return false
        }
        activeIdentity = session.identity
        return true
    }

    public func accepts(_ session: ActiveDatasetSession) -> Bool {
        expectedSessionID == session.sessionID
            && activeIdentity == session.identity
    }

    public func accepts(_ identity: DatasetSessionIdentity) -> Bool {
        activeIdentity == identity
    }

    public mutating func invalidate() {
        expectedSessionID = nil
        activeIdentity = nil
    }
}
