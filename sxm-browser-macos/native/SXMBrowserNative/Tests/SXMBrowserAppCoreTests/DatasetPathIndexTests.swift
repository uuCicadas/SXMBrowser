import Foundation
import Testing
@testable import SXMBrowserAppCore

private func capturedPathIndexError(
    _ operation: () throws -> DatasetPathIndex
) -> DatasetPathIndexError? {
    do {
        _ = try operation()
        return nil
    } catch let error as DatasetPathIndexError {
        return error
    } catch {
        return nil
    }
}

private func sessionRecord(
    id: UUID,
    folderURL: URL
) throws -> DatasetRecordV1 {
    try DatasetRecordV1(
        id: id,
        lastKnownPath: try DatasetMetadataStore.standardizedFolderPath(
            for: folderURL
        ),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func activeSession(
    sessionID: UUID,
    datasetID: UUID,
    folderURL: URL
) throws -> ActiveDatasetSession {
    let record = try sessionRecord(id: datasetID, folderURL: folderURL)
    let index = try DatasetPathIndex(
        folderURL: folderURL,
        sxmItems: [],
        datItems: []
    )
    return try ActiveDatasetSession(
        sessionID: sessionID,
        datasetID: datasetID,
        folderURL: folderURL,
        verifiedRecord: record,
        pathIndex: index
    )
}

@Test
func offlineUnicodePathsCreateStableNFCBidirectionalIndexes() throws {
    let folderURL = URL(fileURLWithPath: "/Volumes/离线数据/实验")
    let sxmID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    let datID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
    let decomposedSXM = folderURL.appendingPathComponent(
        "区域/Cafe\u{301}.SXM"
    )
    let datURL = folderURL.appendingPathComponent("谱图/测量.DAT")

    let index = try DatasetPathIndex(
        folderURL: folderURL,
        sxmItems: [DatasetPathItem(id: sxmID, url: decomposedSXM)],
        datItems: [DatasetPathItem(id: datID, url: datURL)]
    )
    let sxmPath = try #require(index.sxmPath(for: sxmID))
    let datPath = try #require(index.datPath(for: datID))

    #expect(sxmPath.rawValue == "区域/Café.SXM")
    #expect(datPath.rawValue == "谱图/测量.DAT")
    #expect(index.sxmID(for: sxmPath) == sxmID)
    #expect(index.datID(for: datPath) == datID)
    #expect(
        index.folderURL.path
            == "/Volumes/离线数据/实验"
    )
}

@Test
func componentContainmentRejectsSiblingPrefixAndParentTraversal() {
    let folderURL = URL(fileURLWithPath: "/tmp/A")
    let id = UUID()
    let siblingURL = URL(fileURLWithPath: "/tmp/AB/image.sxm")
    let traversedURL = folderURL.appendingPathComponent(
        "../AB/image.sxm"
    )

    for outsideURL in [siblingURL, traversedURL] {
        let error = capturedPathIndexError {
            try DatasetPathIndex(
                folderURL: folderURL,
                sxmItems: [DatasetPathItem(id: id, url: outsideURL)],
                datItems: []
            )
        }
        guard case let .itemOutsideFolder(kind, _, rejectedFolder) = error else {
            Issue.record("Expected an outside-folder error")
            continue
        }
        #expect(kind == .sxm)
        #expect(rejectedFolder.path == folderURL.path)
    }
}

@Test
func wrongExtensionsAndNonFileURLsAreRejected() {
    let folderURL = URL(fileURLWithPath: "/tmp/Dataset")
    let wrongExtensionURL = folderURL.appendingPathComponent("image.dat")
    let wrongExtensionError = capturedPathIndexError {
        try DatasetPathIndex(
            folderURL: folderURL,
            sxmItems: [
                DatasetPathItem(id: UUID(), url: wrongExtensionURL),
            ],
            datItems: []
        )
    }
    guard case let .invalidRelativePath(kind, _, underlying) =
        wrongExtensionError else {
        Issue.record("Expected an invalid-relative-path error")
        return
    }
    #expect(kind == .sxm)
    #expect(
        underlying == .unexpectedFileExtension(
            path: "image.dat",
            expected: .sxm,
            actual: "dat"
        )
    )

    let remoteURL = URL(string: "https://example.test/image.sxm")!
    let remoteError = capturedPathIndexError {
        try DatasetPathIndex(
            folderURL: folderURL,
            sxmItems: [DatasetPathItem(id: UUID(), url: remoteURL)],
            datItems: []
        )
    }
    guard case let .itemIsNotFileURL(remoteKind, rejectedURL) =
        remoteError else {
        Issue.record("Expected a non-file URL error")
        return
    }
    #expect(remoteKind == .sxm)
    #expect(rejectedURL == remoteURL)
}

@Test
func duplicateIDsAndCanonicalRelativePathsAreRejected() throws {
    let folderURL = URL(fileURLWithPath: "/tmp/Dataset")
    let repeatedID = UUID()
    let duplicateIDError = capturedPathIndexError {
        try DatasetPathIndex(
            folderURL: folderURL,
            sxmItems: [
                DatasetPathItem(
                    id: repeatedID,
                    url: folderURL.appendingPathComponent("one.sxm")
                ),
                DatasetPathItem(
                    id: repeatedID,
                    url: folderURL.appendingPathComponent("two.sxm")
                ),
            ],
            datItems: []
        )
    }
    #expect(
        duplicateIDError == .duplicateID(
            kind: .sxm,
            id: repeatedID
        )
    )

    let composedURL = folderURL.appendingPathComponent("Café.sxm")
    let decomposedURL = folderURL.appendingPathComponent(
        "Cafe\u{301}.sxm"
    )
    let duplicatePathError = capturedPathIndexError {
        try DatasetPathIndex(
            folderURL: folderURL,
            sxmItems: [
                DatasetPathItem(id: UUID(), url: composedURL),
                DatasetPathItem(id: UUID(), url: decomposedURL),
            ],
            datItems: []
        )
    }
    let expectedPath = try DatasetRelativePath.sxm("Café.sxm")
    #expect(
        duplicatePathError == .duplicateRelativePath(
            kind: .sxm,
            path: expectedPath
        )
    )
}

@Test
func sameFolderReopenUsesSessionUUIDRatherThanURLIdentity() throws {
    let folderURL = URL(fileURLWithPath: "/tmp/Same Dataset")
    let datasetID = UUID()
    let firstID = UUID()
    let secondID = UUID()
    let first = try activeSession(
        sessionID: firstID,
        datasetID: datasetID,
        folderURL: folderURL
    )
    let second = try activeSession(
        sessionID: secondID,
        datasetID: datasetID,
        folderURL: folderURL
    )
    var gate = DatasetSessionGate()

    gate.begin(sessionID: firstID)
    gate.begin(sessionID: secondID)

    #expect(!gate.acceptsOpeningResult(sessionID: firstID))
    let acceptedFirst = gate.activate(first)
    let acceptedSecond = gate.activate(second)
    #expect(!acceptedFirst)
    #expect(acceptedSecond)
    #expect(!gate.accepts(first))
    #expect(gate.accepts(second))
    #expect(second.folderURL == first.folderURL)
}

@Test
func slowFolderAResultCannotReplaceNewerFolderBSession() throws {
    let firstSessionID = UUID()
    let secondSessionID = UUID()
    let first = try activeSession(
        sessionID: firstSessionID,
        datasetID: UUID(),
        folderURL: URL(fileURLWithPath: "/tmp/A")
    )
    let second = try activeSession(
        sessionID: secondSessionID,
        datasetID: UUID(),
        folderURL: URL(fileURLWithPath: "/tmp/B")
    )
    var gate = DatasetSessionGate()

    gate.begin(sessionID: firstSessionID)
    gate.begin(sessionID: secondSessionID)

    let acceptedFirst = gate.activate(first)
    let acceptedSecond = gate.activate(second)
    #expect(!acceptedFirst)
    #expect(acceptedSecond)
    #expect(gate.accepts(second.identity))
    #expect(!gate.accepts(first.identity))
}

@Test
func activeSessionRejectsMismatchedDatasetAndFolderIdentity() throws {
    let folderURL = URL(fileURLWithPath: "/tmp/Dataset")
    let record = try sessionRecord(id: UUID(), folderURL: folderURL)
    let index = try DatasetPathIndex(
        folderURL: folderURL,
        sxmItems: [],
        datItems: []
    )

    #expect(throws: ActiveDatasetSessionError.self) {
        try ActiveDatasetSession(
            datasetID: UUID(),
            folderURL: folderURL,
            verifiedRecord: record,
            pathIndex: index
        )
    }

    let otherIndex = try DatasetPathIndex(
        folderURL: URL(fileURLWithPath: "/tmp/Other"),
        sxmItems: [],
        datItems: []
    )
    #expect(throws: ActiveDatasetSessionError.self) {
        try ActiveDatasetSession(
            datasetID: record.id,
            folderURL: folderURL,
            verifiedRecord: record,
            pathIndex: otherIndex
        )
    }
}
