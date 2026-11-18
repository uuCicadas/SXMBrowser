import Foundation

public struct LegacyTagDefaultsEntry: Equatable, Sendable {
    public let key: String
    public let data: Data?

    public init(key: String, data: Data?) {
        self.key = key
        self.data = data
    }
}

public struct LegacyTagDefaultsSnapshot: Equatable, Sendable {
    public let entries: [LegacyTagDefaultsEntry]

    public init(entries: [LegacyTagDefaultsEntry]) {
        self.entries = entries
    }
}

public protocol LegacyTagDefaultsAccess: Sendable {
    func migrationCompleted(forKey key: String) throws -> Bool
    func legacyTagSnapshot(
        keyPrefix: String
    ) throws -> LegacyTagDefaultsSnapshot
    func setMigrationCompleted(_ completed: Bool, forKey key: String) throws
}

public final class UserDefaultsLegacyTagDefaultsAccess:
    LegacyTagDefaultsAccess,
    @unchecked Sendable
{
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func migrationCompleted(forKey key: String) throws -> Bool {
        withLock {
            defaults.object(forKey: key) != nil
                && defaults.bool(forKey: key)
        }
    }

    public func legacyTagSnapshot(
        keyPrefix: String
    ) throws -> LegacyTagDefaultsSnapshot {
        withLock {
            let entries = defaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(keyPrefix) }
                .map { key in
                    LegacyTagDefaultsEntry(
                        key: key,
                        data: defaults.data(forKey: key)
                    )
                }
            return LegacyTagDefaultsSnapshot(entries: entries)
        }
    }

    public func setMigrationCompleted(
        _ completed: Bool,
        forKey key: String
    ) throws {
        try withLock {
            defaults.set(completed, forKey: key)
            guard defaults.object(forKey: key) != nil,
                  defaults.bool(forKey: key) == completed else {
                throw LegacyTagDefaultsError.markerVerificationFailed
            }
        }
    }

    private func withLock<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

public enum LegacyTagDefaultsError: Error, Equatable, Sendable {
    case markerVerificationFailed
}

public enum LegacyTagMigrationIssueStage:
    String,
    Equatable,
    Sendable
{
    case defaultsSnapshot
    case legacyKey
    case legacyPayload
    case tagName
    case memberPath
    case metadataPersistence
    case completionMarker
}

public struct LegacyTagMigrationIssue: Equatable, Sendable {
    public let stage: LegacyTagMigrationIssueStage
    public let key: String?
    public let folderPath: String?
    public let tagName: String?
    public let memberPath: String?
    public let reason: String

    public init(
        stage: LegacyTagMigrationIssueStage,
        key: String? = nil,
        folderPath: String? = nil,
        tagName: String? = nil,
        memberPath: String? = nil,
        reason: String
    ) {
        self.stage = stage
        self.key = key
        self.folderPath = folderPath
        self.tagName = tagName
        self.memberPath = memberPath
        self.reason = reason
    }
}

public enum LegacyTagMigrationStatus: Equatable, Sendable {
    case alreadyCompleted
    case completed
    case incomplete
}

public struct LegacyTagMigrationReport: Equatable, Sendable {
    public let status: LegacyTagMigrationStatus
    public let sourceCount: Int
    public let migratedDatasetCount: Int
    public let migratedTagCount: Int
    public let migratedMembershipCount: Int
    public let issues: [LegacyTagMigrationIssue]

    public init(
        status: LegacyTagMigrationStatus,
        sourceCount: Int,
        migratedDatasetCount: Int,
        migratedTagCount: Int,
        migratedMembershipCount: Int,
        issues: [LegacyTagMigrationIssue]
    ) {
        self.status = status
        self.sourceCount = sourceCount
        self.migratedDatasetCount = migratedDatasetCount
        self.migratedTagCount = migratedTagCount
        self.migratedMembershipCount = migratedMembershipCount
        self.issues = issues
    }
}

public actor LegacyTagMigrator {
    public nonisolated static let legacyKeyPrefix = "native.tagsByFolder."
    public nonisolated static let completionKey =
        "native.metadataV1MigrationCompleted"

    private let metadataStore: DatasetMetadataStore
    private let defaults: any LegacyTagDefaultsAccess
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        metadataStore: DatasetMetadataStore,
        defaults: any LegacyTagDefaultsAccess =
            UserDefaultsLegacyTagDefaultsAccess(),
        now: @escaping @Sendable () -> Date = { .now },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.metadataStore = metadataStore
        self.defaults = defaults
        self.now = now
        self.makeID = makeID
    }

    public func migrateIfNeeded() async -> LegacyTagMigrationReport {
        do {
            if try defaults.migrationCompleted(
                forKey: Self.completionKey
            ) {
                return LegacyTagMigrationReport(
                    status: .alreadyCompleted,
                    sourceCount: 0,
                    migratedDatasetCount: 0,
                    migratedTagCount: 0,
                    migratedMembershipCount: 0,
                    issues: []
                )
            }
        } catch {
            return failureReport(
                stage: .completionMarker,
                reason: migrationErrorMessage(error)
            )
        }

        let snapshot: LegacyTagDefaultsSnapshot
        do {
            snapshot = try defaults.legacyTagSnapshot(
                keyPrefix: Self.legacyKeyPrefix
            )
        } catch {
            return failureReport(
                stage: .defaultsSnapshot,
                reason: migrationErrorMessage(error)
            )
        }

        var issues: [LegacyTagMigrationIssue] = []
        var plans: [LegacyDatasetMigrationPlan] = []
        var planIndexByFolderPath: [String: Int] = [:]

        for entry in snapshot.entries.sorted(by: { $0.key < $1.key }) {
            guard let parsed = parse(entry: entry, issues: &issues) else {
                continue
            }
            if let index = planIndexByFolderPath[parsed.folderPath] {
                plans[index].merge(parsed)
            } else {
                planIndexByFolderPath[parsed.folderPath] = plans.count
                plans.append(parsed)
            }
        }

        let migrationPlans = plans.filter { !$0.tags.isEmpty }
        let counts = migrationCounts(for: migrationPlans)
        do {
            if migrationPlans.isEmpty {
                _ = try await metadataStore.load()
            } else {
                let updateDate = now()
                _ = try await metadataStore.transaction { document in
                    for plan in migrationPlans {
                        try merge(
                            plan,
                            into: &document,
                            updatedAt: updateDate
                        )
                    }
                }
            }
        } catch {
            issues.append(
                LegacyTagMigrationIssue(
                    stage: .metadataPersistence,
                    reason: migrationErrorMessage(error)
                )
            )
            return report(
                status: .incomplete,
                sourceCount: snapshot.entries.count,
                counts: .zero,
                issues: issues
            )
        }

        guard issues.isEmpty else {
            return report(
                status: .incomplete,
                sourceCount: snapshot.entries.count,
                counts: counts,
                issues: issues
            )
        }

        do {
            try defaults.setMigrationCompleted(
                true,
                forKey: Self.completionKey
            )
            guard try defaults.migrationCompleted(
                forKey: Self.completionKey
            ) else {
                throw LegacyTagDefaultsError.markerVerificationFailed
            }
        } catch {
            issues.append(
                LegacyTagMigrationIssue(
                    stage: .completionMarker,
                    reason: migrationErrorMessage(error)
                )
            )
            return report(
                status: .incomplete,
                sourceCount: snapshot.entries.count,
                counts: counts,
                issues: issues
            )
        }

        return report(
            status: .completed,
            sourceCount: snapshot.entries.count,
            counts: counts,
            issues: []
        )
    }

    private func parse(
        entry: LegacyTagDefaultsEntry,
        issues: inout [LegacyTagMigrationIssue]
    ) -> LegacyDatasetMigrationPlan? {
        guard let folderPath = decodeFolderPath(from: entry.key) else {
            issues.append(
                LegacyTagMigrationIssue(
                    stage: .legacyKey,
                    key: entry.key,
                    reason: "The legacy key does not contain a valid "
                        + "Base64-encoded UTF-8 absolute folder path."
                )
            )
            return nil
        }
        guard let data = entry.data else {
            issues.append(
                LegacyTagMigrationIssue(
                    stage: .legacyPayload,
                    key: entry.key,
                    folderPath: folderPath,
                    reason: "The legacy value is not Data."
                )
            )
            return nil
        }

        let payload: LegacyTagStorePayload
        do {
            payload = try JSONDecoder().decode(
                LegacyTagStorePayload.self,
                from: data
            )
        } catch {
            issues.append(
                LegacyTagMigrationIssue(
                    stage: .legacyPayload,
                    key: entry.key,
                    folderPath: folderPath,
                    reason: migrationErrorMessage(error)
                )
            )
            return nil
        }

        var plan = LegacyDatasetMigrationPlan(
            id: makeID(),
            folderPath: folderPath,
            tags: []
        )
        var tagIndexByComparisonKey: [String: Int] = [:]

        for rawName in payload.tagNames {
            addTagName(
                rawName,
                key: entry.key,
                folderPath: folderPath,
                to: &plan,
                tagIndexByComparisonKey: &tagIndexByComparisonKey,
                issues: &issues
            )
        }
        for rawName in payload.taggedFilePathsByTag.keys.sorted() {
            addTagName(
                rawName,
                key: entry.key,
                folderPath: folderPath,
                to: &plan,
                tagIndexByComparisonKey: &tagIndexByComparisonKey,
                issues: &issues
            )
        }

        for rawName in payload.taggedFilePathsByTag.keys.sorted() {
            guard let canonicalName = try? canonicalTagName(rawName),
                  let index = tagIndexByComparisonKey[
                    canonicalTagComparisonKey(canonicalName)
                  ] else {
                continue
            }
            for rawMemberPath in payload.taggedFilePathsByTag[rawName] ?? [] {
                do {
                    let relativePath = try relativeSXMPath(
                        absoluteMemberPath: rawMemberPath,
                        folderPath: folderPath
                    )
                    plan.tags[index].append(relativePath)
                } catch {
                    issues.append(
                        LegacyTagMigrationIssue(
                            stage: .memberPath,
                            key: entry.key,
                            folderPath: folderPath,
                            tagName: canonicalName,
                            memberPath: rawMemberPath,
                            reason: migrationErrorMessage(error)
                        )
                    )
                }
            }
        }
        return plan
    }

    private func addTagName(
        _ rawName: String,
        key: String,
        folderPath: String,
        to plan: inout LegacyDatasetMigrationPlan,
        tagIndexByComparisonKey: inout [String: Int],
        issues: inout [LegacyTagMigrationIssue]
    ) {
        let canonicalName: String
        do {
            canonicalName = try canonicalTagName(rawName)
        } catch {
            issues.append(
                LegacyTagMigrationIssue(
                    stage: .tagName,
                    key: key,
                    folderPath: folderPath,
                    tagName: rawName,
                    reason: migrationErrorMessage(error)
                )
            )
            return
        }
        let comparisonKey = canonicalTagComparisonKey(canonicalName)
        guard tagIndexByComparisonKey[comparisonKey] == nil else {
            return
        }
        tagIndexByComparisonKey[comparisonKey] = plan.tags.count
        plan.tags.append(
            LegacyTagMigrationPlan(
                id: makeID(),
                name: canonicalName,
                sxmPaths: []
            )
        )
    }

    private func decodeFolderPath(from key: String) -> String? {
        guard key.hasPrefix(Self.legacyKeyPrefix) else { return nil }
        let suffix = String(key.dropFirst(Self.legacyKeyPrefix.count))
        guard !suffix.isEmpty,
              let pathData = Data(base64Encoded: suffix),
              let rawPath = String(data: pathData, encoding: .utf8),
              rawPath.hasPrefix("/"),
              !rawPath.contains("\0") else {
            return nil
        }
        let folderURL = URL(
            fileURLWithPath: rawPath.precomposedStringWithCanonicalMapping,
            isDirectory: true
        )
        return try? DatasetMetadataStore.standardizedFolderPath(
            for: folderURL
        )
    }

    private func relativeSXMPath(
        absoluteMemberPath rawPath: String,
        folderPath: String
    ) throws -> DatasetRelativePath {
        guard rawPath.hasPrefix("/"), !rawPath.contains("\0") else {
            throw LegacyTagPathError.memberIsNotAnAbsolutePath
        }
        let memberPath = URL(
            fileURLWithPath: rawPath.precomposedStringWithCanonicalMapping,
            isDirectory: false
        ).standardizedFileURL.path.precomposedStringWithCanonicalMapping
        let canonicalFolderPath = URL(
            fileURLWithPath: folderPath,
            isDirectory: true
        ).standardizedFileURL.path.precomposedStringWithCanonicalMapping
        let folderComponents = URL(
            fileURLWithPath: canonicalFolderPath,
            isDirectory: true
        ).pathComponents
        let memberComponents = URL(
            fileURLWithPath: memberPath,
            isDirectory: false
        ).pathComponents

        guard memberComponents.count > folderComponents.count,
              memberComponents.prefix(folderComponents.count)
                .elementsEqual(folderComponents) else {
            throw LegacyTagPathError.memberIsOutsideDatasetFolder
        }

        let relativePath = memberComponents
            .dropFirst(folderComponents.count)
            .joined(separator: "/")
        return try DatasetRelativePath.sxm(relativePath)
    }

    private func failureReport(
        stage: LegacyTagMigrationIssueStage,
        reason: String
    ) -> LegacyTagMigrationReport {
        LegacyTagMigrationReport(
            status: .incomplete,
            sourceCount: 0,
            migratedDatasetCount: 0,
            migratedTagCount: 0,
            migratedMembershipCount: 0,
            issues: [
                LegacyTagMigrationIssue(stage: stage, reason: reason)
            ]
        )
    }

    private func report(
        status: LegacyTagMigrationStatus,
        sourceCount: Int,
        counts: LegacyTagMigrationCounts,
        issues: [LegacyTagMigrationIssue]
    ) -> LegacyTagMigrationReport {
        LegacyTagMigrationReport(
            status: status,
            sourceCount: sourceCount,
            migratedDatasetCount: counts.datasets,
            migratedTagCount: counts.tags,
            migratedMembershipCount: counts.memberships,
            issues: issues
        )
    }
}

private struct LegacyTagStorePayload: Decodable {
    let tagNames: [String]
    let taggedFilePathsByTag: [String: [String]]

    private enum CodingKeys: String, CodingKey {
        case tagNames
        case taggedFilePathsByTag
    }
}

private enum LegacyTagPathError: Error {
    case memberIsNotAnAbsolutePath
    case memberIsOutsideDatasetFolder
}

private struct LegacyTagMigrationPlan: Sendable {
    let id: UUID
    let name: String
    private(set) var sxmPaths: [DatasetRelativePath]

    mutating func append(_ path: DatasetRelativePath) {
        guard !sxmPaths.contains(path) else { return }
        sxmPaths.append(path)
    }

    mutating func merge(_ other: LegacyTagMigrationPlan) {
        for path in other.sxmPaths {
            append(path)
        }
    }
}

private struct LegacyDatasetMigrationPlan: Sendable {
    let id: UUID
    let folderPath: String
    var tags: [LegacyTagMigrationPlan]

    mutating func merge(_ other: LegacyDatasetMigrationPlan) {
        var indexByName = Dictionary(
            uniqueKeysWithValues: tags.enumerated().map {
                (canonicalTagComparisonKey($0.element.name), $0.offset)
            }
        )
        for tag in other.tags {
            let key = canonicalTagComparisonKey(tag.name)
            if let index = indexByName[key] {
                tags[index].merge(tag)
            } else {
                indexByName[key] = tags.count
                tags.append(tag)
            }
        }
    }
}

private struct LegacyTagMigrationCounts {
    let datasets: Int
    let tags: Int
    let memberships: Int

    static let zero = LegacyTagMigrationCounts(
        datasets: 0,
        tags: 0,
        memberships: 0
    )
}

private func migrationCounts(
    for plans: [LegacyDatasetMigrationPlan]
) -> LegacyTagMigrationCounts {
    LegacyTagMigrationCounts(
        datasets: plans.filter { !$0.tags.isEmpty }.count,
        tags: plans.reduce(0) { $0 + $1.tags.count },
        memberships: plans.reduce(0) { partial, dataset in
            partial + dataset.tags.reduce(0) {
                $0 + $1.sxmPaths.count
            }
        }
    )
}

private func merge(
    _ plan: LegacyDatasetMigrationPlan,
    into document: inout DatasetMetadataDocumentV1,
    updatedAt: Date
) throws {
    guard !plan.tags.isEmpty else { return }
    let matches = document.datasets.filter {
        $0.lastKnownPath == plan.folderPath
    }
    guard matches.count <= 1 else {
        throw LegacyTagMergeError.ambiguousDatasetPath(plan.folderPath)
    }

    var dataset: DatasetRecordV1
    let wasExisting: Bool
    if let existing = matches.first {
        dataset = existing
        wasExisting = true
    } else {
        guard !document.datasets.contains(where: { $0.id == plan.id }) else {
            throw DatasetMetadataValidationError.duplicateDatasetID(plan.id)
        }
        dataset = try DatasetRecordV1(
            id: plan.id,
            lastKnownPath: plan.folderPath,
            updatedAt: updatedAt
        )
        wasExisting = false
    }

    let originalTags = dataset.tags
    for tag in plan.tags {
        _ = try dataset.mergeTag(
            id: tag.id,
            name: tag.name,
            sxmPaths: tag.sxmPaths
        )
    }
    if wasExisting, dataset.tags != originalTags {
        try dataset.markUpdated(at: updatedAt)
    }
    document.upsertDataset(dataset)
}

private enum LegacyTagMergeError: Error {
    case ambiguousDatasetPath(String)
}

private func migrationErrorMessage(_ error: Error) -> String {
    if let localizedError = error as? LocalizedError,
       let description = localizedError.errorDescription {
        return description
    }
    return String(describing: error)
}
