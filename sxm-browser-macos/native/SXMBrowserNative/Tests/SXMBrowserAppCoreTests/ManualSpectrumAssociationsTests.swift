import Foundation
import Testing
@testable import SXMBrowserAppCore

private func associationIndex(
    folder: URL,
    sxmItems: [(UUID, String)],
    datItems: [(UUID, String)]
) throws -> DatasetPathIndex {
    try DatasetPathIndex(
        folderURL: folder,
        sxmItems: sxmItems.map {
            DatasetPathItem(
                id: $0.0,
                url: folder.appendingPathComponent($0.1)
            )
        },
        datItems: datItems.map {
            DatasetPathItem(
                id: $0.0,
                url: folder.appendingPathComponent($0.1)
            )
        }
    )
}

@Test
func manualAssociationProjectionDistinguishesAllThreeStates() throws {
    let folder = URL(fileURLWithPath: "/tmp/Association")
    let availableSXMID = UUID()
    let datWithTargetID = UUID()
    let datWithMissingTargetID = UUID()
    let automaticDATID = UUID()
    let index = try associationIndex(
        folder: folder,
        sxmItems: [(availableSXMID, "image.sxm")],
        datItems: [
            (datWithTargetID, "manual.dat"),
            (datWithMissingTargetID, "missing.dat"),
            (automaticDATID, "automatic.dat"),
        ]
    )
    let projection = ManualSpectrumAssociationProjection(
        associations: [
            try DatasetManualAssociationV1(
                datPath: "manual.dat",
                sxmPath: "image.sxm"
            ),
            try DatasetManualAssociationV1(
                datPath: "missing.dat",
                sxmPath: "removed.sxm"
            ),
        ],
        pathIndex: index,
        availableSXMIDs: [availableSXMID]
    )

    #expect(
        projection.resolution(forDATID: datWithTargetID)
            == .manual(sxmID: availableSXMID)
    )
    #expect(
        projection.resolution(forDATID: datWithMissingTargetID)
            == .missingManualTarget(
                sxmPath: try DatasetRelativePath.sxm("removed.sxm")
            )
    )
    #expect(
        projection.resolution(forDATID: automaticDATID)
            == .automaticAllowed
    )
    #expect(
        !projection.resolution(forDATID: datWithMissingTargetID)
            .allowsAutomaticAssociation
    )
}

@Test
func relativePathsRestoreAssociationsAfterEveryRuntimeIDChanges() throws {
    let folder = URL(fileURLWithPath: "/tmp/Reopen")
    let firstSXMID = UUID()
    let firstDATID = UUID()
    let secondSXMID = UUID()
    let secondDATID = UUID()
    let association = try DatasetManualAssociationV1(
        datPath: "spectra/curve.dat",
        sxmPath: "scans/image.sxm"
    )
    let firstIndex = try associationIndex(
        folder: folder,
        sxmItems: [(firstSXMID, "scans/image.sxm")],
        datItems: [(firstDATID, "spectra/curve.dat")]
    )
    let secondIndex = try associationIndex(
        folder: folder,
        sxmItems: [(secondSXMID, "scans/image.sxm")],
        datItems: [(secondDATID, "spectra/curve.dat")]
    )

    let first = ManualSpectrumAssociationProjection(
        associations: [association],
        pathIndex: firstIndex,
        availableSXMIDs: [firstSXMID]
    )
    let reopened = ManualSpectrumAssociationProjection(
        associations: [association],
        pathIndex: secondIndex,
        availableSXMIDs: [secondSXMID]
    )

    #expect(
        first.resolution(forDATID: firstDATID)
            == .manual(sxmID: firstSXMID)
    )
    #expect(
        reopened.resolution(forDATID: secondDATID)
            == .manual(sxmID: secondSXMID)
    )
}

@Test
func missingManualTargetNeverAllowsAutomaticFallback() throws {
    let folder = URL(fileURLWithPath: "/tmp/Missing")
    let temptingAutomaticTargetID = UUID()
    let datID = UUID()
    let index = try associationIndex(
        folder: folder,
        sxmItems: [(temptingAutomaticTargetID, "curve.sxm")],
        datItems: [(datID, "curve.dat")]
    )
    let projection = ManualSpectrumAssociationProjection(
        associations: [
            try DatasetManualAssociationV1(
                datPath: "curve.dat",
                sxmPath: "explicit-but-gone.sxm"
            ),
        ],
        pathIndex: index,
        availableSXMIDs: [temptingAutomaticTargetID]
    )

    let resolution = projection.resolution(forDATID: datID)
    #expect(
        resolution == .missingManualTarget(
            sxmPath: try DatasetRelativePath.sxm(
                "explicit-but-gone.sxm"
            )
        )
    )
    #expect(!resolution.allowsAutomaticAssociation)
}

@Test
func batchPlanIsAllOrNothingAndPreservesUnrelatedAssociations() throws {
    let folder = URL(fileURLWithPath: "/tmp/Batch")
    let oldSXMID = UUID()
    let targetSXMID = UUID()
    let firstDATID = UUID()
    let secondDATID = UUID()
    let untouchedDATID = UUID()
    let unknownDATID = UUID()
    let index = try associationIndex(
        folder: folder,
        sxmItems: [
            (oldSXMID, "old.sxm"),
            (targetSXMID, "target.sxm"),
        ],
        datItems: [
            (firstDATID, "first.dat"),
            (secondDATID, "second.dat"),
            (untouchedDATID, "untouched.dat"),
        ]
    )
    let existing = [
        try DatasetManualAssociationV1(
            datPath: "first.dat",
            sxmPath: "old.sxm"
        ),
        try DatasetManualAssociationV1(
            datPath: "untouched.dat",
            sxmPath: "old.sxm"
        ),
    ]
    let plan = try ManualAssociationUpdatePlan(
        datIDs: [secondDATID, firstDATID],
        targetSXMID: targetSXMID,
        pathIndex: index
    )
    let updated = try plan.applying(to: existing)

    #expect(
        updated.map {
            "\($0.datPath.rawValue)→\($0.sxmPath.rawValue)"
        } == [
            "first.dat→target.sxm",
            "second.dat→target.sxm",
            "untouched.dat→old.sxm",
        ]
    )
    #expect(throws: ManualAssociationUpdatePlanError.self) {
        _ = try ManualAssociationUpdatePlan(
            datIDs: [firstDATID, unknownDATID],
            targetSXMID: targetSXMID,
            pathIndex: index
        )
    }
}
