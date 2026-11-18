import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private enum LegacyMigrationTestError: Error {
    case markerWriteFailed
    case snapshotFailed
}

private final class TestLegacyTagDefaults:
    LegacyTagDefaultsAccess,
    @unchecked Sendable
{
    private struct State {
        var entries: [LegacyTagDefaultsEntry]
        var marker = false
        var failMarkerWrite = false
        var failSnapshot = false
        var snapshotCount = 0
        var markerReadCount = 0
        var markerWriteCount = 0
    }

    private let lock = NSLock()
    private var state: State

    init(
        entries: [LegacyTagDefaultsEntry] = [],
        marker: Bool = false
    ) {
        state = State(entries: entries, marker: marker)
    }

    func migrationCompleted(forKey key: String) throws -> Bool {
        withLock {
            state.markerReadCount += 1
            return state.marker
        }
    }

    func legacyTagSnapshot(
        keyPrefix: String
    ) throws -> LegacyTagDefaultsSnapshot {
        try withLock {
            state.snapshotCount += 1
            if state.failSnapshot {
                throw LegacyMigrationTestError.snapshotFailed
            }
            return LegacyTagDefaultsSnapshot(
                entries: state.entries.filter {
                    $0.key.hasPrefix(keyPrefix)
                }
            )
        }
    }

    func setMigrationCompleted(
        _ completed: Bool,
        forKey key: String
    ) throws {
        try withLock {
            state.markerWriteCount += 1
            if state.failMarkerWrite {
                throw LegacyMigrationTestError.markerWriteFailed
            }
            state.marker = completed
        }
    }

    func setMarkerWriteFailure(_ fails: Bool) {
        withLock {
            state.failMarkerWrite = fails
        }
    }

    var marker: Bool {
        withLock { state.marker }
    }

    var snapshotCount: Int {
        withLock { state.snapshotCount }
    }

    var markerWriteCount: Int {
        withLock { state.markerWriteCount }
    }

    var entries: [LegacyTagDefaultsEntry] {
        withLock { state.entries }
    }

    private func withLock<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private struct TestLegacyTagPayload: Encodable {
    let tagNames: [String]
    let taggedFilePathsByTag: [String: [String]]
    let expandedTagNames: [String]
}

private struct MigrationTestStore {
    let rootURL: URL
    let fileURL: URL
    let store: DatasetMetadataStore

    init(existingData: Data? = nil) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = rootURL.appendingPathComponent("metadata-v1.json")
        if let existingData {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try existingData.write(to: fileURL)
        }
        store = DatasetMetadataStore(fileURL: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func legacyKey(folderPath: String) -> String {
    LegacyTagMigrator.legacyKeyPrefix
        + Data(folderPath.utf8).base64EncodedString()
}

private func legacyEntry(
    folderPath: String,
    tagNames: [String],
    members: [String: [String]],
    expandedTagNames: [String] = []
) throws -> LegacyTagDefaultsEntry {
    let payload = TestLegacyTagPayload(
        tagNames: tagNames,
        taggedFilePathsByTag: members,
        expandedTagNames: expandedTagNames
    )
    return LegacyTagDefaultsEntry(
        key: legacyKey(folderPath: folderPath),
        data: try JSONEncoder().encode(payload)
    )
}

private func dataset(
    in document: DatasetMetadataDocumentV1,
    at path: String
) throws -> DatasetRecordV1 {
    try #require(document.datasets.first { $0.lastKnownPath == path })
}

private let migrationDate = Date(timeIntervalSince1970: 1_700_000_100)

@Test
func migratesUnicodeOfflineFilesAndMultipleFoldersInStableOrder()
    async throws
{
    let first = try legacyEntry(
        folderPath: "/研究/样品 A",
        tagNames: ["精选", "空集合"],
        members: [
            "精选": [
                "/研究/样品 A/子目录/未连接.SXM",
                "/研究/样品 A/表面.sxm",
            ],
        ],
        expandedTagNames: ["精选"]
    )
    let second = try legacyEntry(
        folderPath: "/Research/Second",
        tagNames: ["Later"],
        members: [
            "Later": ["/Research/Second/image.sxm"],
        ]
    )
    let defaults = TestLegacyTagDefaults(entries: [second, first])
    let testStore = try MigrationTestStore()
    defer { testStore.remove() }
    let migrator = LegacyTagMigrator(
        metadataStore: testStore.store,
        defaults: defaults,
        now: { migrationDate }
    )

    let report = await migrator.migrateIfNeeded()
    let document = try await testStore.store.load()

    #expect(report.status == .completed)
    #expect(report.sourceCount == 2)
    #expect(report.migratedDatasetCount == 2)
    #expect(report.migratedTagCount == 3)
    #expect(report.migratedMembershipCount == 3)
    #expect(report.issues.isEmpty)
    #expect(defaults.marker)

    let unicodeDataset = try dataset(in: document, at: "/研究/样品 A")
    #expect(unicodeDataset.tags.map(\.name) == ["精选", "空集合"])
    #expect(
        unicodeDataset.tags[0].sxmPaths.map(\.rawValue)
            == ["子目录/未连接.SXM", "表面.sxm"]
    )
    #expect(unicodeDataset.tags[1].sxmPaths.isEmpty)

    let secondDataset = try dataset(
        in: document,
        at: "/Research/Second"
    )
    #expect(secondDataset.tags.map(\.name) == ["Later"])
    #expect(
        secondDataset.tags[0].sxmPaths.map(\.rawValue)
            == ["image.sxm"]
    )
}

@Test
func pathComponentBoundaryAndUnsafeMembersProduceIssuesWithoutCompletion()
    async throws
{
    let validEntry = try legacyEntry(
        folderPath: "/data/run",
        tagNames: ["Mixed"],
        members: [
            "Mixed": [
                "/data/run/good.SXM",
                "/data/run2/prefix-trap.sxm",
                "/data/run/../escape.sxm",
                "/data/run/wrong.dat",
                "relative.sxm",
            ],
        ]
    )
    let badKey = LegacyTagDefaultsEntry(
        key: LegacyTagMigrator.legacyKeyPrefix + "%%%",
        data: Data()
    )
    let badPayload = LegacyTagDefaultsEntry(
        key: legacyKey(folderPath: "/data/bad-json"),
        data: Data("{bad-json".utf8)
    )
    let nonDataPayload = LegacyTagDefaultsEntry(
        key: legacyKey(folderPath: "/data/not-data"),
        data: nil
    )
    let defaults = TestLegacyTagDefaults(
        entries: [nonDataPayload, badPayload, validEntry, badKey]
    )
    let testStore = try MigrationTestStore()
    defer { testStore.remove() }
    let migrator = LegacyTagMigrator(
        metadataStore: testStore.store,
        defaults: defaults,
        now: { migrationDate }
    )

    let report = await migrator.migrateIfNeeded()
    let document = try await testStore.store.load()
    let migrated = try dataset(in: document, at: "/data/run")

    #expect(report.status == .incomplete)
    #expect(!defaults.marker)
    #expect(report.issues.contains { $0.stage == .legacyKey })
    #expect(
        report.issues.filter { $0.stage == .legacyPayload }.count == 2
    )
    #expect(
        report.issues.filter { $0.stage == .memberPath }.count == 4
    )
    #expect(
        migrated.tags[0].sxmPaths.map(\.rawValue) == ["good.SXM"]
    )
}

@Test
func invalidFolderKeyAndInvalidTagNameNeverMarkComplete() async throws {
    let relativeFolderKey = LegacyTagDefaultsEntry(
        key: legacyKey(folderPath: "relative/folder"),
        data: try JSONEncoder().encode(
            TestLegacyTagPayload(
                tagNames: ["Ignored"],
                taggedFilePathsByTag: [:],
                expandedTagNames: []
            )
        )
    )
    let invalidTag = try legacyEntry(
        folderPath: "/data/run",
        tagNames: ["\0"],
        members: ["\0": ["/data/run/image.sxm"]]
    )
    let defaults = TestLegacyTagDefaults(
        entries: [invalidTag, relativeFolderKey]
    )
    let testStore = try MigrationTestStore()
    defer { testStore.remove() }

    let report = await LegacyTagMigrator(
        metadataStore: testStore.store,
        defaults: defaults
    ).migrateIfNeeded()

    #expect(report.status == .incomplete)
    #expect(!defaults.marker)
    #expect(report.issues.contains { $0.stage == .legacyKey })
    #expect(report.issues.contains { $0.stage == .tagName })
}

@Test
func caseInsensitiveMergePreservesIdentityOrderAndAllExistingMetadata()
    async throws
{
    let datasetID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let keepTagID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let existingOnlyID =
        UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    let existingDate = Date(timeIntervalSince1970: 1_600_000_000)
    let bookmark = Data([0x01, 0x02, 0x03])
    let manual = try DatasetManualAssociationV1(
        datPath: "curve.dat",
        sxmPath: "old.sxm"
    )
    let hidden = try DatasetRelativePath.dat("hidden.dat")
    let axis = try SpectrumAxisPreferenceV1(
        sxmPath: "old.sxm",
        kind: .bias,
        schemaFingerprint: "0123456789abcdef",
        selection: AxisSelection(xColumn: "Bias", yColumn: "Current")
    )
    let existing = try DatasetRecordV1(
        id: datasetID,
        folderBookmark: bookmark,
        lastKnownPath: "/data/run",
        tags: [
            DatasetTagV1(
                id: keepTagID,
                name: "Keep",
                sxmPathStrings: ["old.sxm"]
            ),
            DatasetTagV1(
                id: existingOnlyID,
                name: "Existing Only",
                sxmPathStrings: ["metadata-only.sxm"]
            ),
        ],
        manualAssociations: [manual],
        hiddenDATPaths: [hidden],
        spectrumAxisPreferences: [axis],
        updatedAt: existingDate
    )
    let initialDocument = try DatasetMetadataDocumentV1(
        lastOpenedDatasetID: datasetID,
        datasets: [existing]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let initialData = try encoder.encode(initialDocument)
    let testStore = try MigrationTestStore(existingData: initialData)
    defer { testStore.remove() }
    let entry = try legacyEntry(
        folderPath: "/data/run",
        tagNames: [" keep ", "Listed"],
        members: [
            "KEEP": ["/data/run/new.sxm"],
            "Orphan": ["/data/run/orphan.sxm"],
        ]
    )
    let defaults = TestLegacyTagDefaults(entries: [entry])

    let report = await LegacyTagMigrator(
        metadataStore: testStore.store,
        defaults: defaults,
        now: { migrationDate }
    ).migrateIfNeeded()
    let document = try await testStore.store.load()
    let migrated = try dataset(in: document, at: "/data/run")

    #expect(report.status == .completed)
    #expect(document.lastOpenedDatasetID == datasetID)
    #expect(migrated.id == datasetID)
    #expect(migrated.folderBookmark == bookmark)
    #expect(migrated.manualAssociations == [manual])
    #expect(migrated.hiddenDATPaths == [hidden])
    #expect(migrated.spectrumAxisPreferences == [axis])
    #expect(
        migrated.tags.map(\.name)
            == ["Keep", "Existing Only", "Listed", "Orphan"]
    )
    #expect(migrated.tags[0].id == keepTagID)
    #expect(
        migrated.tags[0].sxmPaths.map(\.rawValue)
            == ["old.sxm", "new.sxm"]
    )
    #expect(migrated.tags[1].id == existingOnlyID)
    #expect(migrated.updatedAt == migrationDate)
}

@Test
func markerFailureAfterVerifiedWriteCanRetryWithoutChangingDocument()
    async throws
{
    let entry = try legacyEntry(
        folderPath: "/data/run",
        tagNames: ["Keep"],
        members: ["Keep": ["/data/run/image.sxm"]]
    )
    let defaults = TestLegacyTagDefaults(entries: [entry])
    defaults.setMarkerWriteFailure(true)
    let testStore = try MigrationTestStore()
    defer { testStore.remove() }

    let firstReport = await LegacyTagMigrator(
        metadataStore: testStore.store,
        defaults: defaults,
        now: { Date(timeIntervalSince1970: 100) }
    ).migrateIfNeeded()
    let firstDocument = try await testStore.store.load()

    defaults.setMarkerWriteFailure(false)
    let secondReport = await LegacyTagMigrator(
        metadataStore: testStore.store,
        defaults: defaults,
        now: { Date(timeIntervalSince1970: 200) }
    ).migrateIfNeeded()
    let secondDocument = try await testStore.store.load()

    #expect(firstReport.status == .incomplete)
    #expect(
        firstReport.issues.map(\.stage) == [.completionMarker]
    )
    #expect(secondReport.status == .completed)
    #expect(firstDocument == secondDocument)
    #expect(defaults.marker)
    #expect(defaults.markerWriteCount == 2)
}

@Test
func completedMarkerSkipsLegacySnapshotAndMetadataRead() async throws {
    let defaults = TestLegacyTagDefaults(
        entries: [
            LegacyTagDefaultsEntry(
                key: LegacyTagMigrator.legacyKeyPrefix + "bad",
                data: nil
            ),
        ],
        marker: true
    )
    let corruptData = Data("{corrupt".utf8)
    let testStore = try MigrationTestStore(existingData: corruptData)
    defer { testStore.remove() }

    let report = await LegacyTagMigrator(
        metadataStore: testStore.store,
        defaults: defaults
    ).migrateIfNeeded()

    #expect(report.status == .alreadyCompleted)
    #expect(report.sourceCount == 0)
    #expect(report.issues.isEmpty)
    #expect(defaults.snapshotCount == 0)
    #expect(defaults.markerWriteCount == 0)
    #expect(try Data(contentsOf: testStore.fileURL) == corruptData)
}

@Test
func noLegacyDataVerifiesMetadataThenMarksMigrationComplete() async throws {
    let defaults = TestLegacyTagDefaults()
    let testStore = try MigrationTestStore()
    defer { testStore.remove() }

    let report = await LegacyTagMigrator(
        metadataStore: testStore.store,
        defaults: defaults
    ).migrateIfNeeded()

    #expect(report.status == .completed)
    #expect(report.sourceCount == 0)
    #expect(report.migratedDatasetCount == 0)
    #expect(defaults.marker)
    #expect(!FileManager.default.fileExists(atPath: testStore.fileURL.path))
}

@Test
func corruptMetadataPreventsCompletionAndPreservesBothSources() async throws {
    let entry = try legacyEntry(
        folderPath: "/data/run",
        tagNames: ["Keep"],
        members: ["Keep": ["/data/run/image.sxm"]]
    )
    let defaults = TestLegacyTagDefaults(entries: [entry])
    let corruptData = Data("{corrupt".utf8)
    let testStore = try MigrationTestStore(existingData: corruptData)
    defer { testStore.remove() }

    let report = await LegacyTagMigrator(
        metadataStore: testStore.store,
        defaults: defaults
    ).migrateIfNeeded()

    #expect(report.status == .incomplete)
    #expect(
        report.issues.last?.stage == .metadataPersistence
    )
    #expect(!defaults.marker)
    #expect(defaults.entries == [entry])
    #expect(try Data(contentsOf: testStore.fileURL) == corruptData)
}

@Test
func foundationDefaultsAdapterNeverDeletesLegacyValues() throws {
    let suiteName = "LegacyTagMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = legacyKey(folderPath: "/data/run")
    let legacyData = Data([0x01, 0x02, 0x03])
    defaults.set(legacyData, forKey: key)
    let adapter = UserDefaultsLegacyTagDefaultsAccess(defaults: defaults)

    let snapshot = try adapter.legacyTagSnapshot(
        keyPrefix: LegacyTagMigrator.legacyKeyPrefix
    )
    try adapter.setMigrationCompleted(
        true,
        forKey: LegacyTagMigrator.completionKey
    )

    #expect(snapshot.entries == [
        LegacyTagDefaultsEntry(key: key, data: legacyData),
    ])
    #expect(
        try adapter.migrationCompleted(
            forKey: LegacyTagMigrator.completionKey
        )
    )
    #expect(defaults.data(forKey: key) == legacyData)
}
