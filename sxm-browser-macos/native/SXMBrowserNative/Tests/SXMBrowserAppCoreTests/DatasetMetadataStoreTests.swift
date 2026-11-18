import Foundation
import Testing
@testable import SXMBrowserAppCore

private enum MetadataStoreTestError: Error {
    case expectedMutationFailure
    case injectedReadFailure
    case injectedWriteFailure
    case injectedBookmarkFailure
}

private final class InMemoryMetadataFileAccess:
    DatasetMetadataFileAccess,
    @unchecked Sendable
{
    private struct State {
        var files: [URL: Data] = [:]
        var directories: Set<URL> = []
        var readCount = 0
        var writeCount = 0
        var removeCount = 0
        var failingReadCalls: Set<Int> = []
        var failNextWriteAfterReplacing = false
    }

    private let lock = NSLock()
    private var state: State

    init(fileURL: URL? = nil, data: Data? = nil) {
        var state = State()
        if let fileURL, let data {
            state.files[fileURL.standardizedFileURL] = data
        }
        self.state = state
    }

    func fileExists(at url: URL) -> Bool {
        withLock {
            state.files[url.standardizedFileURL] != nil
        }
    }

    func createDirectory(at url: URL) throws {
        _ = withLock {
            state.directories.insert(url.standardizedFileURL)
        }
    }

    func readData(at url: URL) throws -> Data {
        try withLock {
            state.readCount += 1
            if state.failingReadCalls.remove(state.readCount) != nil {
                throw MetadataStoreTestError.injectedReadFailure
            }
            guard let data = state.files[url.standardizedFileURL] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return data
        }
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try withLock {
            state.writeCount += 1
            state.files[url.standardizedFileURL] = data
            if state.failNextWriteAfterReplacing {
                state.failNextWriteAfterReplacing = false
                throw MetadataStoreTestError.injectedWriteFailure
            }
        }
    }

    func removeItem(at url: URL) throws {
        withLock {
            state.removeCount += 1
            state.files.removeValue(forKey: url.standardizedFileURL)
        }
    }

    func failRead(onCall call: Int) {
        _ = withLock {
            state.failingReadCalls.insert(call)
        }
    }

    func failNextWriteAfterReplacing() {
        withLock {
            state.failNextWriteAfterReplacing = true
        }
    }

    func data(at url: URL) -> Data? {
        withLock {
            state.files[url.standardizedFileURL]
        }
    }

    var readCount: Int {
        withLock { state.readCount }
    }

    var writeCount: Int {
        withLock { state.writeCount }
    }

    private func withLock<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private struct FakeFolderBookmarker: FolderBookmarking {
    enum Behavior: Sendable {
        case unavailable
        case stale(URL)
        case failure
    }

    let behavior: Behavior

    func createBookmark(for folderURL: URL) throws -> Data? {
        switch behavior {
        case .unavailable:
            nil
        case .stale:
            Data([0x42])
        case .failure:
            throw MetadataStoreTestError.injectedBookmarkFailure
        }
    }

    func resolveBookmark(
        _ bookmarkData: Data?
    ) throws -> FolderBookmarkResolution? {
        guard bookmarkData != nil else { return nil }
        switch behavior {
        case .unavailable:
            return nil
        case let .stale(url):
            return FolderBookmarkResolution(
                folderURL: url,
                isStale: true
            )
        case .failure:
            throw MetadataStoreTestError.injectedBookmarkFailure
        }
    }
}

private func temporaryMetadataURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("nested", isDirectory: true)
        .appendingPathComponent("metadata-v1.json")
}

private func encodedMetadata(
    _ document: DatasetMetadataDocumentV1
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(document)
}

private func datasetRecord(
    id: UUID = UUID(),
    path: String = "/tmp/SXM Dataset",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> DatasetRecordV1 {
    try DatasetRecordV1(
        id: id,
        lastKnownPath: path,
        updatedAt: date
    )
}

private func expectStoreError(
    _ operation: () async throws -> Void,
    matching predicate: (DatasetMetadataStoreError) -> Bool
) async {
    do {
        try await operation()
        Issue.record("Expected metadata store operation to fail")
    } catch let error as DatasetMetadataStoreError {
        #expect(predicate(error))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func metadataDefaultURLUsesExactApplicationSupportSuffix() {
    #expect(
        DatasetMetadataStore.defaultFileURL.path.hasSuffix(
            "/SXM Browser/metadata-v1.json"
        )
    )
}

@Test
func loadingMissingMetadataReturnsValidatedEmptyDocumentWithoutWriting()
    async throws
{
    let fileURL = temporaryMetadataURL()
    let store = DatasetMetadataStore(fileURL: fileURL)

    let document = try await store.load()

    #expect(
        document.schemaVersion
            == DatasetMetadataDocumentV1.currentSchemaVersion
    )
    #expect(document.datasets.isEmpty)
    #expect(document.lastOpenedDatasetID == nil)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(await store.publishedDocument == document)
}

@Test
func firstTransactionCreatesParentDirectoryAndRoundTrips() async throws {
    let fileURL = temporaryMetadataURL()
    defer {
        try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
                .deletingLastPathComponent()
        )
    }
    let record = try datasetRecord()
    let store = DatasetMetadataStore(fileURL: fileURL)

    let written = try await store.transaction { document in
        document.upsertDataset(record)
        try document.setLastOpenedDatasetID(record.id)
    }

    var isDirectory: ObjCBool = false
    #expect(
        FileManager.default.fileExists(
            atPath: fileURL.deletingLastPathComponent().path,
            isDirectory: &isDirectory
        )
    )
    #expect(isDirectory.boolValue)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(written.datasets == [record])

    let reopened = DatasetMetadataStore(fileURL: fileURL)
    #expect(try await reopened.load() == written)
}

@Test
func corruptAndUnknownSchemaDocumentsAreExplicitAndNeverOverwritten()
    async throws
{
    let corruptURL = temporaryMetadataURL()
    let unknownURL = temporaryMetadataURL()
    defer {
        try? FileManager.default.removeItem(
            at: corruptURL.deletingLastPathComponent()
                .deletingLastPathComponent()
        )
        try? FileManager.default.removeItem(
            at: unknownURL.deletingLastPathComponent()
                .deletingLastPathComponent()
        )
    }
    try FileManager.default.createDirectory(
        at: corruptURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: unknownURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let corruptData = Data("{not-json".utf8)
    let unknownData = Data(
        #"{"datasets":[],"schemaVersion":99}"#.utf8
    )
    try corruptData.write(to: corruptURL)
    try unknownData.write(to: unknownURL)

    let corruptStore = DatasetMetadataStore(fileURL: corruptURL)
    await expectStoreError({
        _ = try await corruptStore.transaction { _ in }
    }, matching: { error in
        if case .corruptDocument = error { return true }
        return false
    })
    #expect(try Data(contentsOf: corruptURL) == corruptData)

    let unknownStore = DatasetMetadataStore(fileURL: unknownURL)
    await expectStoreError({
        _ = try await unknownStore.transaction { _ in }
    }, matching: { error in
        if case let .unsupportedSchemaVersion(_, version) = error {
            return version == 99
        }
        return false
    })
    #expect(try Data(contentsOf: unknownURL) == unknownData)
}

@Test
func throwingMutationDoesNotAttemptAWrite() async {
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let access = InMemoryMetadataFileAccess()
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )

    do {
        _ = try await store.transaction { _ in
            throw MetadataStoreTestError.expectedMutationFailure
        }
        Issue.record("Expected mutation to throw")
    } catch MetadataStoreTestError.expectedMutationFailure {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(access.writeCount == 0)
    #expect(access.data(at: fileURL) == nil)
    #expect(await store.publishedDocument == nil)
}

@Test
func concurrentActorTransactionsDoNotLoseDatasets() async throws {
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let access = InMemoryMetadataFileAccess()
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
            group.addTask {
                _ = try await store.transaction { document in
                    let record = try datasetRecord(
                        path: "/tmp/Dataset-\(index)",
                        date: Date(
                            timeIntervalSince1970:
                                1_700_000_000 + Double(index)
                        )
                    )
                    document.upsertDataset(record)
                }
            }
        }
        try await group.waitForAll()
    }

    let document = try await store.load()
    #expect(document.datasets.count == 20)
    #expect(
        Set(document.datasets.map(\.lastKnownPath)).count == 20
    )
    #expect(access.writeCount == 20)
}

@Test
func writeFailureRollsBackBytesEvenIfAccessReplacedBeforeThrowing()
    async throws
{
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let originalDocument = try DatasetMetadataDocumentV1(
        datasets: [datasetRecord(path: "/tmp/Original")]
    )
    let originalData = try encodedMetadata(originalDocument)
    let access = InMemoryMetadataFileAccess(
        fileURL: fileURL,
        data: originalData
    )
    access.failNextWriteAfterReplacing()
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )

    await expectStoreError({
        _ = try await store.transaction { document in
            document.upsertDataset(
                try datasetRecord(path: "/tmp/Should-Roll-Back")
            )
        }
    }, matching: { error in
        if case let .writeFailed(_, _, rollbackFailure) = error {
            return rollbackFailure == nil
        }
        return false
    })

    #expect(access.data(at: fileURL) == originalData)
    #expect(access.writeCount == 2)
}

@Test
func readbackFailureRollsBackPreviouslyVerifiedBytes() async throws {
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let originalDocument = try DatasetMetadataDocumentV1(
        datasets: [datasetRecord(path: "/tmp/Original")]
    )
    let originalData = try encodedMetadata(originalDocument)
    let access = InMemoryMetadataFileAccess(
        fileURL: fileURL,
        data: originalData
    )
    access.failRead(onCall: 2)
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )

    await expectStoreError({
        _ = try await store.transaction { document in
            document.upsertDataset(
                try datasetRecord(path: "/tmp/Should-Roll-Back")
            )
        }
    }, matching: { error in
        if case let .verificationFailed(_, _, rollbackFailure) = error {
            return rollbackFailure == nil
        }
        return false
    })

    #expect(access.readCount == 2)
    #expect(access.data(at: fileURL) == originalData)
    #expect(access.writeCount == 2)
}

@Test
func standardizedLookupCreateAndLastOpenedReuseDatasetIdentity()
    async throws
{
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let access = InMemoryMetadataFileAccess()
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )
    let firstURL = URL(fileURLWithPath: "/tmp/Parent/../Dataset/")
    let equivalentURL = URL(fileURLWithPath: "/tmp/Dataset")

    let created = try await store.findOrCreateDataset(
        forFolderURL: firstURL,
        folderBookmark: Data([0x00]),
        updatedAt: Date(timeIntervalSince1970: 10)
    )
    let reopenedWithoutBookmark = try await store.findOrCreateDataset(
        forFolderURL: equivalentURL,
        folderBookmark: nil,
        updatedAt: Date(timeIntervalSince1970: 15)
    )
    let reopenedWithBookmark = try await store.findOrCreateDataset(
        forFolderURL: equivalentURL,
        folderBookmark: Data([0x01]),
        updatedAt: Date(timeIntervalSince1970: 20)
    )

    #expect(reopenedWithoutBookmark.id == created.id)
    #expect(reopenedWithoutBookmark.folderBookmark == Data([0x00]))
    #expect(reopenedWithBookmark.id == created.id)
    #expect(reopenedWithBookmark.lastKnownPath == "/tmp/Dataset")
    #expect(reopenedWithBookmark.folderBookmark == Data([0x01]))
    #expect(try await store.dataset(forFolderURL: firstURL)?.id == created.id)
    #expect(try await store.lastOpenedDataset()?.id == created.id)
    #expect(try await store.load().datasets.count == 1)
}

@Test
func rebindMovedDatasetPreservesIdentityAndReplacesPath() async throws {
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let access = InMemoryMetadataFileAccess()
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )
    let oldURL = URL(fileURLWithPath: "/tmp/Old Dataset")
    let newURL = URL(fileURLWithPath: "/tmp/New Parent/../New Dataset")
    let created = try await store.findOrCreateDataset(
        forFolderURL: oldURL,
        folderBookmark: Data([0x10]),
        updatedAt: Date(timeIntervalSince1970: 10)
    )

    let rebound = try await store.rebindDataset(
        id: created.id,
        toFolderURL: newURL,
        folderBookmark: nil,
        updatedAt: Date(timeIntervalSince1970: 20)
    )

    #expect(rebound.id == created.id)
    #expect(rebound.lastKnownPath == "/tmp/New Dataset")
    #expect(rebound.folderBookmark == Data([0x10]))
    #expect(try await store.dataset(forFolderURL: oldURL) == nil)
    #expect(
        try await store.dataset(forFolderURL: newURL)?.id == created.id
    )
    #expect(try await store.lastOpenedDataset()?.id == created.id)
    #expect(try await store.load().datasets.count == 1)

    let replacedBookmark = try await store.rebindDataset(
        id: created.id,
        toFolderURL: newURL,
        folderBookmark: Data([0x20]),
        updatedAt: Date(timeIntervalSince1970: 30)
    )
    #expect(replacedBookmark.id == created.id)
    #expect(replacedBookmark.folderBookmark == Data([0x20]))
}

@Test
func rebindUnknownDatasetFailsWithoutWriting() async throws {
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let existing = try datasetRecord(path: "/tmp/Existing")
    let originalData = try encodedMetadata(
        try DatasetMetadataDocumentV1(datasets: [existing])
    )
    let access = InMemoryMetadataFileAccess(
        fileURL: fileURL,
        data: originalData
    )
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )
    let missingID = UUID()

    do {
        _ = try await store.rebindDataset(
            id: missingID,
            toFolderURL: URL(fileURLWithPath: "/tmp/Moved")
        )
        Issue.record("Expected missing dataset ID to fail")
    } catch let error as DatasetMetadataValidationError {
        #expect(error == .datasetNotFound(missingID))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(access.writeCount == 0)
    #expect(access.data(at: fileURL) == originalData)
}

@Test
func updateDatasetReturnsTheVerifiedRecordAndPersistsMutation()
    async throws
{
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let record = try datasetRecord(path: "/tmp/Existing")
    let originalData = try encodedMetadata(
        try DatasetMetadataDocumentV1(datasets: [record])
    )
    let access = InMemoryMetadataFileAccess(
        fileURL: fileURL,
        data: originalData
    )
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )
    let tagID = UUID()
    let updateDate = Date(timeIntervalSince1970: 1_800_000_000)

    let updated = try await store.updateDataset(
        id: record.id,
        updatedAt: updateDate
    ) { dataset in
        _ = try dataset.createTag(id: tagID, name: "Verified")
    }

    #expect(updated.id == record.id)
    #expect(updated.updatedAt == updateDate)
    #expect(updated.tags.map(\.id) == [tagID])
    #expect(
        try await store.load().datasets.first(where: {
            $0.id == record.id
        }) == updated
    )
    #expect(access.writeCount == 1)
}

@Test
func updateDatasetUnknownIDAndMutationFailuresNeverWrite() async throws {
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let record = try datasetRecord(path: "/tmp/Existing")
    let originalData = try encodedMetadata(
        try DatasetMetadataDocumentV1(datasets: [record])
    )
    let access = InMemoryMetadataFileAccess(
        fileURL: fileURL,
        data: originalData
    )
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )
    let missingID = UUID()

    do {
        _ = try await store.updateDataset(id: missingID) { _ in }
        Issue.record("Expected missing dataset ID to fail")
    } catch let error as DatasetMetadataValidationError {
        #expect(error == .datasetNotFound(missingID))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    do {
        _ = try await store.updateDataset(id: record.id) { _ in
            throw MetadataStoreTestError.expectedMutationFailure
        }
        Issue.record("Expected mutation to fail")
    } catch MetadataStoreTestError.expectedMutationFailure {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    do {
        _ = try await store.updateDataset(id: record.id) { dataset in
            _ = try dataset.createTag(name: "Duplicate")
            _ = try dataset.createTag(name: " duplicate ")
        }
        Issue.record("Expected validation to fail")
    } catch let error as DatasetMetadataValidationError {
        #expect(error == .duplicateTagName("duplicate"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(access.writeCount == 0)
    #expect(access.data(at: fileURL) == originalData)
}

@Test
func concurrentDatasetUpdatesDoNotLoseMutations() async throws {
    let fileURL = URL(fileURLWithPath: "/virtual/metadata-v1.json")
    let record = try datasetRecord(path: "/tmp/Existing")
    let originalData = try encodedMetadata(
        try DatasetMetadataDocumentV1(datasets: [record])
    )
    let access = InMemoryMetadataFileAccess(
        fileURL: fileURL,
        data: originalData
    )
    let store = DatasetMetadataStore(
        fileURL: fileURL,
        fileAccess: access
    )
    let tagIDs = (0..<20).map { _ in UUID() }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in tagIDs.indices {
            group.addTask {
                _ = try await store.updateDataset(
                    id: record.id,
                    updatedAt: Date(
                        timeIntervalSince1970:
                            1_800_000_000 + Double(index)
                    )
                ) { dataset in
                    _ = try dataset.createTag(
                        id: tagIDs[index],
                        name: "Tag \(index)"
                    )
                }
            }
        }
        try await group.waitForAll()
    }

    let updated = try #require(
        try await store.load().datasets.first(where: {
            $0.id == record.id
        })
    )
    #expect(updated.tags.count == tagIDs.count)
    #expect(Set(updated.tags.map(\.id)) == Set(tagIDs))
    #expect(access.writeCount == tagIDs.count)
}

@Test
func bookmarkAbstractionSupportsNilStaleAndFailure() throws {
    let folderURL = URL(fileURLWithPath: "/tmp/Dataset")
    let unavailable = FakeFolderBookmarker(behavior: .unavailable)
    #expect(try unavailable.createBookmark(for: folderURL) == nil)
    #expect(try unavailable.resolveBookmark(nil) == nil)

    let stale = FakeFolderBookmarker(behavior: .stale(folderURL))
    let bookmark = try stale.createBookmark(for: folderURL)
    #expect(bookmark == Data([0x42]))
    #expect(
        try stale.resolveBookmark(bookmark)
            == FolderBookmarkResolution(
                folderURL: folderURL,
                isStale: true
            )
    )

    let failing = FakeFolderBookmarker(behavior: .failure)
    #expect(throws: MetadataStoreTestError.self) {
        try failing.createBookmark(for: folderURL)
    }
    #expect(throws: MetadataStoreTestError.self) {
        try failing.resolveBookmark(Data([0x01]))
    }
}
