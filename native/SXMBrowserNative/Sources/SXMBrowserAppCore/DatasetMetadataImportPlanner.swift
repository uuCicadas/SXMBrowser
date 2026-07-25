import Foundation
import SXMBrowserCore

public struct DatasetMetadataImportDATFile:
    Equatable,
    Sendable
{
    public let path: DatasetRelativePath
    public let kind: SpectroscopyKind
    public let schemaFingerprint: String
    public let columns: [String]
    public let automaticParentSXMPath: DatasetRelativePath?

    public init(
        path: DatasetRelativePath,
        kind: SpectroscopyKind,
        schemaFingerprint: String,
        columns: [String],
        automaticParentSXMPath: DatasetRelativePath?
    ) {
        self.path = path
        self.kind = kind
        self.schemaFingerprint = schemaFingerprint
        self.columns = columns
        self.automaticParentSXMPath = automaticParentSXMPath
    }
}

public enum DatasetMetadataImportInventoryError:
    Error,
    Equatable,
    Sendable
{
    case invalidPath(
        kind: DatasetFileKind,
        path: DatasetRelativePath,
        error: DatasetMetadataValidationError
    )
    case duplicateSXMPath(DatasetRelativePath)
    case duplicateDATPath(DatasetRelativePath)
    case automaticParentMissing(
        datPath: DatasetRelativePath,
        parentSXMPath: DatasetRelativePath
    )
    case schemaFingerprintMismatch(
        datPath: DatasetRelativePath,
        expected: String,
        actual: String
    )
    case ambiguousNormalizedColumn(
        datPath: DatasetRelativePath,
        normalizedColumn: String,
        columns: [String]
    )
}

extension DatasetMetadataImportInventoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidPath(kind, path, error):
            "Invalid \(kind.rawValue.uppercased()) inventory path "
                + "“\(path.rawValue)”: \(error.localizedDescription)"
        case let .duplicateSXMPath(path):
            "SXM inventory path “\(path.rawValue)” occurs more than once."
        case let .duplicateDATPath(path):
            "DAT inventory path “\(path.rawValue)” occurs more than once."
        case let .automaticParentMissing(datPath, parentSXMPath):
            "DAT file “\(datPath.rawValue)” refers to missing automatic "
                + "parent “\(parentSXMPath.rawValue)”."
        case let .schemaFingerprintMismatch(
            datPath,
            expected,
            actual
        ):
            "DAT file “\(datPath.rawValue)” has schema fingerprint "
                + "“\(actual)”; expected “\(expected)”."
        case let .ambiguousNormalizedColumn(
            datPath,
            normalizedColumn,
            columns
        ):
            "DAT file “\(datPath.rawValue)” has ambiguous normalized "
                + "column “\(normalizedColumn)”: "
                + columns.joined(separator: ", ")
        }
    }
}

public struct DatasetMetadataImportInventory:
    Equatable,
    Sendable
{
    public let revisionID: UUID
    public let sessionID: UUID
    public let datasetID: UUID
    public let sxmPaths: [DatasetRelativePath]
    public let datFiles: [DatasetMetadataImportDATFile]

    public init(
        revisionID: UUID,
        sessionID: UUID,
        datasetID: UUID,
        sxmPaths: [DatasetRelativePath],
        datFiles: [DatasetMetadataImportDATFile]
    ) throws {
        var seenSXMPaths: Set<DatasetRelativePath> = []
        for path in sxmPaths {
            do {
                _ = try path.validated(for: .sxm)
            } catch let error as DatasetMetadataValidationError {
                throw DatasetMetadataImportInventoryError.invalidPath(
                    kind: .sxm,
                    path: path,
                    error: error
                )
            }
            guard seenSXMPaths.insert(path).inserted else {
                throw DatasetMetadataImportInventoryError
                    .duplicateSXMPath(path)
            }
        }

        var seenDATPaths: Set<DatasetRelativePath> = []
        for file in datFiles {
            do {
                _ = try file.path.validated(for: .dat)
            } catch let error as DatasetMetadataValidationError {
                throw DatasetMetadataImportInventoryError.invalidPath(
                    kind: .dat,
                    path: file.path,
                    error: error
                )
            }
            guard seenDATPaths.insert(file.path).inserted else {
                throw DatasetMetadataImportInventoryError
                    .duplicateDATPath(file.path)
            }

            if let parent = file.automaticParentSXMPath {
                do {
                    _ = try parent.validated(for: .sxm)
                } catch let error as DatasetMetadataValidationError {
                    throw DatasetMetadataImportInventoryError.invalidPath(
                        kind: .sxm,
                        path: parent,
                        error: error
                    )
                }
                guard seenSXMPaths.contains(parent) else {
                    throw DatasetMetadataImportInventoryError
                        .automaticParentMissing(
                            datPath: file.path,
                            parentSXMPath: parent
                        )
                }
            }

            let expectedFingerprint = SpectroscopyColumnSchema(
                columns: file.columns
            ).fingerprint
            guard file.schemaFingerprint == expectedFingerprint else {
                throw DatasetMetadataImportInventoryError
                    .schemaFingerprintMismatch(
                        datPath: file.path,
                        expected: expectedFingerprint,
                        actual: file.schemaFingerprint
                    )
            }

            var columnsByNormalizedName: [String: [String]] = [:]
            for column in file.columns {
                let normalized = SpectroscopyColumnSchema.normalize(
                    column
                )
                columnsByNormalizedName[normalized, default: []]
                    .append(column)
            }
            if let ambiguous = columnsByNormalizedName
                .filter({ $0.value.count > 1 })
                .sorted(by: { $0.key < $1.key })
                .first {
                throw DatasetMetadataImportInventoryError
                    .ambiguousNormalizedColumn(
                        datPath: file.path,
                        normalizedColumn: ambiguous.key,
                        columns: ambiguous.value.sorted()
                    )
            }
        }

        self.revisionID = revisionID
        self.sessionID = sessionID
        self.datasetID = datasetID
        self.sxmPaths = sxmPaths.sorted()
        self.datFiles = datFiles.sorted {
            $0.path < $1.path
        }
    }
}

public enum DatasetMetadataImportConflictPolicy:
    String,
    Equatable,
    Sendable
{
    case keepDestination
    case useImported
    case requireDecision
}

public struct DatasetMetadataImportPolicy:
    Equatable,
    Sendable
{
    public let tagIdentity: DatasetMetadataImportConflictPolicy
    public let association: DatasetMetadataImportConflictPolicy
    public let axis: DatasetMetadataImportConflictPolicy

    public init(
        tagIdentity: DatasetMetadataImportConflictPolicy =
            .requireDecision,
        association: DatasetMetadataImportConflictPolicy =
            .requireDecision,
        axis: DatasetMetadataImportConflictPolicy =
            .requireDecision
    ) {
        self.tagIdentity = tagIdentity
        self.association = association
        self.axis = axis
    }

    public static let safeDefault = DatasetMetadataImportPolicy(
        tagIdentity: .keepDestination,
        association: .keepDestination,
        axis: .keepDestination
    )
    public static let requireDecisions = DatasetMetadataImportPolicy()
}

public enum DatasetMetadataImportConflictResolution:
    Equatable,
    Sendable
{
    case keptDestination
    case usedImported
    case unresolved
}

public enum DatasetMetadataTagIdentityConflictKind:
    Equatable,
    Sendable
{
    case sameNameDifferentUUID
    case sameUUIDDifferentName
    case uuidAndNameMatchDifferentDestinationTags
}

public enum DatasetMetadataImportIssue:
    Equatable,
    Sendable
{
    case missingTagMember(
        tagID: UUID,
        sxmPath: DatasetRelativePath
    )
    case tagIdentityConflict(
        kind: DatasetMetadataTagIdentityConflictKind,
        importedTagID: UUID,
        importedName: String,
        uuidMatchedTagID: UUID?,
        nameMatchedTagID: UUID?,
        resolution: DatasetMetadataImportConflictResolution
    )

    case associationDATMissing(DatasetRelativePath)
    case associationSXMMissing(
        datPath: DatasetRelativePath,
        sxmPath: DatasetRelativePath
    )
    case associationConflict(
        datPath: DatasetRelativePath,
        destinationSXMPath: DatasetRelativePath,
        importedSXMPath: DatasetRelativePath,
        resolution: DatasetMetadataImportConflictResolution
    )

    case hiddenDATMissing(DatasetRelativePath)

    case axisGroupUnavailable(
        key: SpectrumAxisPreferenceKeyV1,
        availableFingerprints: [String]
    )
    case axisColumnMissing(
        key: SpectrumAxisPreferenceKeyV1,
        axis: SpectrumAxis,
        column: String
    )
    case axisColumnAmbiguous(
        key: SpectrumAxisPreferenceKeyV1,
        axis: SpectrumAxis,
        column: String,
        matches: [String]
    )
    case axisConflict(
        key: SpectrumAxisPreferenceKeyV1,
        destination: AxisSelection,
        imported: AxisSelection,
        resolution: DatasetMetadataImportConflictResolution
    )

    public var isUnresolvedConflict: Bool {
        switch self {
        case let .tagIdentityConflict(
            _,
            _,
            _,
            _,
            _,
            resolution
        ),
        let .associationConflict(_, _, _, resolution),
        let .axisConflict(_, _, _, resolution):
            resolution == .unresolved
        default:
            false
        }
    }

    public var isResolvedConflict: Bool {
        switch self {
        case let .tagIdentityConflict(
            _,
            _,
            _,
            _,
            _,
            resolution
        ),
        let .associationConflict(_, _, _, resolution),
        let .axisConflict(_, _, _, resolution):
            resolution != .unresolved
        default:
            false
        }
    }

    public var isSkippedItem: Bool {
        switch self {
        case .missingTagMember,
             .associationDATMissing,
             .associationSXMMissing,
             .hiddenDATMissing,
             .axisGroupUnavailable,
             .axisColumnMissing,
             .axisColumnAmbiguous:
            true
        case .tagIdentityConflict,
             .associationConflict,
             .axisConflict:
            false
        }
    }
}

public enum DatasetMetadataImportAction:
    Equatable,
    Sendable
{
    case addTag(DatasetTagV1)
    case mergeTag(
        importedTagID: UUID,
        destinationTagID: UUID,
        addedSXMPaths: [DatasetRelativePath]
    )
    case renameTag(
        tagID: UUID,
        from: String,
        to: String
    )

    case addManualAssociation(DatasetManualAssociationV1)
    case replaceManualAssociation(
        datPath: DatasetRelativePath,
        from: DatasetRelativePath,
        to: DatasetRelativePath
    )

    case hideDAT(DatasetRelativePath)

    case addAxisPreference(SpectrumAxisPreferenceV1)
    case replaceAxisPreference(
        key: SpectrumAxisPreferenceKeyV1,
        from: AxisSelection,
        to: AxisSelection
    )
}

public struct DatasetMetadataImportPreview:
    Equatable,
    Sendable
{
    public let tags: [DatasetTagV1]
    public let manualAssociations: [DatasetManualAssociationV1]
    public let hiddenDATPaths: [DatasetRelativePath]
    public let spectrumAxisPreferences: [SpectrumAxisPreferenceV1]

    public init(
        tags: [DatasetTagV1],
        manualAssociations: [DatasetManualAssociationV1],
        hiddenDATPaths: [DatasetRelativePath],
        spectrumAxisPreferences: [SpectrumAxisPreferenceV1]
    ) {
        self.tags = tags
        self.manualAssociations = manualAssociations
        self.hiddenDATPaths = hiddenDATPaths
        self.spectrumAxisPreferences = spectrumAxisPreferences
    }
}

public struct DatasetMetadataImportSummary:
    Equatable,
    Sendable
{
    public let actionCount: Int
    public let tagActionCount: Int
    public let associationActionCount: Int
    public let hiddenActionCount: Int
    public let axisActionCount: Int
    public let skippedItemCount: Int
    public let resolvedConflictCount: Int
    public let unresolvedConflictCount: Int

    fileprivate init(
        actions: [DatasetMetadataImportAction],
        issues: [DatasetMetadataImportIssue]
    ) {
        actionCount = actions.count
        tagActionCount = actions.filter(\.isTagAction).count
        associationActionCount = actions.filter(
            \.isAssociationAction
        ).count
        hiddenActionCount = actions.filter(\.isHiddenAction).count
        axisActionCount = actions.filter(\.isAxisAction).count
        skippedItemCount = issues.filter(\.isSkippedItem).count
        resolvedConflictCount = issues.filter(
            \.isResolvedConflict
        ).count
        unresolvedConflictCount = issues.filter(
            \.isUnresolvedConflict
        ).count
    }
}

public enum DatasetMetadataImportPlanningError:
    Error,
    Equatable,
    Sendable
{
    case inventoryDatasetMismatch(
        recordDatasetID: UUID,
        inventoryDatasetID: UUID
    )
    case invalidResult(DatasetMetadataValidationError)
}

extension DatasetMetadataImportPlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .inventoryDatasetMismatch(recordID, inventoryID):
            "Cannot plan metadata import for dataset "
                + "\(recordID.uuidString): the inventory belongs to "
                + "\(inventoryID.uuidString)."
        case let .invalidResult(error):
            "The metadata import preview is invalid: "
                + (error.errorDescription ?? String(describing: error))
        }
    }
}

public enum DatasetMetadataImportApplyError:
    Error,
    Equatable,
    Sendable
{
    case datasetStale(
        expected: UUID,
        recordDatasetID: UUID,
        inventoryDatasetID: UUID
    )
    case recordStale
    case inventoryStale(
        expectedRevisionID: UUID,
        actualRevisionID: UUID,
        expectedSessionID: UUID,
        actualSessionID: UUID
    )
    case unresolvedConflicts(Int)
    case invalidResult(DatasetMetadataValidationError)
}

extension DatasetMetadataImportApplyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .datasetStale(expected, recordID, inventoryID):
            "The import expected dataset \(expected.uuidString), but the "
                + "current record is \(recordID.uuidString) and the "
                + "inventory is \(inventoryID.uuidString)."
        case .recordStale:
            "Dataset metadata changed after the import preview was made."
        case let .inventoryStale(
            expectedRevision,
            actualRevision,
            expectedSession,
            actualSession
        ):
            "Dataset files changed after the import preview was made "
                + "(revision \(expectedRevision.uuidString) → "
                + "\(actualRevision.uuidString), session "
                + "\(expectedSession.uuidString) → "
                + "\(actualSession.uuidString))."
        case let .unresolvedConflicts(count):
            "The metadata import has \(count) unresolved "
                + "conflict\(count == 1 ? "" : "s")."
        case let .invalidResult(error):
            "The applied metadata is invalid: "
                + (error.errorDescription ?? String(describing: error))
        }
    }
}

public struct DatasetMetadataImportPlan:
    Equatable,
    Sendable
{
    public let preview: DatasetMetadataImportPreview
    public let summary: DatasetMetadataImportSummary
    public let issues: [DatasetMetadataImportIssue]
    public let actions: [DatasetMetadataImportAction]
    public let hasChanges: Bool
    public let canApply: Bool

    private let baselineRecord: DatasetRecordV1
    private let baselineInventory: DatasetMetadataImportInventory

    fileprivate init(
        baselineRecord: DatasetRecordV1,
        baselineInventory: DatasetMetadataImportInventory,
        preview: DatasetMetadataImportPreview,
        issues: [DatasetMetadataImportIssue],
        actions: [DatasetMetadataImportAction]
    ) {
        self.baselineRecord = baselineRecord
        self.baselineInventory = baselineInventory
        self.preview = preview
        self.issues = issues
        self.actions = actions
        summary = DatasetMetadataImportSummary(
            actions: actions,
            issues: issues
        )
        hasChanges =
            preview.tags != baselineRecord.tags
            || preview.manualAssociations
                != baselineRecord.manualAssociations
            || preview.hiddenDATPaths
                != baselineRecord.hiddenDATPaths
            || preview.spectrumAxisPreferences
                != baselineRecord.spectrumAxisPreferences
        canApply = !issues.contains(where: \.isUnresolvedConflict)
    }

    public func applying(
        to currentRecord: DatasetRecordV1,
        inventory currentInventory: DatasetMetadataImportInventory,
        updatedAt: Date
    ) throws -> DatasetRecordV1 {
        guard currentRecord.id == baselineRecord.id,
              currentInventory.datasetID == baselineRecord.id else {
            throw DatasetMetadataImportApplyError.datasetStale(
                expected: baselineRecord.id,
                recordDatasetID: currentRecord.id,
                inventoryDatasetID: currentInventory.datasetID
            )
        }
        guard currentRecord == baselineRecord else {
            throw DatasetMetadataImportApplyError.recordStale
        }
        guard currentInventory == baselineInventory else {
            throw DatasetMetadataImportApplyError.inventoryStale(
                expectedRevisionID: baselineInventory.revisionID,
                actualRevisionID: currentInventory.revisionID,
                expectedSessionID: baselineInventory.sessionID,
                actualSessionID: currentInventory.sessionID
            )
        }
        let unresolvedCount = summary.unresolvedConflictCount
        guard unresolvedCount == 0 else {
            throw DatasetMetadataImportApplyError.unresolvedConflicts(
                unresolvedCount
            )
        }
        guard hasChanges else {
            return currentRecord
        }

        do {
            return try DatasetRecordV1(
                id: currentRecord.id,
                folderBookmark: currentRecord.folderBookmark,
                lastKnownPath: currentRecord.lastKnownPath,
                tags: preview.tags,
                manualAssociations: preview.manualAssociations,
                hiddenDATPaths: preview.hiddenDATPaths,
                spectrumAxisPreferences:
                    preview.spectrumAxisPreferences,
                updatedAt: updatedAt
            )
        } catch let error as DatasetMetadataValidationError {
            throw DatasetMetadataImportApplyError.invalidResult(error)
        }
    }
}

public struct DatasetMetadataImportPlanner: Sendable {
    public init() {}

    public func plan(
        transfer: DatasetMetadataTransferV1,
        into destination: DatasetRecordV1,
        inventory: DatasetMetadataImportInventory,
        policy: DatasetMetadataImportPolicy = .safeDefault
    ) throws -> DatasetMetadataImportPlan {
        guard destination.id == inventory.datasetID else {
            throw DatasetMetadataImportPlanningError
                .inventoryDatasetMismatch(
                    recordDatasetID: destination.id,
                    inventoryDatasetID: inventory.datasetID
                )
        }

        var issues: [DatasetMetadataImportIssue] = []
        var actions: [DatasetMetadataImportAction] = []
        let availableSXMPaths = Set(inventory.sxmPaths)
        let availableDATPaths = Set(inventory.datFiles.map(\.path))

        let tags = try mergedTags(
            destination: destination.tags,
            imported: transfer.tags,
            availableSXMPaths: availableSXMPaths,
            policy: policy.tagIdentity,
            issues: &issues,
            actions: &actions
        )
        let associations = try mergedAssociations(
            destination: destination.manualAssociations,
            imported: transfer.manualAssociations,
            availableSXMPaths: availableSXMPaths,
            availableDATPaths: availableDATPaths,
            policy: policy.association,
            issues: &issues,
            actions: &actions
        )
        let hiddenDATPaths = mergedHiddenPaths(
            destination: destination.hiddenDATPaths,
            imported: transfer.hiddenDATPaths,
            availableDATPaths: availableDATPaths,
            issues: &issues,
            actions: &actions
        )
        let axisPreferences = try mergedAxisPreferences(
            destination: destination.spectrumAxisPreferences,
            imported: transfer.spectrumAxisPreferences,
            associations: associations,
            inventory: inventory,
            policy: policy.axis,
            issues: &issues,
            actions: &actions
        )

        return DatasetMetadataImportPlan(
            baselineRecord: destination,
            baselineInventory: inventory,
            preview: DatasetMetadataImportPreview(
                tags: tags,
                manualAssociations: associations,
                hiddenDATPaths: hiddenDATPaths,
                spectrumAxisPreferences: axisPreferences
            ),
            issues: issues,
            actions: actions
        )
    }
}

private func mergedTags(
    destination: [DatasetTagV1],
    imported: [DatasetTagV1],
    availableSXMPaths: Set<DatasetRelativePath>,
    policy: DatasetMetadataImportConflictPolicy,
    issues: inout [DatasetMetadataImportIssue],
    actions: inout [DatasetMetadataImportAction]
) throws -> [DatasetTagV1] {
    var result = destination

    for importedTag in imported {
        var availableMembers: [DatasetRelativePath] = []
        for path in importedTag.sxmPaths {
            if availableSXMPaths.contains(path) {
                availableMembers.append(path)
            } else {
                issues.append(
                    .missingTagMember(
                        tagID: importedTag.id,
                        sxmPath: path
                    )
                )
            }
        }

        let idIndex = result.firstIndex {
            $0.id == importedTag.id
        }
        let importedNameKey = canonicalTagComparisonKey(
            importedTag.name
        )
        let nameIndex = result.firstIndex {
            canonicalTagComparisonKey($0.name) == importedNameKey
        }

        if idIndex == nil, nameIndex == nil {
            do {
                let added = try DatasetTagV1(
                    id: importedTag.id,
                    name: importedTag.name,
                    sxmPaths: availableMembers
                )
                result.append(added)
                actions.append(.addTag(added))
            } catch let error as DatasetMetadataValidationError {
                throw DatasetMetadataImportPlanningError.invalidResult(
                    error
                )
            }
            continue
        }

        let targetIndex: Int
        var resultingName: String

        switch (idIndex, nameIndex) {
        case let (.some(idIndex), .some(nameIndex))
            where idIndex == nameIndex:
            targetIndex = idIndex
            resultingName = result[idIndex].name

        case let (.none, .some(nameIndex)):
            targetIndex = nameIndex
            resultingName = result[nameIndex].name
            issues.append(
                .tagIdentityConflict(
                    kind: .sameNameDifferentUUID,
                    importedTagID: importedTag.id,
                    importedName: importedTag.name,
                    uuidMatchedTagID: nil,
                    nameMatchedTagID: result[nameIndex].id,
                    resolution: .keptDestination
                )
            )

        case let (.some(idIndex), .none):
            targetIndex = idIndex
            let resolution = conflictResolution(for: policy)
            issues.append(
                .tagIdentityConflict(
                    kind: .sameUUIDDifferentName,
                    importedTagID: importedTag.id,
                    importedName: importedTag.name,
                    uuidMatchedTagID: result[idIndex].id,
                    nameMatchedTagID: nil,
                    resolution: resolution
                )
            )
            resultingName = policy == .useImported
                ? importedTag.name
                : result[idIndex].name

        case let (.some(idIndex), .some(nameIndex)):
            let resolution = conflictResolution(for: policy)
            issues.append(
                .tagIdentityConflict(
                    kind: .uuidAndNameMatchDifferentDestinationTags,
                    importedTagID: importedTag.id,
                    importedName: importedTag.name,
                    uuidMatchedTagID: result[idIndex].id,
                    nameMatchedTagID: result[nameIndex].id,
                    resolution: resolution
                )
            )
            if policy == .useImported {
                targetIndex = nameIndex
            } else {
                targetIndex = idIndex
            }
            resultingName = result[targetIndex].name

        case (.none, .none):
            continue
        }

        let target = result[targetIndex]
        if target.name != resultingName {
            actions.append(
                .renameTag(
                    tagID: target.id,
                    from: target.name,
                    to: resultingName
                )
            )
        }

        let existingMembers = Set(target.sxmPaths)
        let addedMembers = availableMembers.filter {
            !existingMembers.contains($0)
        }
        if !addedMembers.isEmpty {
            actions.append(
                .mergeTag(
                    importedTagID: importedTag.id,
                    destinationTagID: target.id,
                    addedSXMPaths: addedMembers
                )
            )
        }

        do {
            result[targetIndex] = try DatasetTagV1(
                id: target.id,
                name: resultingName,
                sxmPaths: target.sxmPaths + addedMembers
            )
        } catch let error as DatasetMetadataValidationError {
            throw DatasetMetadataImportPlanningError.invalidResult(error)
        }
    }

    return result
}

private func mergedAssociations(
    destination: [DatasetManualAssociationV1],
    imported: [DatasetManualAssociationV1],
    availableSXMPaths: Set<DatasetRelativePath>,
    availableDATPaths: Set<DatasetRelativePath>,
    policy: DatasetMetadataImportConflictPolicy,
    issues: inout [DatasetMetadataImportIssue],
    actions: inout [DatasetMetadataImportAction]
) throws -> [DatasetManualAssociationV1] {
    var result = destination

    for association in imported {
        var isAvailable = true
        if !availableDATPaths.contains(association.datPath) {
            issues.append(.associationDATMissing(association.datPath))
            isAvailable = false
        }
        if !availableSXMPaths.contains(association.sxmPath) {
            issues.append(
                .associationSXMMissing(
                    datPath: association.datPath,
                    sxmPath: association.sxmPath
                )
            )
            isAvailable = false
        }
        guard isAvailable else { continue }

        guard let existingIndex = result.firstIndex(where: {
            $0.datPath == association.datPath
        }) else {
            result.append(association)
            actions.append(.addManualAssociation(association))
            continue
        }

        let existing = result[existingIndex]
        guard existing.sxmPath != association.sxmPath else {
            continue
        }

        let resolution = conflictResolution(for: policy)
        issues.append(
            .associationConflict(
                datPath: association.datPath,
                destinationSXMPath: existing.sxmPath,
                importedSXMPath: association.sxmPath,
                resolution: resolution
            )
        )
        if policy == .useImported {
            result[existingIndex] = association
            actions.append(
                .replaceManualAssociation(
                    datPath: association.datPath,
                    from: existing.sxmPath,
                    to: association.sxmPath
                )
            )
        }
    }

    return result
}

private func mergedHiddenPaths(
    destination: [DatasetRelativePath],
    imported: [DatasetRelativePath],
    availableDATPaths: Set<DatasetRelativePath>,
    issues: inout [DatasetMetadataImportIssue],
    actions: inout [DatasetMetadataImportAction]
) -> [DatasetRelativePath] {
    var result = destination
    var seen = Set(destination)

    for path in imported {
        guard availableDATPaths.contains(path) else {
            issues.append(.hiddenDATMissing(path))
            continue
        }
        if seen.insert(path).inserted {
            result.append(path)
            actions.append(.hideDAT(path))
        }
    }
    return result
}

private struct SimulatedAxisGroup {
    let key: SpectrumAxisPreferenceKeyV1
    let columnCandidates: [String]
}

private func mergedAxisPreferences(
    destination: [SpectrumAxisPreferenceV1],
    imported: [SpectrumAxisPreferenceV1],
    associations: [DatasetManualAssociationV1],
    inventory: DatasetMetadataImportInventory,
    policy: DatasetMetadataImportConflictPolicy,
    issues: inout [DatasetMetadataImportIssue],
    actions: inout [DatasetMetadataImportAction]
) throws -> [SpectrumAxisPreferenceV1] {
    var result = destination
    let groups = try simulatedAxisGroups(
        inventory: inventory,
        associations: associations
    )

    for importedPreference in imported {
        let key = importedPreference.key
        guard let group = groups[key] else {
            let availableFingerprints = groups.keys
                .filter {
                    $0.sxmPath == key.sxmPath
                        && $0.kind.rawValue == key.kind.rawValue
                }
                .map(\.schemaFingerprint)
                .sorted()
            issues.append(
                .axisGroupUnavailable(
                    key: key,
                    availableFingerprints: availableFingerprints
                )
            )
            continue
        }

        var selectionIssues: [DatasetMetadataImportIssue] = []
        let xColumn = resolvedImportColumn(
            importedPreference.selection.xColumn,
            axis: .x,
            group: group,
            issues: &selectionIssues
        )
        let yColumn = resolvedImportColumn(
            importedPreference.selection.yColumn,
            axis: .y,
            group: group,
            issues: &selectionIssues
        )
        if !selectionIssues.isEmpty {
            issues.append(contentsOf: selectionIssues)
            continue
        }
        guard let xColumn, let yColumn else {
            continue
        }

        let resolvedPreference: SpectrumAxisPreferenceV1
        do {
            resolvedPreference = try SpectrumAxisPreferenceV1(
                key: key,
                selection: AxisSelection(
                    xColumn: xColumn,
                    yColumn: yColumn
                )
            )
        } catch let error as DatasetMetadataValidationError {
            throw DatasetMetadataImportPlanningError.invalidResult(error)
        }

        guard let existingIndex = result.firstIndex(where: {
            $0.key == key
        }) else {
            result.append(resolvedPreference)
            actions.append(.addAxisPreference(resolvedPreference))
            continue
        }

        let existing = result[existingIndex]
        guard existing.selection != resolvedPreference.selection else {
            continue
        }

        let resolution = conflictResolution(for: policy)
        issues.append(
            .axisConflict(
                key: key,
                destination: existing.selection,
                imported: resolvedPreference.selection,
                resolution: resolution
            )
        )
        if policy == .useImported {
            result[existingIndex] = resolvedPreference
            actions.append(
                .replaceAxisPreference(
                    key: key,
                    from: existing.selection,
                    to: resolvedPreference.selection
                )
            )
        }
    }

    return result
}

private func simulatedAxisGroups(
    inventory: DatasetMetadataImportInventory,
    associations: [DatasetManualAssociationV1]
) throws -> [SpectrumAxisPreferenceKeyV1: SimulatedAxisGroup] {
    let availableSXMPaths = Set(inventory.sxmPaths)
    let manualTargetByDAT = Dictionary(
        uniqueKeysWithValues: associations.map {
            ($0.datPath, $0.sxmPath)
        }
    )
    var groups: [
        SpectrumAxisPreferenceKeyV1: SimulatedAxisGroup
    ] = [:]

    for file in inventory.datFiles {
        let parent: DatasetRelativePath?
        if let manualTarget = manualTargetByDAT[file.path] {
            // A manual target that is currently unavailable deliberately
            // blocks automatic fallback.
            parent = availableSXMPaths.contains(manualTarget)
                ? manualTarget
                : nil
        } else {
            parent = file.automaticParentSXMPath
        }
        guard let parent else { continue }

        let key: SpectrumAxisPreferenceKeyV1
        do {
            key = try SpectrumAxisPreferenceKeyV1(
                sxmPath: parent,
                kind: file.kind,
                schemaFingerprint: file.schemaFingerprint
            )
        } catch let error as DatasetMetadataValidationError {
            throw DatasetMetadataImportPlanningError.invalidResult(error)
        }

        if groups[key] == nil {
            groups[key] = SimulatedAxisGroup(
                key: key,
                columnCandidates: file.columns
            )
        }
    }
    return groups
}

private enum ImportColumnResolution {
    case unique(String)
    case missing
    case ambiguous([String])
}

private func resolveImportColumn(
    _ requested: String,
    candidates: [String]
) -> ImportColumnResolution {
    let exactMatches = candidates.filter { $0 == requested }
    if exactMatches.count == 1 {
        return .unique(exactMatches[0])
    }
    if exactMatches.count > 1 {
        return .ambiguous(exactMatches.sorted())
    }

    let normalized = SpectroscopyColumnSchema.normalize(requested)
    let normalizedMatches = candidates.filter {
        SpectroscopyColumnSchema.normalize($0) == normalized
    }
    switch normalizedMatches.count {
    case 0:
        return .missing
    case 1:
        return .unique(normalizedMatches[0])
    default:
        return .ambiguous(normalizedMatches.sorted())
    }
}

private func resolvedImportColumn(
    _ requested: String,
    axis: SpectrumAxis,
    group: SimulatedAxisGroup,
    issues: inout [DatasetMetadataImportIssue]
) -> String? {
    switch resolveImportColumn(
        requested,
        candidates: group.columnCandidates
    ) {
    case let .unique(column):
        return column
    case .missing:
        issues.append(
            .axisColumnMissing(
                key: group.key,
                axis: axis,
                column: requested
            )
        )
    case let .ambiguous(matches):
        issues.append(
            .axisColumnAmbiguous(
                key: group.key,
                axis: axis,
                column: requested,
                matches: matches
            )
        )
    }
    return nil
}

private func conflictResolution(
    for policy: DatasetMetadataImportConflictPolicy
) -> DatasetMetadataImportConflictResolution {
    switch policy {
    case .keepDestination:
        .keptDestination
    case .useImported:
        .usedImported
    case .requireDecision:
        .unresolved
    }
}

private extension DatasetMetadataImportAction {
    var isTagAction: Bool {
        switch self {
        case .addTag, .mergeTag, .renameTag:
            true
        default:
            false
        }
    }

    var isAssociationAction: Bool {
        switch self {
        case .addManualAssociation, .replaceManualAssociation:
            true
        default:
            false
        }
    }

    var isHiddenAction: Bool {
        if case .hideDAT = self {
            return true
        }
        return false
    }

    var isAxisAction: Bool {
        switch self {
        case .addAxisPreference, .replaceAxisPreference:
            true
        default:
            false
        }
    }
}
