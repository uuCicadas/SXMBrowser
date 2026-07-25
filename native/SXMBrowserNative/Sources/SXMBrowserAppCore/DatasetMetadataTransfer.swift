import Foundation
import SXMBrowserCore

public struct DatasetMetadataTransferV1: Equatable, Sendable {
    public static let formatIdentifier =
        "com.sxmbrowser.dataset-metadata"
    public static let currentFormatVersion = 1

    public let tags: [DatasetTagV1]
    public let manualAssociations: [DatasetManualAssociationV1]
    public let hiddenDATPaths: [DatasetRelativePath]
    public let spectrumAxisPreferences: [SpectrumAxisPreferenceV1]

    public init(exporting record: DatasetRecordV1) throws {
        try self.init(
            tags: record.tags,
            manualAssociations: record.manualAssociations,
            hiddenDATPaths: record.hiddenDATPaths,
            spectrumAxisPreferences: record.spectrumAxisPreferences
        )
    }

    public init(
        tags: [DatasetTagV1],
        manualAssociations: [DatasetManualAssociationV1],
        hiddenDATPaths: [DatasetRelativePath],
        spectrumAxisPreferences: [SpectrumAxisPreferenceV1]
    ) throws {
        try rejectDuplicateTags(tags)
        try rejectDuplicateAssociations(manualAssociations)
        try rejectDuplicateHiddenPaths(hiddenDATPaths)
        try rejectDuplicateAxisPreferences(spectrumAxisPreferences)

        let validated: DatasetRecordV1
        do {
            validated = try DatasetRecordV1(
                id: Self.validationDatasetID,
                folderBookmark: nil,
                lastKnownPath: "/",
                tags: tags,
                manualAssociations: manualAssociations,
                hiddenDATPaths: hiddenDATPaths,
                spectrumAxisPreferences: spectrumAxisPreferences,
                updatedAt: Date(timeIntervalSinceReferenceDate: 0)
            )
        } catch let error as DatasetMetadataValidationError {
            throw DatasetMetadataTransferError.invalidMetadata(
                path: "$",
                error: error
            )
        }

        do {
            self.tags = try validated.tags.map { tag in
                try DatasetTagV1(
                    id: tag.id,
                    name: tag.name,
                    sxmPaths: tag.sxmPaths.sorted()
                )
            }
        } catch let error as DatasetMetadataValidationError {
            throw DatasetMetadataTransferError.invalidMetadata(
                path: "$.tags",
                error: error
            )
        }
        self.manualAssociations = validated.manualAssociations.sorted(
            by: associationSortsBefore
        )
        self.hiddenDATPaths = validated.hiddenDATPaths.sorted()
        self.spectrumAxisPreferences =
            validated.spectrumAxisPreferences.sorted(
                by: axisPreferenceSortsBefore
            )
    }

    private static let validationDatasetID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}

public enum DatasetMetadataTransferError:
    Error,
    Equatable,
    Sendable
{
    case emptyPayload
    case payloadTooLarge(actual: Int, maximum: Int)
    case unsupportedFileURL(URL)
    case notRegularFile(URL)
    case fileReadFailed(fileURL: URL, message: String)

    case malformedJSON(path: String, message: String)
    case missingField(path: String, field: String)
    case typeMismatch(path: String, expected: String)
    case unknownField(path: String, field: String)

    case invalidFormatIdentifier(String)
    case unsupportedFormatVersion(Int)

    case invalidUUID(path: String, value: String)
    case nonCanonicalUUID(path: String, value: String)
    case invalidValue(path: String, value: String)
    case nonCanonicalValue(path: String, value: String)

    case duplicateEntry(path: String, identity: String)
    case conflictingEntry(path: String, identity: String)
    case invalidMetadata(
        path: String,
        error: DatasetMetadataValidationError
    )

    case encodingFailed(message: String)
}

extension DatasetMetadataTransferError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPayload:
            "The metadata transfer file is empty."
        case let .payloadTooLarge(actual, maximum):
            "The metadata transfer contains \(actual) bytes; "
                + "the limit is \(maximum) bytes."
        case let .unsupportedFileURL(url):
            "The metadata transfer URL is not a file URL: \(url)."
        case let .notRegularFile(url):
            "The metadata transfer is not a regular file: \(url.path)."
        case let .fileReadFailed(fileURL, message):
            "Could not read metadata transfer at \(fileURL.path): \(message)"
        case let .malformedJSON(path, message):
            "Malformed JSON at \(path): \(message)"
        case let .missingField(path, field):
            "Required field “\(field)” is missing at \(path)."
        case let .typeMismatch(path, expected):
            "Expected \(expected) at \(path)."
        case let .unknownField(path, field):
            "Unknown field “\(field)” at \(path)."
        case let .invalidFormatIdentifier(identifier):
            "Unsupported metadata transfer identifier “\(identifier)”."
        case let .unsupportedFormatVersion(version):
            "Unsupported metadata transfer version \(version)."
        case let .invalidUUID(path, value):
            "“\(value)” is not a UUID at \(path)."
        case let .nonCanonicalUUID(path, value):
            "UUID “\(value)” is not lowercase canonical form at \(path)."
        case let .invalidValue(path, value):
            "“\(value)” is not a valid value at \(path)."
        case let .nonCanonicalValue(path, value):
            "“\(value)” is not canonical at \(path)."
        case let .duplicateEntry(path, identity):
            "Duplicate entry “\(identity)” at \(path)."
        case let .conflictingEntry(path, identity):
            "Conflicting entry “\(identity)” at \(path)."
        case let .invalidMetadata(path, error):
            "Invalid metadata at \(path): "
                + (error.errorDescription ?? String(describing: error))
        case let .encodingFailed(message):
            "Could not encode metadata transfer: \(message)"
        }
    }
}

public struct DatasetMetadataTransferCodec: Sendable {
    public static let maximumByteCount = 16 * 1024 * 1024

    private static let readChunkByteCount = 64 * 1024

    public init() {}

    public func encode(
        _ transfer: DatasetMetadataTransferV1
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(TransferWireV1(transfer))
        } catch let error as DatasetMetadataTransferError {
            throw error
        } catch {
            throw DatasetMetadataTransferError.encodingFailed(
                message: stableErrorMessage(error)
            )
        }

        guard data.count <= Self.maximumByteCount else {
            throw DatasetMetadataTransferError.payloadTooLarge(
                actual: data.count,
                maximum: Self.maximumByteCount
            )
        }
        return data
    }

    public func decode(
        _ data: Data
    ) throws -> DatasetMetadataTransferV1 {
        guard !data.isEmpty else {
            throw DatasetMetadataTransferError.emptyPayload
        }
        guard data.count <= Self.maximumByteCount else {
            throw DatasetMetadataTransferError.payloadTooLarge(
                actual: data.count,
                maximum: Self.maximumByteCount
            )
        }

        let wire: TransferWireV1
        do {
            wire = try JSONDecoder().decode(
                TransferWireV1.self,
                from: data
            )
        } catch let error as DatasetMetadataTransferError {
            throw error
        } catch let error as DecodingError {
            throw transferError(from: error)
        } catch {
            throw DatasetMetadataTransferError.malformedJSON(
                path: "$",
                message: stableErrorMessage(error)
            )
        }

        return try transfer(from: wire)
    }

    public func decode(
        contentsOf fileURL: URL
    ) throws -> DatasetMetadataTransferV1 {
        guard fileURL.isFileURL else {
            throw DatasetMetadataTransferError.unsupportedFileURL(fileURL)
        }

        let standardizedURL = fileURL.standardizedFileURL
        let resourceValues: URLResourceValues
        do {
            resourceValues = try standardizedURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
        } catch {
            throw DatasetMetadataTransferError.fileReadFailed(
                fileURL: standardizedURL,
                message: stableErrorMessage(error)
            )
        }

        guard resourceValues.isRegularFile == true else {
            throw DatasetMetadataTransferError.notRegularFile(
                standardizedURL
            )
        }
        if let fileSize = resourceValues.fileSize,
           fileSize > Self.maximumByteCount {
            throw DatasetMetadataTransferError.payloadTooLarge(
                actual: fileSize,
                maximum: Self.maximumByteCount
            )
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: standardizedURL)
        } catch {
            throw DatasetMetadataTransferError.fileReadFailed(
                fileURL: standardizedURL,
                message: stableErrorMessage(error)
            )
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try readBoundedData(
                from: handle,
                suggestedCapacity: resourceValues.fileSize
            )
        } catch let error as DatasetMetadataTransferError {
            throw error
        } catch {
            throw DatasetMetadataTransferError.fileReadFailed(
                fileURL: standardizedURL,
                message: stableErrorMessage(error)
            )
        }
        return try decode(data)
    }

    private func readBoundedData(
        from handle: FileHandle,
        suggestedCapacity: Int?
    ) throws -> Data {
        let readLimit = Self.maximumByteCount + 1
        var data = Data()
        if let suggestedCapacity, suggestedCapacity > 0 {
            data.reserveCapacity(min(suggestedCapacity, readLimit))
        }

        while data.count < readLimit {
            let remaining = readLimit - data.count
            let requestedCount = min(
                Self.readChunkByteCount,
                remaining
            )
            guard let chunk = try handle.read(upToCount: requestedCount),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }

        guard data.count <= Self.maximumByteCount else {
            throw DatasetMetadataTransferError.payloadTooLarge(
                actual: data.count,
                maximum: Self.maximumByteCount
            )
        }
        return data
    }
}

private struct TransferWireV1: Codable {
    let formatIdentifier: String
    let formatVersion: Int
    let tags: [TagWireV1]
    let manualAssociations: [AssociationWireV1]
    let hiddenDATPaths: [String]
    let spectrumAxisPreferences: [AxisPreferenceWireV1]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatIdentifier
        case formatVersion
        case tags
        case manualAssociations
        case hiddenDATPaths
        case spectrumAxisPreferences
    }

    init(_ transfer: DatasetMetadataTransferV1) {
        formatIdentifier = DatasetMetadataTransferV1.formatIdentifier
        formatVersion = DatasetMetadataTransferV1.currentFormatVersion
        tags = transfer.tags.map(TagWireV1.init)
        manualAssociations = transfer.manualAssociations.map(
            AssociationWireV1.init
        )
        hiddenDATPaths = transfer.hiddenDATPaths.map(\.rawValue)
        spectrumAxisPreferences =
            transfer.spectrumAxisPreferences.map(
                AxisPreferenceWireV1.init
            )
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownFields(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)

        formatIdentifier = try container.decode(
            String.self,
            forKey: .formatIdentifier
        )
        guard formatIdentifier
                == DatasetMetadataTransferV1.formatIdentifier else {
            throw DatasetMetadataTransferError.invalidFormatIdentifier(
                formatIdentifier
            )
        }

        formatVersion = try container.decode(
            Int.self,
            forKey: .formatVersion
        )
        guard formatVersion
                == DatasetMetadataTransferV1.currentFormatVersion else {
            throw DatasetMetadataTransferError.unsupportedFormatVersion(
                formatVersion
            )
        }

        tags = try container.decode([TagWireV1].self, forKey: .tags)
        manualAssociations = try container.decode(
            [AssociationWireV1].self,
            forKey: .manualAssociations
        )
        hiddenDATPaths = try container.decode(
            [String].self,
            forKey: .hiddenDATPaths
        )
        spectrumAxisPreferences = try container.decode(
            [AxisPreferenceWireV1].self,
            forKey: .spectrumAxisPreferences
        )
    }
}

private struct TagWireV1: Codable {
    let id: String
    let name: String
    let sxmPaths: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case sxmPaths
    }

    init(_ tag: DatasetTagV1) {
        id = tag.id.uuidString.lowercased()
        name = tag.name
        sxmPaths = tag.sxmPaths.map(\.rawValue)
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownFields(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sxmPaths = try container.decode(
            [String].self,
            forKey: .sxmPaths
        )
    }
}

private struct AssociationWireV1: Codable {
    let datPath: String
    let sxmPath: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case datPath
        case sxmPath
    }

    init(_ association: DatasetManualAssociationV1) {
        datPath = association.datPath.rawValue
        sxmPath = association.sxmPath.rawValue
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownFields(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        datPath = try container.decode(String.self, forKey: .datPath)
        sxmPath = try container.decode(String.self, forKey: .sxmPath)
    }
}

private struct AxisPreferenceWireV1: Codable {
    let sxmPath: String
    let kind: String
    let schemaFingerprint: String
    let xColumn: String
    let yColumn: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sxmPath
        case kind
        case schemaFingerprint
        case xColumn
        case yColumn
    }

    init(_ preference: SpectrumAxisPreferenceV1) {
        sxmPath = preference.key.sxmPath.rawValue
        kind = preference.key.kind.rawValue
        schemaFingerprint = preference.key.schemaFingerprint
        xColumn = preference.selection.xColumn
        yColumn = preference.selection.yColumn
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownFields(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sxmPath = try container.decode(String.self, forKey: .sxmPath)
        kind = try container.decode(String.self, forKey: .kind)
        schemaFingerprint = try container.decode(
            String.self,
            forKey: .schemaFingerprint
        )
        xColumn = try container.decode(String.self, forKey: .xColumn)
        yColumn = try container.decode(String.self, forKey: .yColumn)
    }
}

private struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownFields(
    from decoder: Decoder,
    allowed: [String]
) throws {
    // Foundation keyed containers do not expose repeated raw JSON object
    // member names. Strict duplicate checks below therefore apply to all
    // semantic metadata entries, while unknown object fields are rejected
    // here at every level.
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowedSet = Set(allowed)
    let unknown = container.allKeys
        .map(\.stringValue)
        .filter { !allowedSet.contains($0) }
        .sorted()
        .first
    if let unknown {
        throw DatasetMetadataTransferError.unknownField(
            path: jsonPath(decoder.codingPath),
            field: unknown
        )
    }
}

private func transfer(
    from wire: TransferWireV1
) throws -> DatasetMetadataTransferV1 {
    var tags: [DatasetTagV1] = []
    var seenTagIDs: Set<UUID> = []
    var seenTagNames: Set<String> = []

    for (tagIndex, wireTag) in wire.tags.enumerated() {
        let path = "$.tags[\(tagIndex)]"
        guard let id = UUID(uuidString: wireTag.id) else {
            throw DatasetMetadataTransferError.invalidUUID(
                path: "\(path).id",
                value: wireTag.id
            )
        }
        let canonicalID = id.uuidString.lowercased()
        guard stringsHaveIdenticalUTF8(wireTag.id, canonicalID) else {
            throw DatasetMetadataTransferError.nonCanonicalUUID(
                path: "\(path).id",
                value: wireTag.id
            )
        }
        guard seenTagIDs.insert(id).inserted else {
            throw DatasetMetadataTransferError.duplicateEntry(
                path: path,
                identity: canonicalID
            )
        }

        let canonicalName = try mapValidationError(
            at: "\(path).name"
        ) {
            try canonicalTagName(wireTag.name)
        }
        try requireCanonical(
            wireTag.name,
            canonical: canonicalName,
            at: "\(path).name"
        )
        let nameKey = canonicalTagComparisonKey(canonicalName)
        guard seenTagNames.insert(nameKey).inserted else {
            throw DatasetMetadataTransferError.duplicateEntry(
                path: path,
                identity: canonicalName
            )
        }

        var sxmPaths: [DatasetRelativePath] = []
        var seenPaths: Set<DatasetRelativePath> = []
        for (memberIndex, rawPath) in wireTag.sxmPaths.enumerated() {
            let memberPath = "\(path).sxmPaths[\(memberIndex)]"
            let sxmPath = try canonicalSXMPath(
                rawPath,
                at: memberPath
            )
            guard seenPaths.insert(sxmPath).inserted else {
                throw DatasetMetadataTransferError.duplicateEntry(
                    path: memberPath,
                    identity: sxmPath.rawValue
                )
            }
            sxmPaths.append(sxmPath)
        }

        let tag = try mapValidationError(at: path) {
            try DatasetTagV1(
                id: id,
                name: canonicalName,
                sxmPaths: sxmPaths
            )
        }
        tags.append(tag)
    }

    var associations: [DatasetManualAssociationV1] = []
    var associationTargetByDAT: [
        DatasetRelativePath: DatasetRelativePath
    ] = [:]
    for (index, wireAssociation) in
        wire.manualAssociations.enumerated()
    {
        let path = "$.manualAssociations[\(index)]"
        let datPath = try canonicalDATPath(
            wireAssociation.datPath,
            at: "\(path).datPath"
        )
        let sxmPath = try canonicalSXMPath(
            wireAssociation.sxmPath,
            at: "\(path).sxmPath"
        )

        if let existing = associationTargetByDAT[datPath] {
            if existing == sxmPath {
                throw DatasetMetadataTransferError.duplicateEntry(
                    path: path,
                    identity: datPath.rawValue
                )
            }
            throw DatasetMetadataTransferError.conflictingEntry(
                path: path,
                identity: datPath.rawValue
            )
        }
        associationTargetByDAT[datPath] = sxmPath
        associations.append(
            try mapValidationError(at: path) {
                try DatasetManualAssociationV1(
                    datPath: datPath,
                    sxmPath: sxmPath
                )
            }
        )
    }

    var hiddenDATPaths: [DatasetRelativePath] = []
    var seenHiddenPaths: Set<DatasetRelativePath> = []
    for (index, rawPath) in wire.hiddenDATPaths.enumerated() {
        let path = "$.hiddenDATPaths[\(index)]"
        let datPath = try canonicalDATPath(rawPath, at: path)
        guard seenHiddenPaths.insert(datPath).inserted else {
            throw DatasetMetadataTransferError.duplicateEntry(
                path: path,
                identity: datPath.rawValue
            )
        }
        hiddenDATPaths.append(datPath)
    }

    var axisPreferences: [SpectrumAxisPreferenceV1] = []
    var selectionByAxisKey: [
        SpectrumAxisPreferenceKeyV1: AxisSelection
    ] = [:]
    for (index, wirePreference) in
        wire.spectrumAxisPreferences.enumerated()
    {
        let path = "$.spectrumAxisPreferences[\(index)]"
        let sxmPath = try canonicalSXMPath(
            wirePreference.sxmPath,
            at: "\(path).sxmPath"
        )
        guard let kind = SpectroscopyKind(
            rawValue: wirePreference.kind
        ) else {
            throw DatasetMetadataTransferError.invalidValue(
                path: "\(path).kind",
                value: wirePreference.kind
            )
        }

        let key = try mapValidationError(
            at: "\(path).schemaFingerprint"
        ) {
            try SpectrumAxisPreferenceKeyV1(
                sxmPath: sxmPath,
                kind: kind,
                schemaFingerprint: wirePreference.schemaFingerprint
            )
        }
        try requireCanonical(
            wirePreference.schemaFingerprint,
            canonical: key.schemaFingerprint,
            at: "\(path).schemaFingerprint"
        )

        let preference = try mapValidationError(at: path) {
            try SpectrumAxisPreferenceV1(
                key: key,
                selection: AxisSelection(
                    xColumn: wirePreference.xColumn,
                    yColumn: wirePreference.yColumn
                )
            )
        }
        try requireCanonical(
            wirePreference.xColumn,
            canonical: preference.selection.xColumn,
            at: "\(path).xColumn"
        )
        try requireCanonical(
            wirePreference.yColumn,
            canonical: preference.selection.yColumn,
            at: "\(path).yColumn"
        )

        if let existing = selectionByAxisKey[key] {
            if existing == preference.selection {
                throw DatasetMetadataTransferError.duplicateEntry(
                    path: path,
                    identity: key.stableIdentifier
                )
            }
            throw DatasetMetadataTransferError.conflictingEntry(
                path: path,
                identity: key.stableIdentifier
            )
        }
        selectionByAxisKey[key] = preference.selection
        axisPreferences.append(preference)
    }

    return try DatasetMetadataTransferV1(
        tags: tags,
        manualAssociations: associations,
        hiddenDATPaths: hiddenDATPaths,
        spectrumAxisPreferences: axisPreferences
    )
}

private func canonicalSXMPath(
    _ rawValue: String,
    at path: String
) throws -> DatasetRelativePath {
    let canonical = try mapValidationError(at: path) {
        try DatasetRelativePath.sxm(rawValue)
    }
    try requireCanonical(
        rawValue,
        canonical: canonical.rawValue,
        at: path
    )
    return canonical
}

private func canonicalDATPath(
    _ rawValue: String,
    at path: String
) throws -> DatasetRelativePath {
    let canonical = try mapValidationError(at: path) {
        try DatasetRelativePath.dat(rawValue)
    }
    try requireCanonical(
        rawValue,
        canonical: canonical.rawValue,
        at: path
    )
    return canonical
}

private func requireCanonical(
    _ rawValue: String,
    canonical: String,
    at path: String
) throws {
    guard stringsHaveIdenticalUTF8(rawValue, canonical) else {
        throw DatasetMetadataTransferError.nonCanonicalValue(
            path: path,
            value: rawValue
        )
    }
}

private func stringsHaveIdenticalUTF8(
    _ lhs: String,
    _ rhs: String
) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

private func mapValidationError<Result>(
    at path: String,
    _ operation: () throws -> Result
) throws -> Result {
    do {
        return try operation()
    } catch let error as DatasetMetadataValidationError {
        throw DatasetMetadataTransferError.invalidMetadata(
            path: path,
            error: error
        )
    }
}

private func rejectDuplicateTags(
    _ tags: [DatasetTagV1]
) throws {
    var seenIDs: Set<UUID> = []
    var seenNames: Set<String> = []
    for (index, tag) in tags.enumerated() {
        let path = "$.tags[\(index)]"
        guard seenIDs.insert(tag.id).inserted else {
            throw DatasetMetadataTransferError.duplicateEntry(
                path: path,
                identity: tag.id.uuidString.lowercased()
            )
        }
        let nameKey = canonicalTagComparisonKey(tag.name)
        guard seenNames.insert(nameKey).inserted else {
            throw DatasetMetadataTransferError.duplicateEntry(
                path: path,
                identity: tag.name
            )
        }
    }
}

private func rejectDuplicateAssociations(
    _ associations: [DatasetManualAssociationV1]
) throws {
    var targetByDAT: [
        DatasetRelativePath: DatasetRelativePath
    ] = [:]
    for (index, association) in associations.enumerated() {
        if let existing = targetByDAT[association.datPath] {
            let path = "$.manualAssociations[\(index)]"
            if existing == association.sxmPath {
                throw DatasetMetadataTransferError.duplicateEntry(
                    path: path,
                    identity: association.datPath.rawValue
                )
            }
            throw DatasetMetadataTransferError.conflictingEntry(
                path: path,
                identity: association.datPath.rawValue
            )
        }
        targetByDAT[association.datPath] = association.sxmPath
    }
}

private func rejectDuplicateHiddenPaths(
    _ paths: [DatasetRelativePath]
) throws {
    var seen: Set<DatasetRelativePath> = []
    for (index, path) in paths.enumerated() {
        guard seen.insert(path).inserted else {
            throw DatasetMetadataTransferError.duplicateEntry(
                path: "$.hiddenDATPaths[\(index)]",
                identity: path.rawValue
            )
        }
    }
}

private func rejectDuplicateAxisPreferences(
    _ preferences: [SpectrumAxisPreferenceV1]
) throws {
    var selectionByKey: [
        SpectrumAxisPreferenceKeyV1: AxisSelection
    ] = [:]
    for (index, preference) in preferences.enumerated() {
        if let existing = selectionByKey[preference.key] {
            let path = "$.spectrumAxisPreferences[\(index)]"
            if existing == preference.selection {
                throw DatasetMetadataTransferError.duplicateEntry(
                    path: path,
                    identity: preference.key.stableIdentifier
                )
            }
            throw DatasetMetadataTransferError.conflictingEntry(
                path: path,
                identity: preference.key.stableIdentifier
            )
        }
        selectionByKey[preference.key] = preference.selection
    }
}

private func associationSortsBefore(
    _ lhs: DatasetManualAssociationV1,
    _ rhs: DatasetManualAssociationV1
) -> Bool {
    if lhs.datPath != rhs.datPath {
        return lhs.datPath < rhs.datPath
    }
    return lhs.sxmPath < rhs.sxmPath
}

private func axisPreferenceSortsBefore(
    _ lhs: SpectrumAxisPreferenceV1,
    _ rhs: SpectrumAxisPreferenceV1
) -> Bool {
    if lhs.key.sxmPath != rhs.key.sxmPath {
        return lhs.key.sxmPath < rhs.key.sxmPath
    }
    if lhs.key.kind.rawValue != rhs.key.kind.rawValue {
        return lhs.key.kind.rawValue < rhs.key.kind.rawValue
    }
    if lhs.key.schemaFingerprint != rhs.key.schemaFingerprint {
        return lhs.key.schemaFingerprint < rhs.key.schemaFingerprint
    }
    if lhs.selection.xColumn != rhs.selection.xColumn {
        return lhs.selection.xColumn < rhs.selection.xColumn
    }
    return lhs.selection.yColumn < rhs.selection.yColumn
}

private func transferError(
    from error: DecodingError
) -> DatasetMetadataTransferError {
    switch error {
    case let .keyNotFound(key, context):
        return .missingField(
            path: jsonPath(context.codingPath),
            field: key.stringValue
        )
    case let .typeMismatch(type, context):
        return .typeMismatch(
            path: jsonPath(context.codingPath),
            expected: String(describing: type)
        )
    case let .valueNotFound(type, context):
        return .typeMismatch(
            path: jsonPath(context.codingPath),
            expected: String(describing: type)
        )
    case let .dataCorrupted(context):
        return .malformedJSON(
            path: jsonPath(context.codingPath),
            message: context.debugDescription
        )
    @unknown default:
        return .malformedJSON(
            path: "$",
            message: String(describing: error)
        )
    }
}

private func jsonPath(_ codingPath: [any CodingKey]) -> String {
    codingPath.reduce(into: "$") { result, key in
        if let index = key.intValue {
            result += "[\(index)]"
        } else {
            result += ".\(key.stringValue)"
        }
    }
}

private func stableErrorMessage(_ error: Error) -> String {
    if let localized = error as? any LocalizedError,
       let description = localized.errorDescription {
        return description
    }
    return String(describing: error)
}
