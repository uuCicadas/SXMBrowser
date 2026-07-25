import Foundation

public protocol DatasetMetadataFileAccess: Sendable {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func readData(at url: URL) throws -> Data
    func writeDataAtomically(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
}

public struct FoundationDatasetMetadataFileAccess:
    DatasetMetadataFileAccess,
    Sendable
{
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

public enum DatasetMetadataStoreError: Error, Equatable, Sendable {
    case readFailed(fileURL: URL, message: String)
    case corruptDocument(fileURL: URL, message: String)
    case unsupportedSchemaVersion(fileURL: URL, version: Int)
    case encodingFailed(message: String)
    case directoryCreationFailed(directoryURL: URL, message: String)
    case writeFailed(
        fileURL: URL,
        message: String,
        rollbackFailure: String?
    )
    case verificationFailed(
        fileURL: URL,
        message: String,
        rollbackFailure: String?
    )
}

extension DatasetMetadataStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .readFailed(fileURL, message):
            "Could not read metadata at \(fileURL.path): \(message)"
        case let .corruptDocument(fileURL, message):
            "Metadata at \(fileURL.path) is invalid: \(message)"
        case let .unsupportedSchemaVersion(fileURL, version):
            "Metadata at \(fileURL.path) uses unsupported schema version "
                + "\(version)."
        case let .encodingFailed(message):
            "Could not encode metadata: \(message)"
        case let .directoryCreationFailed(directoryURL, message):
            "Could not create \(directoryURL.path): \(message)"
        case let .writeFailed(fileURL, message, rollbackFailure):
            operationDescription(
                prefix: "Could not write metadata at \(fileURL.path)",
                message: message,
                rollbackFailure: rollbackFailure
            )
        case let .verificationFailed(
            fileURL,
            message,
            rollbackFailure
        ):
            operationDescription(
                prefix: "Could not verify metadata at \(fileURL.path)",
                message: message,
                rollbackFailure: rollbackFailure
            )
        }
    }

    private func operationDescription(
        prefix: String,
        message: String,
        rollbackFailure: String?
    ) -> String {
        var description = "\(prefix): \(message)"
        if let rollbackFailure {
            description += " Rollback also failed: \(rollbackFailure)"
        }
        return description
    }
}

public actor DatasetMetadataStore {
    public nonisolated static var defaultFileURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupportURL
            .appendingPathComponent("SXM Browser", isDirectory: true)
            .appendingPathComponent("metadata-v1.json", isDirectory: false)
    }

    public nonisolated let fileURL: URL
    public private(set) var publishedDocument: DatasetMetadataDocumentV1?

    private let fileAccess: any DatasetMetadataFileAccess
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL = DatasetMetadataStore.defaultFileURL,
        fileAccess: any DatasetMetadataFileAccess =
            FoundationDatasetMetadataFileAccess()
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileAccess = fileAccess

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    @discardableResult
    public func load() throws -> DatasetMetadataDocumentV1 {
        let snapshot = try loadSnapshot()
        publishedDocument = snapshot.document
        return snapshot.document
    }

    @discardableResult
    public func transaction(
        _ mutation: @Sendable (
            inout DatasetMetadataDocumentV1
        ) throws -> Void
    ) throws -> DatasetMetadataDocumentV1 {
        let snapshot = try loadSnapshot()
        var candidate = snapshot.document
        try mutation(&candidate)

        let expectedData = try validatedEncoding(of: candidate)
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileAccess.createDirectory(at: directoryURL)
        } catch {
            throw DatasetMetadataStoreError.directoryCreationFailed(
                directoryURL: directoryURL,
                message: errorMessage(error)
            )
        }

        do {
            try fileAccess.writeDataAtomically(expectedData, to: fileURL)
        } catch {
            let rollbackFailure = rollback(to: snapshot)
            throw DatasetMetadataStoreError.writeFailed(
                fileURL: fileURL,
                message: errorMessage(error),
                rollbackFailure: rollbackFailure
            )
        }

        let verifiedDocument: DatasetMetadataDocumentV1
        do {
            let writtenData = try fileAccess.readData(at: fileURL)
            verifiedDocument = try decodeDocument(from: writtenData)
            let canonicalWrittenData = try encode(verifiedDocument)
            guard canonicalWrittenData == expectedData else {
                throw VerificationMismatch()
            }
        } catch {
            let rollbackFailure = rollback(to: snapshot)
            throw DatasetMetadataStoreError.verificationFailed(
                fileURL: fileURL,
                message: errorMessage(error),
                rollbackFailure: rollbackFailure
            )
        }

        publishedDocument = verifiedDocument
        return verifiedDocument
    }

    public func dataset(
        forFolderURL folderURL: URL
    ) throws -> DatasetRecordV1? {
        let path = try Self.standardizedFolderPath(for: folderURL)
        return try load().datasets.first { dataset in
            dataset.lastKnownPath == path
        }
    }

    public func lastOpenedDataset() throws -> DatasetRecordV1? {
        let document = try load()
        guard let id = document.lastOpenedDatasetID else { return nil }
        return document.datasets.first { $0.id == id }
    }

    @discardableResult
    public func findOrCreateDataset(
        forFolderURL folderURL: URL,
        folderBookmark: Data? = nil,
        updatedAt: Date = .now
    ) throws -> DatasetRecordV1 {
        let path = try Self.standardizedFolderPath(for: folderURL)
        let verified = try transaction { document in
            if var existing = document.datasets.first(where: {
                $0.lastKnownPath == path
            }) {
                try existing.updateFolderIdentity(
                    folderBookmark:
                        folderBookmark ?? existing.folderBookmark,
                    lastKnownPath: path,
                    updatedAt: updatedAt
                )
                document.upsertDataset(existing)
                try document.setLastOpenedDatasetID(existing.id)
            } else {
                let created = try DatasetRecordV1(
                    folderBookmark: folderBookmark,
                    lastKnownPath: path,
                    updatedAt: updatedAt
                )
                document.upsertDataset(created)
                try document.setLastOpenedDatasetID(created.id)
            }
        }
        guard let dataset = verified.datasets.first(where: {
            $0.lastKnownPath == path
        }) else {
            throw DatasetMetadataStoreError.verificationFailed(
                fileURL: fileURL,
                message: "The verified document omitted the opened dataset.",
                rollbackFailure: nil
            )
        }
        return dataset
    }

    @discardableResult
    public func rebindDataset(
        id: UUID,
        toFolderURL folderURL: URL,
        folderBookmark: Data? = nil,
        updatedAt: Date = .now
    ) throws -> DatasetRecordV1 {
        let path = try Self.standardizedFolderPath(for: folderURL)
        let verified = try transaction { document in
            guard var existing = document.datasets.first(where: {
                $0.id == id
            }) else {
                throw DatasetMetadataValidationError.datasetNotFound(id)
            }
            try existing.updateFolderIdentity(
                folderBookmark: folderBookmark ?? existing.folderBookmark,
                lastKnownPath: path,
                updatedAt: updatedAt
            )
            try document.replaceDataset(existing)
            try document.setLastOpenedDatasetID(id)
        }
        guard let dataset = verified.datasets.first(where: {
            $0.id == id
        }) else {
            throw DatasetMetadataStoreError.verificationFailed(
                fileURL: fileURL,
                message: "The verified document omitted the rebound dataset.",
                rollbackFailure: nil
            )
        }
        return dataset
    }

    public nonisolated static func standardizedFolderPath(
        for folderURL: URL
    ) throws -> String {
        guard folderURL.isFileURL else {
            throw DatasetMetadataValidationError.invalidLastKnownPath(
                folderURL.absoluteString
            )
        }
        let path = folderURL.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        guard !path.isEmpty else {
            throw DatasetMetadataValidationError.invalidLastKnownPath(
                folderURL.path
            )
        }
        return path
    }

    private func loadSnapshot() throws -> DiskSnapshot {
        guard fileAccess.fileExists(at: fileURL) else {
            let empty = try DatasetMetadataDocumentV1()
            return DiskSnapshot(
                originalData: nil,
                document: empty
            )
        }

        let data: Data
        do {
            data = try fileAccess.readData(at: fileURL)
        } catch {
            throw DatasetMetadataStoreError.readFailed(
                fileURL: fileURL,
                message: errorMessage(error)
            )
        }
        return DiskSnapshot(
            originalData: data,
            document: try decodeStoredDocument(from: data)
        )
    }

    private func validatedEncoding(
        of document: DatasetMetadataDocumentV1
    ) throws -> Data {
        let firstEncoding = try encode(document)
        let validated: DatasetMetadataDocumentV1
        do {
            validated = try decodeDocument(from: firstEncoding)
        } catch {
            throw DatasetMetadataStoreError.encodingFailed(
                message: errorMessage(error)
            )
        }
        return try encode(validated)
    }

    private func encode(
        _ document: DatasetMetadataDocumentV1
    ) throws -> Data {
        do {
            return try encoder.encode(document)
        } catch {
            throw DatasetMetadataStoreError.encodingFailed(
                message: errorMessage(error)
            )
        }
    }

    private func decodeStoredDocument(
        from data: Data
    ) throws -> DatasetMetadataDocumentV1 {
        do {
            return try decodeDocument(from: data)
        } catch let error as DatasetMetadataValidationError {
            if case let .unsupportedSchemaVersion(version) = error {
                throw DatasetMetadataStoreError.unsupportedSchemaVersion(
                    fileURL: fileURL,
                    version: version
                )
            }
            throw DatasetMetadataStoreError.corruptDocument(
                fileURL: fileURL,
                message: errorMessage(error)
            )
        } catch {
            throw DatasetMetadataStoreError.corruptDocument(
                fileURL: fileURL,
                message: errorMessage(error)
            )
        }
    }

    private func decodeDocument(
        from data: Data
    ) throws -> DatasetMetadataDocumentV1 {
        try decoder.decode(DatasetMetadataDocumentV1.self, from: data)
    }

    private func rollback(to snapshot: DiskSnapshot) -> String? {
        do {
            if let originalData = snapshot.originalData {
                try fileAccess.createDirectory(
                    at: fileURL.deletingLastPathComponent()
                )
                try fileAccess.writeDataAtomically(
                    originalData,
                    to: fileURL
                )
            } else if fileAccess.fileExists(at: fileURL) {
                try fileAccess.removeItem(at: fileURL)
            }
            return nil
        } catch {
            return errorMessage(error)
        }
    }
}

private struct DiskSnapshot: Sendable {
    let originalData: Data?
    let document: DatasetMetadataDocumentV1
}

private struct VerificationMismatch: Error {}

private func errorMessage(_ error: Error) -> String {
    if let localizedError = error as? LocalizedError,
       let description = localizedError.errorDescription {
        return description
    }
    return String(describing: error)
}
