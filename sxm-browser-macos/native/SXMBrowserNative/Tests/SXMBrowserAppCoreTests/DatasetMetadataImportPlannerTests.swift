import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private let importDatasetID = UUID(
    uuidString: "10000000-0000-0000-0000-000000000001"
)!
private let importSessionID = UUID(
    uuidString: "20000000-0000-0000-0000-000000000002"
)!
private let importRevisionID = UUID(
    uuidString: "30000000-0000-0000-0000-000000000003"
)!
private let destinationTagAID = UUID(
    uuidString: "a0000000-0000-0000-0000-00000000000a"
)!
private let destinationTagBID = UUID(
    uuidString: "b0000000-0000-0000-0000-00000000000b"
)!
private let importedTagID = UUID(
    uuidString: "c0000000-0000-0000-0000-00000000000c"
)!

private func sxm(_ value: String) throws -> DatasetRelativePath {
    try DatasetRelativePath.sxm(value)
}

private func dat(_ value: String) throws -> DatasetRelativePath {
    try DatasetRelativePath.dat(value)
}

private func importDAT(
    _ path: String,
    kind: SpectroscopyKind = .bias,
    experiment: String? = nil,
    columns: [String] = ["Bias", "Current", "Phase"],
    fingerprint: String? = nil,
    automaticParent: String? = "a.sxm"
) throws -> DatasetMetadataImportDATFile {
    DatasetMetadataImportDATFile(
        path: try dat(path),
        kind: kind,
        experiment: experiment,
        schemaFingerprint:
            fingerprint
            ?? SpectroscopyColumnSchema(columns: columns).fingerprint,
        columns: columns,
        automaticParentSXMPath: try automaticParent.map(sxm)
    )
}

private func importInventory(
    revisionID: UUID = importRevisionID,
    sessionID: UUID = importSessionID,
    datasetID: UUID = importDatasetID,
    sxmPaths: [String] = ["a.sxm", "b.sxm"],
    datFiles: [DatasetMetadataImportDATFile]? = nil
) throws -> DatasetMetadataImportInventory {
    try DatasetMetadataImportInventory(
        revisionID: revisionID,
        sessionID: sessionID,
        datasetID: datasetID,
        sxmPaths: try sxmPaths.map(sxm),
        datFiles: try datFiles ?? [
            importDAT("curve.dat"),
        ]
    )
}

private func importRecord(
    id: UUID = importDatasetID,
    tags: [DatasetTagV1] = [],
    associations: [DatasetManualAssociationV1] = [],
    hidden: [DatasetRelativePath] = [],
    axes: [SpectrumAxisPreferenceV1] = [],
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> DatasetRecordV1 {
    try DatasetRecordV1(
        id: id,
        folderBookmark: Data([0x01, 0x02]),
        lastKnownPath: "/tmp/Import Dataset",
        tags: tags,
        manualAssociations: associations,
        hiddenDATPaths: hidden,
        spectrumAxisPreferences: axes,
        updatedAt: updatedAt
    )
}

private func importTransfer(
    tags: [DatasetTagV1] = [],
    associations: [DatasetManualAssociationV1] = [],
    hidden: [DatasetRelativePath] = [],
    axes: [SpectrumAxisPreferenceV1] = []
) throws -> DatasetMetadataTransferV1 {
    try DatasetMetadataTransferV1(
        tags: tags,
        manualAssociations: associations,
        hiddenDATPaths: hidden,
        spectrumAxisPreferences: axes
    )
}

private func importAxis(
    sxmPath: String,
    kind: SpectroscopyKind = .bias,
    experimentIdentity: String? = nil,
    legacy: Bool = false,
    columns: [String] = ["Bias", "Current", "Phase"],
    fingerprint: String? = nil,
    x: String,
    y: String
) throws -> SpectrumAxisPreferenceV1 {
    try SpectrumAxisPreferenceV1(
        sxmPath: sxmPath,
        kind: kind,
        experimentIdentity: legacy
            ? nil
            : (experimentIdentity ?? kind.rawValue),
        schemaFingerprint:
            fingerprint
            ?? SpectroscopyColumnSchema(columns: columns).fingerprint,
        selection: AxisSelection(xColumn: x, yColumn: y)
    )
}

private func capturedInventoryError<T>(
    _ operation: () throws -> T
) -> DatasetMetadataImportInventoryError? {
    do {
        _ = try operation()
        return nil
    } catch let error as DatasetMetadataImportInventoryError {
        return error
    } catch {
        return nil
    }
}

private func capturedApplyError<T>(
    _ operation: () throws -> T
) -> DatasetMetadataImportApplyError? {
    do {
        _ = try operation()
        return nil
    } catch let error as DatasetMetadataImportApplyError {
        return error
    } catch {
        return nil
    }
}

@Test
func importInventoryCanonicalizesOrderAndRejectsInvalidInputs() throws {
    let firstDAT = try importDAT(
        "a.dat",
        automaticParent: "a.sxm"
    )
    let secondDAT = try importDAT(
        "b.dat",
        automaticParent: "b.sxm"
    )
    let inventory = try importInventory(
        sxmPaths: ["b.sxm", "a.sxm"],
        datFiles: [secondDAT, firstDAT]
    )
    #expect(inventory.sxmPaths.map(\.rawValue) == ["a.sxm", "b.sxm"])
    #expect(inventory.datFiles.map(\.path.rawValue) == ["a.dat", "b.dat"])

    #expect(
        capturedInventoryError {
            try importInventory(sxmPaths: ["a.sxm", "a.sxm"])
        } == .duplicateSXMPath(try sxm("a.sxm"))
    )
    #expect(
        capturedInventoryError {
            try importInventory(
                datFiles: [firstDAT, firstDAT]
            )
        } == .duplicateDATPath(try dat("a.dat"))
    )

    let wrongSXM = try DatasetRelativePath.dat("wrong.dat")
    guard case let .invalidPath(kind, path, _) =
        capturedInventoryError({
            try DatasetMetadataImportInventory(
                revisionID: importRevisionID,
                sessionID: importSessionID,
                datasetID: importDatasetID,
                sxmPaths: [wrongSXM],
                datFiles: []
            )
        })
    else {
        Issue.record("Expected an invalid SXM extension")
        return
    }
    #expect(kind == .sxm)
    #expect(path == wrongSXM)

    let wrongDAT = DatasetMetadataImportDATFile(
        path: try sxm("wrong.sxm"),
        kind: .bias,
        schemaFingerprint:
            SpectroscopyColumnSchema(columns: ["X", "Y"]).fingerprint,
        columns: ["X", "Y"],
        automaticParentSXMPath: try sxm("a.sxm")
    )
    guard case let .invalidPath(datKind, _, _) =
        capturedInventoryError({
            try importInventory(datFiles: [wrongDAT])
        })
    else {
        Issue.record("Expected an invalid DAT extension")
        return
    }
    #expect(datKind == .dat)

    let missingParent = try importDAT(
        "missing-parent.dat",
        automaticParent: "gone.sxm"
    )
    #expect(
        capturedInventoryError {
            try importInventory(datFiles: [missingParent])
        } == .automaticParentMissing(
            datPath: try dat("missing-parent.dat"),
            parentSXMPath: try sxm("gone.sxm")
        )
    )

    let wrongParent = DatasetMetadataImportDATFile(
        path: try dat("wrong-parent.dat"),
        kind: .bias,
        schemaFingerprint:
            SpectroscopyColumnSchema(columns: ["X", "Y"]).fingerprint,
        columns: ["X", "Y"],
        automaticParentSXMPath: try dat("not-an-sxm.dat")
    )
    guard case let .invalidPath(parentKind, parentPath, _) =
        capturedInventoryError({
            try importInventory(datFiles: [wrongParent])
        })
    else {
        Issue.record("Expected an invalid automatic-parent extension")
        return
    }
    #expect(parentKind == .sxm)
    let expectedWrongParent = try dat("not-an-sxm.dat")
    #expect(parentPath == expectedWrongParent)

    let fingerprintMismatch = try importDAT(
        "fingerprint.dat",
        fingerprint: "0000000000000000"
    )
    guard case let .schemaFingerprintMismatch(
        fingerprintPath,
        expected,
        actual
    ) = capturedInventoryError({
        try importInventory(datFiles: [fingerprintMismatch])
    }) else {
        Issue.record("Expected a schema fingerprint mismatch")
        return
    }
    let expectedFingerprintPath = try dat("fingerprint.dat")
    #expect(fingerprintPath == expectedFingerprintPath)
    #expect(expected != actual)
    #expect(actual == "0000000000000000")

    let ambiguousColumns = ["Bias", " bias ", "Current"]
    let ambiguous = try importDAT(
        "ambiguous.dat",
        columns: ambiguousColumns
    )
    #expect(
        capturedInventoryError {
            try importInventory(datFiles: [ambiguous])
        } == .ambiguousNormalizedColumn(
            datPath: try dat("ambiguous.dat"),
            normalizedColumn: "bias",
            columns: [" bias ", "Bias"]
        )
    )
}

@Test
func tagMergePreservesDestinationOrderIdentityAndOfflineMembers()
    throws
{
    let offline = try sxm("offline.sxm")
    let tagA = try DatasetTagV1(
        id: destinationTagAID,
        name: "Alpha",
        sxmPaths: [offline, try sxm("a.sxm")]
    )
    let tagB = try DatasetTagV1(
        id: destinationTagBID,
        name: "Beta"
    )
    let destination = try importRecord(tags: [tagA, tagB])

    let importedA = try DatasetTagV1(
        id: destinationTagAID,
        name: "Alpha",
        sxmPaths: [try sxm("b.sxm")]
    )
    let importedByName = try DatasetTagV1(
        id: importedTagID,
        name: "bEtA",
        sxmPaths: [try sxm("a.sxm")]
    )
    let newID = UUID(
        uuidString: "d0000000-0000-0000-0000-00000000000d"
    )!
    let newTag = try DatasetTagV1(
        id: newID,
        name: "New",
        sxmPaths: [
            try sxm("b.sxm"),
            try sxm("missing.sxm"),
        ]
    )
    let transfer = try importTransfer(
        tags: [importedA, importedByName, newTag]
    )

    let plan = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: importInventory()
    )

    #expect(plan.canApply)
    #expect(plan.hasChanges)
    #expect(
        plan.preview.tags.map(\.id)
            == [destinationTagAID, destinationTagBID, newID]
    )
    #expect(plan.preview.tags[0].name == "Alpha")
    #expect(plan.preview.tags[1].name == "Beta")
    #expect(
        plan.preview.tags[0].sxmPaths
            == [offline, try sxm("a.sxm"), try sxm("b.sxm")]
    )
    #expect(
        plan.preview.tags[1].sxmPaths == [try sxm("a.sxm")]
    )
    #expect(
        plan.preview.tags[2].sxmPaths == [try sxm("b.sxm")]
    )
    let missingMemberPath = try sxm("missing.sxm")
    #expect(
        plan.issues.contains {
            $0 == .missingTagMember(
                tagID: newID,
                sxmPath: missingMemberPath
            )
        }
    )
    #expect(
        plan.issues.contains {
            if case let .tagIdentityConflict(
                kind,
                importedID,
                _,
                _,
                nameMatchedID,
                resolution
            ) = $0 {
                return kind == .sameNameDifferentUUID
                    && importedID == importedTagID
                    && nameMatchedID == destinationTagBID
                    && resolution == .keptDestination
            }
            return false
        }
    )
}

@Test
func tagIdentityPoliciesHandleRenameAndCrossMatchWithoutReplacingIDs()
    throws
{
    let tagA = try DatasetTagV1(
        id: destinationTagAID,
        name: "Alpha"
    )
    let tagB = try DatasetTagV1(
        id: destinationTagBID,
        name: "Beta"
    )
    let destination = try importRecord(tags: [tagA, tagB])
    let renameTransfer = try importTransfer(
        tags: [
            DatasetTagV1(
                id: destinationTagAID,
                name: "Renamed",
                sxmPathStrings: ["a.sxm"]
            ),
        ]
    )

    let keep = try DatasetMetadataImportPlanner().plan(
        transfer: renameTransfer,
        into: destination,
        inventory: importInventory(),
        policy: DatasetMetadataImportPolicy(
            tagIdentity: .keepDestination
        )
    )
    let use = try DatasetMetadataImportPlanner().plan(
        transfer: renameTransfer,
        into: destination,
        inventory: importInventory(),
        policy: DatasetMetadataImportPolicy(
            tagIdentity: .useImported
        )
    )
    let require = try DatasetMetadataImportPlanner().plan(
        transfer: renameTransfer,
        into: destination,
        inventory: importInventory(),
        policy: .requireDecisions
    )

    #expect(keep.preview.tags[0].name == "Alpha")
    #expect(use.preview.tags[0].name == "Renamed")
    #expect(use.preview.tags.map(\.id) == [destinationTagAID, destinationTagBID])
    #expect(keep.canApply)
    #expect(use.canApply)
    #expect(!require.canApply)

    let crossTransfer = try importTransfer(
        tags: [
            DatasetTagV1(
                id: destinationTagAID,
                name: "Beta",
                sxmPathStrings: ["b.sxm"]
            ),
        ]
    )
    let crossKeep = try DatasetMetadataImportPlanner().plan(
        transfer: crossTransfer,
        into: destination,
        inventory: importInventory(),
        policy: DatasetMetadataImportPolicy(
            tagIdentity: .keepDestination
        )
    )
    let crossUse = try DatasetMetadataImportPlanner().plan(
        transfer: crossTransfer,
        into: destination,
        inventory: importInventory(),
        policy: DatasetMetadataImportPolicy(
            tagIdentity: .useImported
        )
    )
    let crossRequire = try DatasetMetadataImportPlanner().plan(
        transfer: crossTransfer,
        into: destination,
        inventory: importInventory(),
        policy: .requireDecisions
    )

    #expect(
        crossKeep.preview.tags[0].sxmPaths == [try sxm("b.sxm")]
    )
    #expect(crossKeep.preview.tags[1].sxmPaths.isEmpty)
    #expect(crossUse.preview.tags[0].sxmPaths.isEmpty)
    #expect(
        crossUse.preview.tags[1].sxmPaths == [try sxm("b.sxm")]
    )
    #expect(
        crossUse.preview.tags.map(\.id)
            == [destinationTagAID, destinationTagBID]
    )
    #expect(!crossRequire.canApply)
}

@Test
func associationPoliciesRetainOfflineStateAndReportMissingImports()
    throws
{
    let inventory = try importInventory(
        sxmPaths: ["a.sxm", "b.sxm"],
        datFiles: [
            importDAT("conflict.dat"),
            importDAT("new.dat"),
            importDAT("blocked.dat"),
            importDAT("same.dat"),
        ]
    )
    let destination = try importRecord(
        associations: [
            DatasetManualAssociationV1(
                datPath: "conflict.dat",
                sxmPath: "a.sxm"
            ),
            DatasetManualAssociationV1(
                datPath: "offline.dat",
                sxmPath: "offline.sxm"
            ),
            DatasetManualAssociationV1(
                datPath: "blocked.dat",
                sxmPath: "missing-target.sxm"
            ),
            DatasetManualAssociationV1(
                datPath: "same.dat",
                sxmPath: "a.sxm"
            ),
        ]
    )
    let transfer = try importTransfer(
        associations: [
            DatasetManualAssociationV1(
                datPath: "conflict.dat",
                sxmPath: "b.sxm"
            ),
            DatasetManualAssociationV1(
                datPath: "new.dat",
                sxmPath: "b.sxm"
            ),
            DatasetManualAssociationV1(
                datPath: "gone.dat",
                sxmPath: "a.sxm"
            ),
            DatasetManualAssociationV1(
                datPath: "blocked.dat",
                sxmPath: "gone.sxm"
            ),
            DatasetManualAssociationV1(
                datPath: "same.dat",
                sxmPath: "a.sxm"
            ),
        ]
    )

    let keep = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: inventory,
        policy: DatasetMetadataImportPolicy(
            association: .keepDestination
        )
    )
    let use = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: inventory,
        policy: DatasetMetadataImportPolicy(
            association: .useImported
        )
    )
    let require = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: inventory,
        policy: .requireDecisions
    )
    let safeDefault = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: inventory
    )

    func target(
        _ datPath: String,
        in plan: DatasetMetadataImportPlan
    ) -> String? {
        plan.preview.manualAssociations.first {
            $0.datPath.rawValue == datPath
        }?.sxmPath.rawValue
    }

    #expect(target("conflict.dat", in: keep) == "a.sxm")
    #expect(target("conflict.dat", in: use) == "b.sxm")
    #expect(target("new.dat", in: use) == "b.sxm")
    #expect(target("same.dat", in: use) == "a.sxm")
    #expect(target("offline.dat", in: use) == "offline.sxm")
    #expect(target("blocked.dat", in: use) == "missing-target.sxm")
    #expect(safeDefault == keep)
    #expect(keep.canApply)
    #expect(use.canApply)
    #expect(!require.canApply)
    let goneDATPath = try dat("gone.dat")
    let blockedDATPath = try dat("blocked.dat")
    let goneSXMPath = try sxm("gone.sxm")
    #expect(
        use.issues.contains {
            $0 == .associationDATMissing(goneDATPath)
        }
    )
    #expect(
        use.issues.contains {
            $0 == .associationSXMMissing(
                datPath: blockedDATPath,
                sxmPath: goneSXMPath
            )
        }
    )
}

@Test
func hiddenImportUsesUnionReportsMissingAndRetainsOfflinePaths()
    throws
{
    let offline = try dat("offline.dat")
    let destination = try importRecord(hidden: [offline])
    let transfer = try importTransfer(
        hidden: [
            try dat("curve.dat"),
            try dat("gone.dat"),
        ]
    )
    let plan = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: importInventory()
    )

    #expect(
        plan.preview.hiddenDATPaths
            == [offline, try dat("curve.dat")]
    )
    #expect(
        plan.issues.contains(.hiddenDATMissing(try dat("gone.dat")))
    )
    #expect(plan.summary.hiddenActionCount == 1)
}

@Test
func associationMergePrecedesAxisGroupingAndHiddenCurvesStillCount()
    throws
{
    let columns = ["Bias", "Current", "Phase"]
    let inventory = try importInventory(
        datFiles: [
            importDAT(
                "curve.dat",
                columns: columns,
                automaticParent: "a.sxm"
            ),
        ]
    )
    let movedAxis = try importAxis(
        sxmPath: "b.sxm",
        columns: columns,
        x: "Bias",
        y: "Phase"
    )
    let transfer = try importTransfer(
        associations: [
            DatasetManualAssociationV1(
                datPath: "curve.dat",
                sxmPath: "b.sxm"
            ),
        ],
        hidden: [try dat("curve.dat")],
        axes: [movedAxis]
    )

    let plan = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: importRecord(),
        inventory: inventory
    )

    #expect(plan.canApply)
    #expect(plan.preview.manualAssociations.count == 1)
    #expect(plan.preview.hiddenDATPaths == [try dat("curve.dat")])
    #expect(plan.preview.spectrumAxisPreferences == [movedAxis])
    #expect(
        !plan.issues.contains {
            if case .axisGroupUnavailable = $0 { return true }
            return false
        }
    )
}

@Test
func importAxisPreferencesStayIndependentByExperiment() throws {
    let columns = ["Frequency", "Current", "Phase"]
    let inventory = try importInventory(
        datFiles: [
            importDAT(
                "frequency.dat",
                kind: .other,
                experiment: "Frequency Sweep",
                columns: columns
            ),
            importDAT(
                "lock-in.dat",
                kind: .other,
                experiment: "Lock-In Sweep",
                columns: columns
            ),
        ]
    )
    let frequency = try importAxis(
        sxmPath: "a.sxm",
        kind: .other,
        experimentIdentity: "frequency sweep",
        columns: columns,
        x: "Frequency",
        y: "Phase"
    )
    let lockIn = try importAxis(
        sxmPath: "a.sxm",
        kind: .other,
        experimentIdentity: "lock-in sweep",
        columns: columns,
        x: "Phase",
        y: "Current"
    )

    let plan = try DatasetMetadataImportPlanner().plan(
        transfer: importTransfer(axes: [lockIn, frequency]),
        into: importRecord(),
        inventory: inventory
    )

    #expect(plan.issues.isEmpty)
    #expect(
        Set(plan.preview.spectrumAxisPreferences)
            == Set([frequency, lockIn])
    )
}

@Test
func importUniquelyUpgradesLegacyExperimentAxisKey() throws {
    let columns = ["Frequency", "Current", "Phase"]
    let inventory = try importInventory(
        datFiles: [
            importDAT(
                "frequency.dat",
                kind: .other,
                experiment: " Frequency   Sweep ",
                columns: columns
            ),
        ]
    )
    let legacy = try importAxis(
        sxmPath: "a.sxm",
        kind: .other,
        legacy: true,
        columns: columns,
        x: "Frequency",
        y: "Phase"
    )

    let plan = try DatasetMetadataImportPlanner().plan(
        transfer: importTransfer(axes: [legacy]),
        into: importRecord(),
        inventory: inventory
    )

    #expect(plan.issues.isEmpty)
    #expect(
        plan.preview.spectrumAxisPreferences.first?
            .key.experimentIdentity == "frequency sweep"
    )
}

@Test
func importRejectsAmbiguousLegacyExperimentAxisKey() throws {
    let columns = ["Frequency", "Current", "Phase"]
    let inventory = try importInventory(
        datFiles: [
            importDAT(
                "frequency.dat",
                kind: .other,
                experiment: "Frequency Sweep",
                columns: columns
            ),
            importDAT(
                "lock-in.dat",
                kind: .other,
                experiment: "Lock-In Sweep",
                columns: columns
            ),
        ]
    )
    let legacy = try importAxis(
        sxmPath: "a.sxm",
        kind: .other,
        legacy: true,
        columns: columns,
        x: "Frequency",
        y: "Phase"
    )

    let plan = try DatasetMetadataImportPlanner().plan(
        transfer: importTransfer(axes: [legacy]),
        into: importRecord(),
        inventory: inventory
    )

    #expect(plan.preview.spectrumAxisPreferences.isEmpty)
    #expect(
        plan.issues == [
            .axisExperimentAmbiguous(
                key: legacy.key,
                availableIdentities: [
                    "frequency sweep",
                    "lock-in sweep",
                ]
            ),
        ]
    )
}

@Test
func missingManualTargetBlocksAutomaticFallbackDuringAxisPlanning()
    throws
{
    let columns = ["Bias", "Current"]
    let inventory = try importInventory(
        datFiles: [
            importDAT(
                "curve.dat",
                columns: columns,
                automaticParent: "a.sxm"
            ),
        ]
    )
    let destination = try importRecord(
        associations: [
            DatasetManualAssociationV1(
                datPath: "curve.dat",
                sxmPath: "offline.sxm"
            ),
        ]
    )
    let automaticAxis = try importAxis(
        sxmPath: "a.sxm",
        columns: columns,
        x: "Bias",
        y: "Current"
    )
    let plan = try DatasetMetadataImportPlanner().plan(
        transfer: importTransfer(axes: [automaticAxis]),
        into: destination,
        inventory: inventory
    )

    #expect(plan.preview.spectrumAxisPreferences.isEmpty)
    #expect(
        plan.issues.contains {
            if case let .axisGroupUnavailable(key, _) = $0 {
                return key == automaticAxis.key
            }
            return false
        }
    )
}

@Test
func axisGroupsUseFirstSortedDATColumnsAndSkipUnavailableOrMissing()
    throws
{
    let firstColumns = ["Bias", "Current"]
    let variantColumns = [" bias ", " current "]
    let fingerprint = SpectroscopyColumnSchema(
        columns: firstColumns
    ).fingerprint
    let inventory = try importInventory(
        datFiles: [
            importDAT(
                "a.dat",
                columns: firstColumns,
                automaticParent: "a.sxm"
            ),
            importDAT(
                "b.dat",
                columns: variantColumns,
                automaticParent: "a.sxm"
            ),
        ]
    )
    let normalizedSelection = try importAxis(
        sxmPath: "a.sxm",
        columns: firstColumns,
        fingerprint: fingerprint,
        x: "BIAS",
        y: "CURRENT"
    )
    let unavailable = try importAxis(
        sxmPath: "b.sxm",
        columns: firstColumns,
        fingerprint: fingerprint,
        x: "Bias",
        y: "Current"
    )
    let missing = try importAxis(
        sxmPath: "a.sxm",
        columns: firstColumns,
        fingerprint: fingerprint,
        x: "Not Present",
        y: "Current"
    )

    let representativePlan = try DatasetMetadataImportPlanner().plan(
        transfer: importTransfer(axes: [normalizedSelection]),
        into: importRecord(),
        inventory: inventory
    )
    #expect(representativePlan.issues.isEmpty)
    #expect(
        representativePlan.preview.spectrumAxisPreferences
            == [
                try importAxis(
                    sxmPath: "a.sxm",
                    columns: firstColumns,
                    fingerprint: fingerprint,
                    x: "Bias",
                    y: "Current"
                ),
            ]
    )

    let otherPlans = try DatasetMetadataImportPlanner().plan(
        transfer: importTransfer(axes: [unavailable, missing]),
        into: importRecord(),
        inventory: inventory
    )
    #expect(otherPlans.preview.spectrumAxisPreferences.isEmpty)
    #expect(
        otherPlans.issues.contains {
            if case let .axisGroupUnavailable(key, _) = $0 {
                return key == unavailable.key
            }
            return false
        }
    )
    #expect(
        otherPlans.issues.contains {
            if case let .axisColumnMissing(key, axis, column) = $0 {
                return key == missing.key
                    && axis == .x
                    && column == "Not Present"
            }
            return false
        }
    )
}

@Test
func axisConflictPoliciesAreIndependentAndPreserveOfflinePreferences()
    throws
{
    let columns = ["Bias", "Current", "Phase"]
    let existing = try importAxis(
        sxmPath: "a.sxm",
        columns: columns,
        x: "Bias",
        y: "Current"
    )
    let imported = try importAxis(
        sxmPath: "a.sxm",
        columns: columns,
        x: "Bias",
        y: "Phase"
    )
    let offline = try importAxis(
        sxmPath: "offline.sxm",
        columns: columns,
        x: "Bias",
        y: "Current"
    )
    let destination = try importRecord(axes: [offline, existing])
    let transfer = try importTransfer(axes: [imported])

    let keep = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: importInventory(),
        policy: DatasetMetadataImportPolicy(axis: .keepDestination)
    )
    let use = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: importInventory(),
        policy: DatasetMetadataImportPolicy(axis: .useImported)
    )
    let require = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: importInventory(),
        policy: .requireDecisions
    )

    #expect(keep.preview.spectrumAxisPreferences == [offline, existing])
    #expect(use.preview.spectrumAxisPreferences == [offline, imported])
    #expect(keep.canApply)
    #expect(use.canApply)
    #expect(!require.canApply)
}

@Test
func planApplyRejectsDatasetRecordInventoryStalenessAndUnresolved()
    throws
{
    let destination = try importRecord()
    let inventory = try importInventory()
    let transfer = try importTransfer(
        hidden: [try dat("curve.dat")]
    )
    let plan = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: inventory
    )
    let appliedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let applied = try plan.applying(
        to: destination,
        inventory: inventory,
        updatedAt: appliedDate
    )
    #expect(applied.hiddenDATPaths == [try dat("curve.dat")])
    #expect(applied.updatedAt == appliedDate)
    #expect(applied.id == destination.id)
    #expect(applied.folderBookmark == destination.folderBookmark)
    #expect(applied.lastKnownPath == destination.lastKnownPath)

    let otherDatasetID = UUID(
        uuidString: "40000000-0000-0000-0000-000000000004"
    )!
    let otherRecord = try importRecord(id: otherDatasetID)
    let otherInventory = try importInventory(datasetID: otherDatasetID)
    guard case .datasetStale = capturedApplyError({
        try plan.applying(
            to: otherRecord,
            inventory: otherInventory,
            updatedAt: appliedDate
        )
    }) else {
        Issue.record("Expected dataset stale rejection")
        return
    }

    var changedRecord = destination
    _ = try changedRecord.createTag(name: "Concurrent")
    #expect(
        capturedApplyError {
            try plan.applying(
                to: changedRecord,
                inventory: inventory,
                updatedAt: appliedDate
            )
        } == .recordStale
    )

    let changedInventory = try importInventory(
        revisionID: UUID(
            uuidString: "50000000-0000-0000-0000-000000000005"
        )!
    )
    guard case .inventoryStale = capturedApplyError({
        try plan.applying(
            to: destination,
            inventory: changedInventory,
            updatedAt: appliedDate
        )
    }) else {
        Issue.record("Expected inventory stale rejection")
        return
    }

    let changedSessionInventory = try importInventory(
        sessionID: UUID(
            uuidString: "60000000-0000-0000-0000-000000000006"
        )!
    )
    guard case .inventoryStale = capturedApplyError({
        try plan.applying(
            to: destination,
            inventory: changedSessionInventory,
            updatedAt: appliedDate
        )
    }) else {
        Issue.record("Expected session change to make inventory stale")
        return
    }

    let conflictDestination = try importRecord(
        associations: [
            DatasetManualAssociationV1(
                datPath: "curve.dat",
                sxmPath: "a.sxm"
            ),
        ]
    )
    let conflictTransfer = try importTransfer(
        associations: [
            DatasetManualAssociationV1(
                datPath: "curve.dat",
                sxmPath: "b.sxm"
            ),
        ]
    )
    let unresolved = try DatasetMetadataImportPlanner().plan(
        transfer: conflictTransfer,
        into: conflictDestination,
        inventory: inventory,
        policy: .requireDecisions
    )
    #expect(!unresolved.canApply)
    #expect(
        capturedApplyError {
            try unresolved.applying(
                to: conflictDestination,
                inventory: inventory,
                updatedAt: appliedDate
            )
        } == .unresolvedConflicts(1)
    )
}

@Test
func noOpDoesNotAdvanceDateAndReimportAfterApplyIsIdempotent()
    throws
{
    let inventory = try importInventory()
    let destination = try importRecord()
    let transfer = try importTransfer(
        tags: [
            DatasetTagV1(
                id: importedTagID,
                name: "Imported",
                sxmPathStrings: ["a.sxm"]
            ),
        ],
        hidden: [try dat("curve.dat")]
    )
    let firstPlan = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: inventory
    )
    let applied = try firstPlan.applying(
        to: destination,
        inventory: inventory,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let secondPlan = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: applied,
        inventory: inventory
    )

    #expect(firstPlan.hasChanges)
    #expect(!secondPlan.hasChanges)
    #expect(secondPlan.actions.isEmpty)
    let returned = try secondPlan.applying(
        to: applied,
        inventory: inventory,
        updatedAt: Date(
            timeIntervalSinceReferenceDate: Double.nan
        )
    )
    #expect(returned == applied)
    #expect(returned.updatedAt == applied.updatedAt)
}

@Test
func importPlansAreDeterministicAcrossInventoryInputOrdering()
    throws
{
    let firstDAT = try importDAT(
        "a.dat",
        automaticParent: "a.sxm"
    )
    let secondDAT = try importDAT(
        "b.dat",
        automaticParent: "b.sxm"
    )
    let firstInventory = try importInventory(
        sxmPaths: ["b.sxm", "a.sxm"],
        datFiles: [secondDAT, firstDAT]
    )
    let secondInventory = try importInventory(
        sxmPaths: ["a.sxm", "b.sxm"],
        datFiles: [firstDAT, secondDAT]
    )
    let destination = try importRecord()
    let transfer = try importTransfer(
        tags: [
            DatasetTagV1(
                id: importedTagID,
                name: "Imported",
                sxmPathStrings: ["b.sxm", "a.sxm"]
            ),
        ],
        hidden: [try dat("b.dat"), try dat("a.dat")]
    )

    let first = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: firstInventory
    )
    let second = try DatasetMetadataImportPlanner().plan(
        transfer: transfer,
        into: destination,
        inventory: secondInventory
    )

    #expect(first == second)
    #expect(
        first.actions == [
            .addTag(
                try DatasetTagV1(
                    id: importedTagID,
                    name: "Imported",
                    sxmPathStrings: ["a.sxm", "b.sxm"]
                )
            ),
            .hideDAT(try dat("a.dat")),
            .hideDAT(try dat("b.dat")),
        ]
    )
}
