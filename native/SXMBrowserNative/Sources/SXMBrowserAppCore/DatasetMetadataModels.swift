import Foundation
import SXMBrowserCore

public enum DatasetFileKind: String, Codable, Hashable, Sendable {
    case sxm
    case dat

    public var fileExtension: String { rawValue }
}

public enum DatasetRelativePathInvalidReason: Equatable, Sendable {
    case empty
    case absolute
    case containsNUL
    case containsBackslash
    case emptyComponent
    case dotComponent
    case parentComponent
}

public enum DatasetMetadataValidationError: Error, Equatable, Sendable {
    case invalidRelativePath(
        rawValue: String,
        reason: DatasetRelativePathInvalidReason
    )
    case unexpectedFileExtension(
        path: String,
        expected: DatasetFileKind,
        actual: String?
    )
    case unsupportedSchemaVersion(Int)
    case duplicateDatasetID(UUID)
    case datasetNotFound(UUID)
    case lastOpenedDatasetMissing(UUID)
    case emptyFolderBookmark
    case invalidLastKnownPath(String)
    case invalidUpdatedAt
    case invalidTagName
    case duplicateTagID(UUID)
    case duplicateTagName(String)
    case tagNotFound(UUID)
    case tagIndexOutOfBounds(Int)
    case conflictingManualAssociation(DatasetRelativePath)
    case invalidSchemaFingerprint(String)
    case invalidAxisColumn
    case conflictingAxisPreference(SpectrumAxisPreferenceKeyV1)
}

extension DatasetMetadataValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(rawValue, reason):
            "Invalid dataset-relative path “\(rawValue)”: \(reason)."
        case let .unexpectedFileExtension(path, expected, actual):
            "Expected a .\(expected.fileExtension) path, but “\(path)” has "
                + (actual.map { "a .\($0) extension." } ?? "no extension.")
        case let .unsupportedSchemaVersion(version):
            "Unsupported metadata schema version \(version)."
        case let .duplicateDatasetID(id):
            "Dataset ID \(id.uuidString) occurs more than once."
        case let .datasetNotFound(id):
            "Dataset \(id.uuidString) does not exist."
        case let .lastOpenedDatasetMissing(id):
            "Last-opened dataset \(id.uuidString) is not in this document."
        case .emptyFolderBookmark:
            "A stored folder bookmark cannot be empty."
        case let .invalidLastKnownPath(path):
            "The last-known dataset path is invalid: “\(path)”."
        case .invalidUpdatedAt:
            "The metadata update time must be finite."
        case .invalidTagName:
            "A tag name cannot be empty or contain a NUL character."
        case let .duplicateTagID(id):
            "Tag ID \(id.uuidString) occurs more than once."
        case let .duplicateTagName(name):
            "Tag name “\(name)” conflicts with an existing tag."
        case let .tagNotFound(id):
            "Tag \(id.uuidString) does not exist."
        case let .tagIndexOutOfBounds(index):
            "Tag position \(index) is outside the valid range."
        case let .conflictingManualAssociation(path):
            "DAT file “\(path.rawValue)” has multiple manual SXM associations."
        case let .invalidSchemaFingerprint(fingerprint):
            "“\(fingerprint)” is not a valid spectroscopy schema fingerprint."
        case .invalidAxisColumn:
            "A spectrum axis column cannot be empty or contain a NUL character."
        case let .conflictingAxisPreference(key):
            "Spectrum group “\(key.stableIdentifier)” has conflicting axis preferences."
        }
    }
}

public struct DatasetRelativePath:
    Codable,
    Comparable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else {
            throw DatasetMetadataValidationError.invalidRelativePath(
                rawValue: rawValue,
                reason: .empty
            )
        }
        guard !normalized.hasPrefix("/") else {
            throw DatasetMetadataValidationError.invalidRelativePath(
                rawValue: rawValue,
                reason: .absolute
            )
        }
        guard !normalized.contains("\0") else {
            throw DatasetMetadataValidationError.invalidRelativePath(
                rawValue: rawValue,
                reason: .containsNUL
            )
        }
        guard !normalized.contains("\\") else {
            throw DatasetMetadataValidationError.invalidRelativePath(
                rawValue: rawValue,
                reason: .containsBackslash
            )
        }

        let components = normalized.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        for component in components {
            if component.isEmpty {
                throw DatasetMetadataValidationError.invalidRelativePath(
                    rawValue: rawValue,
                    reason: .emptyComponent
                )
            }
            if component == "." {
                throw DatasetMetadataValidationError.invalidRelativePath(
                    rawValue: rawValue,
                    reason: .dotComponent
                )
            }
            if component == ".." {
                throw DatasetMetadataValidationError.invalidRelativePath(
                    rawValue: rawValue,
                    reason: .parentComponent
                )
            }
        }
        self.rawValue = normalized
    }

    public init(_ rawValue: String, requiring fileKind: DatasetFileKind) throws {
        let path = try DatasetRelativePath(rawValue)
        try path.validateFileKind(fileKind)
        self = path
    }

    public static func sxm(_ rawValue: String) throws -> DatasetRelativePath {
        try DatasetRelativePath(rawValue, requiring: .sxm)
    }

    public static func dat(_ rawValue: String) throws -> DatasetRelativePath {
        try DatasetRelativePath(rawValue, requiring: .dat)
    }

    public var pathExtension: String? {
        guard let filename = rawValue.split(separator: "/").last,
              let dot = filename.lastIndex(of: "."),
              dot != filename.startIndex else {
            return nil
        }
        let value = filename[filename.index(after: dot)...]
        return value.isEmpty ? nil : String(value)
    }

    @discardableResult
    public func validated(
        for fileKind: DatasetFileKind
    ) throws -> DatasetRelativePath {
        try validateFileKind(fileKind)
        return self
    }

    public var description: String { rawValue }

    public static func < (
        lhs: DatasetRelativePath,
        rhs: DatasetRelativePath
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private func validateFileKind(_ fileKind: DatasetFileKind) throws {
        let actual = pathExtension?.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
        guard actual == fileKind.fileExtension else {
            throw DatasetMetadataValidationError.unexpectedFileExtension(
                path: rawValue,
                expected: fileKind,
                actual: pathExtension
            )
        }
    }
}

public struct DatasetTagV1:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID
    public private(set) var name: String
    public private(set) var sxmPaths: [DatasetRelativePath]

    public init(
        id: UUID = UUID(),
        name: String,
        sxmPaths: [DatasetRelativePath] = []
    ) throws {
        self.id = id
        self.name = try canonicalTagName(name)
        self.sxmPaths = try orderedUnique(sxmPaths) { path in
            try path.validated(for: .sxm)
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        sxmPathStrings: [String]
    ) throws {
        try self.init(
            id: id,
            name: name,
            sxmPaths: sxmPathStrings.map(DatasetRelativePath.sxm)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sxmPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            sxmPaths: container.decode(
                [DatasetRelativePath].self,
                forKey: .sxmPaths
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sxmPaths, forKey: .sxmPaths)
    }
}

public struct DatasetManualAssociationV1: Codable, Hashable, Sendable {
    public let datPath: DatasetRelativePath
    public let sxmPath: DatasetRelativePath

    public init(
        datPath: DatasetRelativePath,
        sxmPath: DatasetRelativePath
    ) throws {
        self.datPath = try datPath.validated(for: .dat)
        self.sxmPath = try sxmPath.validated(for: .sxm)
    }

    public init(datPath: String, sxmPath: String) throws {
        try self.init(
            datPath: DatasetRelativePath.dat(datPath),
            sxmPath: DatasetRelativePath.sxm(sxmPath)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case datPath
        case sxmPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            datPath: container.decode(
                DatasetRelativePath.self,
                forKey: .datPath
            ),
            sxmPath: container.decode(
                DatasetRelativePath.self,
                forKey: .sxmPath
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(datPath, forKey: .datPath)
        try container.encode(sxmPath, forKey: .sxmPath)
    }
}

public struct SpectrumAxisPreferenceKeyV1: Codable, Hashable, Sendable {
    public let sxmPath: DatasetRelativePath
    public let kind: SpectroscopyKind
    public let schemaFingerprint: String

    public init(
        sxmPath: DatasetRelativePath,
        kind: SpectroscopyKind,
        schemaFingerprint: String
    ) throws {
        self.sxmPath = try sxmPath.validated(for: .sxm)
        self.kind = kind
        self.schemaFingerprint = try canonicalSchemaFingerprint(
            schemaFingerprint
        )
    }

    public init(
        sxmPath: String,
        kind: SpectroscopyKind,
        schemaFingerprint: String
    ) throws {
        try self.init(
            sxmPath: DatasetRelativePath.sxm(sxmPath),
            kind: kind,
            schemaFingerprint: schemaFingerprint
        )
    }

    public var stableIdentifier: String {
        "\(sxmPath.rawValue)|\(kind.rawValue)|\(schemaFingerprint)"
    }

    public static func == (
        lhs: SpectrumAxisPreferenceKeyV1,
        rhs: SpectrumAxisPreferenceKeyV1
    ) -> Bool {
        lhs.sxmPath == rhs.sxmPath
            && lhs.kind.rawValue == rhs.kind.rawValue
            && lhs.schemaFingerprint == rhs.schemaFingerprint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sxmPath)
        hasher.combine(kind.rawValue)
        hasher.combine(schemaFingerprint)
    }

    private enum CodingKeys: String, CodingKey {
        case sxmPath
        case kind
        case schemaFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sxmPath: container.decode(
                DatasetRelativePath.self,
                forKey: .sxmPath
            ),
            kind: container.decode(
                SpectroscopyKind.self,
                forKey: .kind
            ),
            schemaFingerprint: container.decode(
                String.self,
                forKey: .schemaFingerprint
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sxmPath, forKey: .sxmPath)
        try container.encode(kind, forKey: .kind)
        try container.encode(schemaFingerprint, forKey: .schemaFingerprint)
    }
}

public struct SpectrumAxisPreferenceV1: Codable, Hashable, Sendable {
    public let key: SpectrumAxisPreferenceKeyV1
    public let selection: AxisSelection

    public init(
        key: SpectrumAxisPreferenceKeyV1,
        selection: AxisSelection
    ) throws {
        self.key = key
        self.selection = AxisSelection(
            xColumn: try canonicalAxisColumn(selection.xColumn),
            yColumn: try canonicalAxisColumn(selection.yColumn)
        )
    }

    public init(
        sxmPath: String,
        kind: SpectroscopyKind,
        schemaFingerprint: String,
        selection: AxisSelection
    ) throws {
        try self.init(
            key: SpectrumAxisPreferenceKeyV1(
                sxmPath: sxmPath,
                kind: kind,
                schemaFingerprint: schemaFingerprint
            ),
            selection: selection
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case selection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: container.decode(
                SpectrumAxisPreferenceKeyV1.self,
                forKey: .key
            ),
            selection: container.decode(
                AxisSelection.self,
                forKey: .selection
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(selection, forKey: .selection)
    }
}

public struct DatasetRecordV1: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public private(set) var folderBookmark: Data?
    public private(set) var lastKnownPath: String
    public private(set) var tags: [DatasetTagV1]
    public private(set) var manualAssociations: [DatasetManualAssociationV1]
    public private(set) var hiddenDATPaths: [DatasetRelativePath]
    public private(set) var spectrumAxisPreferences: [SpectrumAxisPreferenceV1]
    public private(set) var updatedAt: Date

    public init(
        id: UUID = UUID(),
        folderBookmark: Data? = nil,
        lastKnownPath: String,
        tags: [DatasetTagV1] = [],
        manualAssociations: [DatasetManualAssociationV1] = [],
        hiddenDATPaths: [DatasetRelativePath] = [],
        spectrumAxisPreferences: [SpectrumAxisPreferenceV1] = [],
        updatedAt: Date
    ) throws {
        if let folderBookmark, folderBookmark.isEmpty {
            throw DatasetMetadataValidationError.emptyFolderBookmark
        }
        let canonicalLastKnownPath = try canonicalDatasetFolderPath(
            lastKnownPath
        )
        try validateUpdateDate(updatedAt)

        self.id = id
        self.folderBookmark = folderBookmark
        self.lastKnownPath = canonicalLastKnownPath
        self.tags = try validateTags(tags)
        self.manualAssociations = try canonicalAssociations(
            manualAssociations
        )
        self.hiddenDATPaths = try orderedUnique(hiddenDATPaths) { path in
            try path.validated(for: .dat)
        }
        self.spectrumAxisPreferences = try canonicalAxisPreferences(
            spectrumAxisPreferences
        )
        self.updatedAt = updatedAt
    }

    public mutating func updateFolderIdentity(
        folderBookmark: Data?,
        lastKnownPath: String,
        updatedAt: Date
    ) throws {
        if let folderBookmark, folderBookmark.isEmpty {
            throw DatasetMetadataValidationError.emptyFolderBookmark
        }
        let canonicalPath = try canonicalDatasetFolderPath(lastKnownPath)
        try validateUpdateDate(updatedAt)

        self.folderBookmark = folderBookmark
        self.lastKnownPath = canonicalPath
        self.updatedAt = updatedAt
    }

    public mutating func markUpdated(at updatedAt: Date) throws {
        try validateUpdateDate(updatedAt)
        self.updatedAt = updatedAt
    }

    public mutating func replaceManualAssociations(
        with associations: [DatasetManualAssociationV1],
        updatedAt: Date
    ) throws {
        try validateUpdateDate(updatedAt)
        let canonical = try canonicalAssociations(associations)
        manualAssociations = canonical
        self.updatedAt = updatedAt
    }

    public mutating func replaceHiddenDATPaths(
        with paths: [DatasetRelativePath],
        updatedAt: Date
    ) throws {
        try validateUpdateDate(updatedAt)
        let canonical = try orderedUnique(paths) { path in
            try path.validated(for: .dat)
        }
        hiddenDATPaths = canonical
        self.updatedAt = updatedAt
    }

    public mutating func replaceSpectrumAxisPreferences(
        with preferences: [SpectrumAxisPreferenceV1],
        updatedAt: Date
    ) throws {
        try validateUpdateDate(updatedAt)
        let canonical = try canonicalAxisPreferences(preferences)
        spectrumAxisPreferences = canonical
        self.updatedAt = updatedAt
    }

    @discardableResult
    public mutating func createTag(
        id: UUID = UUID(),
        name: String,
        sxmPaths: [DatasetRelativePath] = []
    ) throws -> DatasetTagV1 {
        guard !tags.contains(where: { $0.id == id }) else {
            throw DatasetMetadataValidationError.duplicateTagID(id)
        }
        let newTag = try DatasetTagV1(
            id: id,
            name: name,
            sxmPaths: sxmPaths
        )
        try ensureUniqueTagName(newTag.name, excluding: nil)
        tags.append(newTag)
        return newTag
    }

    public mutating func renameTag(
        id: UUID,
        to name: String
    ) throws {
        guard let index = tags.firstIndex(where: { $0.id == id }) else {
            throw DatasetMetadataValidationError.tagNotFound(id)
        }
        let renamed = try DatasetTagV1(
            id: tags[index].id,
            name: name,
            sxmPaths: tags[index].sxmPaths
        )
        try ensureUniqueTagName(renamed.name, excluding: id)
        tags[index] = renamed
    }

    @discardableResult
    public mutating func deleteTag(id: UUID) -> DatasetTagV1? {
        guard let index = tags.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return tags.remove(at: index)
    }

    public mutating func replaceTagMembers(
        id: UUID,
        with sxmPaths: [DatasetRelativePath]
    ) throws {
        guard let index = tags.firstIndex(where: { $0.id == id }) else {
            throw DatasetMetadataValidationError.tagNotFound(id)
        }
        tags[index] = try DatasetTagV1(
            id: tags[index].id,
            name: tags[index].name,
            sxmPaths: sxmPaths
        )
    }

    @discardableResult
    public mutating func mergeTag(
        id: UUID = UUID(),
        name: String,
        sxmPaths: [DatasetRelativePath]
    ) throws -> DatasetTagV1 {
        let candidate = try DatasetTagV1(
            id: id,
            name: name,
            sxmPaths: sxmPaths
        )
        let comparisonKey = canonicalTagComparisonKey(candidate.name)

        if let index = tags.firstIndex(where: {
            canonicalTagComparisonKey($0.name) == comparisonKey
        }) {
            let existing = tags[index]
            let merged = try DatasetTagV1(
                id: existing.id,
                name: existing.name,
                sxmPaths: existing.sxmPaths + candidate.sxmPaths
            )
            tags[index] = merged
            return merged
        }

        guard !tags.contains(where: { $0.id == candidate.id }) else {
            throw DatasetMetadataValidationError.duplicateTagID(candidate.id)
        }
        tags.append(candidate)
        return candidate
    }

    public mutating func moveTag(
        id: UUID,
        to destinationIndex: Int
    ) throws {
        guard let sourceIndex = tags.firstIndex(where: { $0.id == id }) else {
            throw DatasetMetadataValidationError.tagNotFound(id)
        }
        guard tags.indices.contains(destinationIndex) else {
            throw DatasetMetadataValidationError.tagIndexOutOfBounds(
                destinationIndex
            )
        }
        guard sourceIndex != destinationIndex else { return }
        let tag = tags.remove(at: sourceIndex)
        tags.insert(tag, at: destinationIndex)
    }

    public mutating func sortTagsByName() {
        tags.sort { lhs, rhs in
            let lhsKey = canonicalTagComparisonKey(lhs.name)
            let rhsKey = canonicalTagComparisonKey(rhs.name)
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func ensureUniqueTagName(
        _ name: String,
        excluding excludedID: UUID?
    ) throws {
        let key = canonicalTagComparisonKey(name)
        if tags.contains(where: {
            $0.id != excludedID
                && canonicalTagComparisonKey($0.name) == key
        }) {
            throw DatasetMetadataValidationError.duplicateTagName(name)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case folderBookmark
        case lastKnownPath
        case tags
        case manualAssociations
        case hiddenDATPaths
        case spectrumAxisPreferences
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            folderBookmark: container.decodeIfPresent(
                Data.self,
                forKey: .folderBookmark
            ),
            lastKnownPath: container.decode(
                String.self,
                forKey: .lastKnownPath
            ),
            tags: container.decode(
                [DatasetTagV1].self,
                forKey: .tags
            ),
            manualAssociations: container.decode(
                [DatasetManualAssociationV1].self,
                forKey: .manualAssociations
            ),
            hiddenDATPaths: container.decode(
                [DatasetRelativePath].self,
                forKey: .hiddenDATPaths
            ),
            spectrumAxisPreferences: container.decode(
                [SpectrumAxisPreferenceV1].self,
                forKey: .spectrumAxisPreferences
            ),
            updatedAt: container.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(
            folderBookmark,
            forKey: .folderBookmark
        )
        try container.encode(lastKnownPath, forKey: .lastKnownPath)
        try container.encode(tags, forKey: .tags)
        try container.encode(
            manualAssociations,
            forKey: .manualAssociations
        )
        try container.encode(hiddenDATPaths, forKey: .hiddenDATPaths)
        try container.encode(
            spectrumAxisPreferences,
            forKey: .spectrumAxisPreferences
        )
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct DatasetMetadataDocumentV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public private(set) var lastOpenedDatasetID: UUID?
    public private(set) var datasets: [DatasetRecordV1]

    public init(
        schemaVersion: Int = DatasetMetadataDocumentV1.currentSchemaVersion,
        lastOpenedDatasetID: UUID? = nil,
        datasets: [DatasetRecordV1] = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DatasetMetadataValidationError.unsupportedSchemaVersion(
                schemaVersion
            )
        }

        var seenIDs: Set<UUID> = []
        for dataset in datasets where !seenIDs.insert(dataset.id).inserted {
            throw DatasetMetadataValidationError.duplicateDatasetID(
                dataset.id
            )
        }
        if let lastOpenedDatasetID,
           !seenIDs.contains(lastOpenedDatasetID) {
            throw DatasetMetadataValidationError.lastOpenedDatasetMissing(
                lastOpenedDatasetID
            )
        }

        self.schemaVersion = schemaVersion
        self.lastOpenedDatasetID = lastOpenedDatasetID
        self.datasets = datasets
    }

    public mutating func upsertDataset(_ dataset: DatasetRecordV1) {
        if let index = datasets.firstIndex(where: { $0.id == dataset.id }) {
            datasets[index] = dataset
        } else {
            datasets.append(dataset)
        }
    }

    public mutating func replaceDataset(
        _ dataset: DatasetRecordV1
    ) throws {
        guard let index = datasets.firstIndex(where: {
            $0.id == dataset.id
        }) else {
            throw DatasetMetadataValidationError.datasetNotFound(dataset.id)
        }
        datasets[index] = dataset
    }

    @discardableResult
    public mutating func removeDataset(id: UUID) -> DatasetRecordV1? {
        guard let index = datasets.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = datasets.remove(at: index)
        if lastOpenedDatasetID == id {
            lastOpenedDatasetID = nil
        }
        return removed
    }

    public mutating func setLastOpenedDatasetID(_ id: UUID?) throws {
        if let id, !datasets.contains(where: { $0.id == id }) {
            throw DatasetMetadataValidationError.lastOpenedDatasetMissing(id)
        }
        lastOpenedDatasetID = id
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lastOpenedDatasetID
        case datasets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(
                Int.self,
                forKey: .schemaVersion
            ),
            lastOpenedDatasetID: container.decodeIfPresent(
                UUID.self,
                forKey: .lastOpenedDatasetID
            ),
            datasets: container.decode(
                [DatasetRecordV1].self,
                forKey: .datasets
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(
            lastOpenedDatasetID,
            forKey: .lastOpenedDatasetID
        )
        try container.encode(datasets, forKey: .datasets)
    }
}

func canonicalTagName(_ name: String) throws -> String {
    let canonical = name
        .precomposedStringWithCanonicalMapping
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonical.isEmpty, !canonical.contains("\0") else {
        throw DatasetMetadataValidationError.invalidTagName
    }
    return canonical
}

func canonicalTagComparisonKey(_ name: String) -> String {
    name
        .precomposedStringWithCanonicalMapping
        .folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
}

private func canonicalDatasetFolderPath(_ path: String) throws -> String {
    let canonical = path.precomposedStringWithCanonicalMapping
    guard canonical.hasPrefix("/"),
          canonical.count > 1 || canonical == "/",
          !canonical.contains("\0") else {
        throw DatasetMetadataValidationError.invalidLastKnownPath(path)
    }
    return canonical
}

private func canonicalSchemaFingerprint(
    _ fingerprint: String
) throws -> String {
    let canonical = fingerprint
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
    let isLowercaseHex = canonical.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
    }
    guard canonical.utf8.count == 16, isLowercaseHex else {
        throw DatasetMetadataValidationError.invalidSchemaFingerprint(
            fingerprint
        )
    }
    return canonical
}

private func canonicalAxisColumn(_ column: String) throws -> String {
    let canonical = column
        .precomposedStringWithCanonicalMapping
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonical.isEmpty, !canonical.contains("\0") else {
        throw DatasetMetadataValidationError.invalidAxisColumn
    }
    return canonical
}

private func validateUpdateDate(_ date: Date) throws {
    guard date.timeIntervalSinceReferenceDate.isFinite else {
        throw DatasetMetadataValidationError.invalidUpdatedAt
    }
}

private func validateTags(
    _ tags: [DatasetTagV1]
) throws -> [DatasetTagV1] {
    var seenIDs: Set<UUID> = []
    var seenNames: Set<String> = []
    for tag in tags {
        guard seenIDs.insert(tag.id).inserted else {
            throw DatasetMetadataValidationError.duplicateTagID(tag.id)
        }
        let key = canonicalTagComparisonKey(tag.name)
        guard seenNames.insert(key).inserted else {
            throw DatasetMetadataValidationError.duplicateTagName(tag.name)
        }
    }
    return tags
}

private func canonicalAssociations(
    _ associations: [DatasetManualAssociationV1]
) throws -> [DatasetManualAssociationV1] {
    var targetByDATPath: [
        DatasetRelativePath: DatasetRelativePath
    ] = [:]
    var result: [DatasetManualAssociationV1] = []
    for association in associations {
        _ = try association.datPath.validated(for: .dat)
        _ = try association.sxmPath.validated(for: .sxm)
        if let existing = targetByDATPath[association.datPath] {
            guard existing == association.sxmPath else {
                throw DatasetMetadataValidationError
                    .conflictingManualAssociation(association.datPath)
            }
            continue
        }
        targetByDATPath[association.datPath] = association.sxmPath
        result.append(association)
    }
    return result
}

private func canonicalAxisPreferences(
    _ preferences: [SpectrumAxisPreferenceV1]
) throws -> [SpectrumAxisPreferenceV1] {
    var selectionByKey: [
        SpectrumAxisPreferenceKeyV1: AxisSelection
    ] = [:]
    var result: [SpectrumAxisPreferenceV1] = []
    for preference in preferences {
        if let existing = selectionByKey[preference.key] {
            guard existing == preference.selection else {
                throw DatasetMetadataValidationError
                    .conflictingAxisPreference(preference.key)
            }
            continue
        }
        selectionByKey[preference.key] = preference.selection
        result.append(preference)
    }
    return result
}

private func orderedUnique<Element: Hashable>(
    _ values: [Element],
    validating validate: (Element) throws -> Element
) throws -> [Element] {
    var seen: Set<Element> = []
    var result: [Element] = []
    for value in values {
        let validated = try validate(value)
        if seen.insert(validated).inserted {
            result.append(validated)
        }
    }
    return result
}
