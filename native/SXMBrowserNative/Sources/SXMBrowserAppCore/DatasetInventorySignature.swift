import Foundation

public enum DatasetInventorySignatureError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedPath(DatasetRelativePath)
    case nestedPath(DatasetRelativePath)
    case duplicatePath(DatasetRelativePath)
    case invalidModificationDate(DatasetRelativePath)
}

extension DatasetInventorySignatureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedPath(let path):
            "Inventory signatures support only .sxm and .dat files: "
                + path.rawValue
        case .nestedPath(let path):
            "Inventory signatures require top-level dataset files: "
                + path.rawValue
        case .duplicatePath(let path):
            "The inventory signature contains duplicate path "
                + "“\(path.rawValue)”."
        case .invalidModificationDate(let path):
            "The modification date for “\(path.rawValue)” is invalid."
        }
    }
}

public struct DatasetInventoryFileStamp: Equatable, Sendable {
    public let path: DatasetRelativePath
    public let byteCount: UInt64
    public let modifiedAt: Date

    public init(
        path: DatasetRelativePath,
        byteCount: UInt64,
        modifiedAt: Date
    ) throws {
        let fileExtension = path.pathExtension?
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard fileExtension == DatasetFileKind.sxm.fileExtension
                || fileExtension == DatasetFileKind.dat.fileExtension else {
            throw DatasetInventorySignatureError.unsupportedPath(path)
        }
        guard !path.rawValue.contains("/") else {
            throw DatasetInventorySignatureError.nestedPath(path)
        }
        guard modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DatasetInventorySignatureError
                .invalidModificationDate(path)
        }
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct DatasetInventorySignature: Equatable, Sendable {
    public let files: [DatasetInventoryFileStamp]

    public init(files: [DatasetInventoryFileStamp]) throws {
        var seen: Set<DatasetRelativePath> = []
        for file in files {
            guard seen.insert(file.path).inserted else {
                throw DatasetInventorySignatureError
                    .duplicatePath(file.path)
            }
        }
        self.files = files.sorted {
            $0.path < $1.path
        }
    }
}
