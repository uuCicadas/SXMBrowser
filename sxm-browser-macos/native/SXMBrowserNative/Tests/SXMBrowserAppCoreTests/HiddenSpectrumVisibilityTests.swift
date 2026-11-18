import Foundation
import Testing
@testable import SXMBrowserAppCore

private func hiddenSpectrumIndex(
    folder: URL,
    datItems: [(UUID, String)]
) throws -> DatasetPathIndex {
    try DatasetPathIndex(
        folderURL: folder,
        sxmItems: [],
        datItems: datItems.map {
            DatasetPathItem(
                id: $0.0,
                url: folder.appendingPathComponent($0.1)
            )
        }
    )
}

@Test
func hiddenPathsRestoreAfterRuntimeIDsChange() throws {
    let folder = URL(fileURLWithPath: "/tmp/Hidden-Reopen")
    let firstID = UUID()
    let reopenedID = UUID()
    let hiddenPath = try DatasetRelativePath.dat("spectra/curve.dat")
    let firstIndex = try hiddenSpectrumIndex(
        folder: folder,
        datItems: [(firstID, hiddenPath.rawValue)]
    )
    let reopenedIndex = try hiddenSpectrumIndex(
        folder: folder,
        datItems: [(reopenedID, hiddenPath.rawValue)]
    )

    let first = HiddenSpectrumProjection(
        hiddenDATPaths: [hiddenPath],
        pathIndex: firstIndex
    )
    let reopened = HiddenSpectrumProjection(
        hiddenDATPaths: [hiddenPath],
        pathIndex: reopenedIndex
    )

    #expect(first.hiddenDATIDs == [firstID])
    #expect(reopened.hiddenDATIDs == [reopenedID])
    #expect(reopened.persistedDATPaths == [hiddenPath])
}

@Test
func hiddenProjectionAndUpdatesPreserveMissingDATPaths() throws {
    let folder = URL(fileURLWithPath: "/tmp/Hidden-Missing")
    let availableID = UUID()
    let availablePath = try DatasetRelativePath.dat("available.dat")
    let missingPath = try DatasetRelativePath.dat("offline/missing.dat")
    let index = try hiddenSpectrumIndex(
        folder: folder,
        datItems: [(availableID, availablePath.rawValue)]
    )
    let projection = HiddenSpectrumProjection(
        hiddenDATPaths: [missingPath, availablePath],
        pathIndex: index
    )
    let showAvailable = try HiddenSpectrumUpdatePlan(
        datID: availableID,
        visible: true,
        pathIndex: index
    )

    #expect(projection.hiddenDATIDs == [availableID])
    #expect(projection.missingDATPaths == [missingPath])
    #expect(
        try showAvailable.applying(to: projection.persistedDATPaths)
            == [missingPath]
    )
}

@Test
func hideAndShowOnlyChangeTheRequestedPathInStableOrder() throws {
    let folder = URL(fileURLWithPath: "/tmp/Hidden-Update")
    let targetID = UUID()
    let targetPath = try DatasetRelativePath.dat("middle.dat")
    let firstPath = try DatasetRelativePath.dat("alpha.dat")
    let lastPath = try DatasetRelativePath.dat("zulu.dat")
    let index = try hiddenSpectrumIndex(
        folder: folder,
        datItems: [(targetID, targetPath.rawValue)]
    )
    let hide = try HiddenSpectrumUpdatePlan(
        datID: targetID,
        visible: false,
        pathIndex: index
    )
    let show = try HiddenSpectrumUpdatePlan(
        datID: targetID,
        visible: true,
        pathIndex: index
    )

    let hidden = try hide.applying(
        to: [lastPath, firstPath, lastPath]
    )
    #expect(hidden == [firstPath, targetPath, lastPath])
    #expect(try hide.applying(to: hidden) == hidden)
    #expect(
        try show.applying(to: hidden)
            == [firstPath, lastPath]
    )
}

@Test
func associationUpdatesDoNotChangeHiddenSpectrumPaths() throws {
    let folder = URL(fileURLWithPath: "/tmp/Hidden-Association")
    let sxmID = UUID()
    let datID = UUID()
    let hiddenPath = try DatasetRelativePath.dat("curve.dat")
    let index = try DatasetPathIndex(
        folderURL: folder,
        sxmItems: [
            DatasetPathItem(
                id: sxmID,
                url: folder.appendingPathComponent("image.sxm")
            ),
        ],
        datItems: [
            DatasetPathItem(
                id: datID,
                url: folder.appendingPathComponent(hiddenPath.rawValue)
            ),
        ]
    )
    let plan = try ManualAssociationUpdatePlan(
        datIDs: [datID],
        targetSXMID: sxmID,
        pathIndex: index
    )
    var record = try DatasetRecordV1(
        lastKnownPath: folder.path,
        hiddenDATPaths: [hiddenPath],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    try record.replaceManualAssociations(
        with: plan.applying(to: record.manualAssociations),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )

    #expect(record.hiddenDATPaths == [hiddenPath])
}
