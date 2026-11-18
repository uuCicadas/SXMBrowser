import Foundation
import Observation
import SXMBrowserAppCore
import SXMBrowserCore

@Observable
@MainActor
public final class DatasetSessionController {
    private struct SortedFilesCache {
        let inventoryRevision: UInt64
        let sortMode: SortMode
        let sortAscending: Bool
        let result: [SXMMetadata]
    }

    private struct TagFilesCacheKey: Equatable {
        let inventoryRevision: UInt64
        let sessionRevision: UInt64
        let tagsRevision: UInt64
        let sortMode: SortMode
        let sortAscending: Bool
    }

    private struct TagFilesCacheEntry {
        let key: TagFilesCacheKey
        let result: [SXMMetadata]
    }

    private struct SearchScopedFilesCacheKey: Equatable {
        let inventoryRevision: UInt64
        let sessionRevision: UInt64
        let tagsRevision: UInt64
        let sortMode: SortMode
        let sortAscending: Bool
        let sidebarMode: SidebarMode
        let activeTagID: UUID?
    }

    private struct SearchScopedFilesCache {
        let key: SearchScopedFilesCacheKey
        let result: [SXMMetadata]
    }

    private struct VisibleFilesCacheKey: Equatable {
        let scopedKey: SearchScopedFilesCacheKey
        let search: String
        let associationRevision: UInt64?
    }

    private struct VisibleFilesCache {
        let key: VisibleFilesCacheKey
        let result: [SXMMetadata]
    }

    public var folder: URL?
    public var files: [SXMMetadata] = [] {
        didSet {
            inventoryRevision &+= 1
            invalidateDerivedCaches()
        }
    }
    public var spectra: [SpectroscopyFile] = []
    public var scanIssues: [ScanIssue] = []

    public var sidebarMode: SidebarMode = .all
    public var activeTagID: UUID?
    public var filenameSearch = ""
    public var appliedFilenameSearch = ""
    public var sortMode: SortMode = BrowserDefaults.loadSortMode() {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: BrowserDefaults.sortMode)
        }
    }
    public var sortAscending = BrowserDefaults.loadBool(
        BrowserDefaults.sortAscending,
        fallback: false
    ) {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: BrowserDefaults.sortAscending)
        }
    }

    public var datasetLoadState: DatasetLoadState = .idle
    public var status = "Choose a folder with .sxm files."
    public var metadataWarnings = MetadataWarningPresentationState()
    public var noticePresentation = NoticePresentationState()
    public var activeDatasetSession: ActiveDatasetSession? {
        didSet {
            sessionRevision &+= 1
            invalidateDerivedCaches()
        }
    }
    public var tags: [DatasetTagV1] = [] {
        didSet {
            tagsRevision &+= 1
            invalidateDerivedCaches()
        }
    }
    public var expandedTagIDs: Set<UUID> = []
    public var isMetadataMutationInFlight = false
    public var isMetadataTransferInFlight = false
    public var isDeletingFiles = false
    public var metadataImportWorkflow: MetadataImportWorkflow?

    @ObservationIgnored internal var currentSessionID: UUID?
    @ObservationIgnored public private(set) var inventoryRevision: UInt64 = 0
    @ObservationIgnored public private(set) var sessionRevision: UInt64 = 0
    @ObservationIgnored public private(set) var tagsRevision: UInt64 = 0
    @ObservationIgnored public private(set) var visibleFilesVersion: UInt64 = 0

    @ObservationIgnored public private(set) var sortedFilesComputeCount = 0
    @ObservationIgnored public private(set) var visibleFilesComputeCount = 0

    @ObservationIgnored private var cachedSortedFiles: SortedFilesCache?
    @ObservationIgnored private var cachedFilesByTag: [UUID: TagFilesCacheEntry] = [:]
    @ObservationIgnored private var cachedSearchScopedFiles: SearchScopedFilesCache?
    @ObservationIgnored private var cachedVisibleFiles: VisibleFilesCache?

    @ObservationIgnored internal var associatedSpectraProvider: ((SXMMetadata) -> [SpectroscopyFile])?
    @ObservationIgnored internal var associationRevisionProvider: (() -> UInt64)?

    public init() {}

    public var isLoading: Bool {
        datasetLoadState.isLoading
    }

    public var isMetadataBusy: Bool {
        isLoading
            || isMetadataMutationInFlight
            || isMetadataTransferInFlight
            || metadataImportWorkflow != nil
            || isDeletingFiles
    }

    public var canModifyTags: Bool {
        activeDatasetSession != nil && !isMetadataBusy
    }

    public var canAssociateSpectra: Bool {
        activeDatasetSession != nil && !isMetadataBusy
    }

    public var canModifySpectrumVisibility: Bool {
        activeDatasetSession != nil && !isMetadataBusy
    }

    public var canModifySpectrumAxes: Bool {
        activeDatasetSession != nil && !isMetadataBusy
    }

    public var canExportMetadata: Bool {
        activeDatasetSession != nil && !isMetadataBusy
    }

    public var canImportMetadata: Bool {
        activeDatasetSession != nil && !isMetadataBusy
    }

    public var canOpenFolder: Bool {
        guard let workflow = metadataImportWorkflow else {
            return true
        }
        if case .applying = workflow.phase {
            return false
        }
        return true
    }

    public var metadataWarning: String? {
        metadataWarnings.collection.isEmpty
            ? nil
            : metadataWarnings.collection.detailText
    }

    public var shouldPresentMetadataWarning: Bool {
        metadataWarnings.isPresented
    }

    public var metadataWarningSummary: String {
        let collection = metadataWarnings.collection
        guard collection.count > 1 else {
            return collection.messages.first ?? ""
        }
        return "\(collection.count) metadata issues require attention."
    }

    public var canRetryMetadataWarning: Bool {
        folder != nil
            && !isLoading
            && !isMetadataMutationInFlight
            && !isMetadataTransferInFlight
            && !isDeletingFiles
            && canOpenFolder
    }

    public var sortedFiles: [SXMMetadata] {
        let currentFiles = self.files
        let currentSortMode = self.sortMode
        let currentSortAscending = self.sortAscending
        let revision = self.inventoryRevision

        if let cached = cachedSortedFiles,
           cached.inventoryRevision == revision,
           cached.sortMode == currentSortMode,
           cached.sortAscending == currentSortAscending {
            return cached.result
        }

        sortedFilesComputeCount += 1
        let computed = currentFiles.sorted { lhs, rhs in
            FileSortComparator.orderedBefore(
                FileSortValue(
                    identity: lhs.path.standardizedFileURL.path,
                    filename: lhs.filename,
                    modifiedTime: lhs.modifiedTime,
                    recordedTime: lhs.recordedTime
                ),
                FileSortValue(
                    identity: rhs.path.standardizedFileURL.path,
                    filename: rhs.filename,
                    modifiedTime: rhs.modifiedTime,
                    recordedTime: rhs.recordedTime
                ),
                criterion: currentSortMode.sortCriterion,
                ascending: currentSortAscending
            )
        }
        cachedSortedFiles = SortedFilesCache(
            inventoryRevision: revision,
            sortMode: currentSortMode,
            sortAscending: currentSortAscending,
            result: computed
        )
        return computed
    }

    public func files(forTagID tagID: UUID) -> [SXMMetadata] {
        let session = self.activeDatasetSession
        let currentTags = self.tags
        let sorted = self.sortedFiles
        let key = TagFilesCacheKey(
            inventoryRevision: inventoryRevision,
            sessionRevision: sessionRevision,
            tagsRevision: tagsRevision,
            sortMode: sortMode,
            sortAscending: sortAscending
        )

        if let cached = cachedFilesByTag[tagID], cached.key == key {
            return cached.result
        }

        let computed: [SXMMetadata]
        if let session, let tag = currentTags.first(where: { $0.id == tagID }) {
            let taggedPaths = Set(tag.sxmPaths)
            computed = sorted.filter { file in
                guard let path = session.pathIndex.sxmPath(for: file.id) else {
                    return false
                }
                return taggedPaths.contains(path)
            }
        } else {
            computed = []
        }

        cachedFilesByTag[tagID] = TagFilesCacheEntry(key: key, result: computed)
        return computed
    }

    public func visibleFiles(forTagID tagID: UUID) -> [SXMMetadata] {
        filesMatchingSearch(in: files(forTagID: tagID), query: appliedFilenameSearch)
    }

    private var searchScopedFiles: [SXMMetadata] {
        let mode = self.sidebarMode
        let tagID = self.activeTagID
        let currentTags = self.tags
        let sorted = self.sortedFiles

        let key = SearchScopedFilesCacheKey(
            inventoryRevision: inventoryRevision,
            sessionRevision: sessionRevision,
            tagsRevision: tagsRevision,
            sortMode: sortMode,
            sortAscending: sortAscending,
            sidebarMode: mode,
            activeTagID: tagID
        )
        if let cached = cachedSearchScopedFiles, cached.key == key {
            return cached.result
        }

        let computed: [SXMMetadata]
        switch mode {
        case .all:
            computed = sorted
        case .tag:
            if let tagID, currentTags.contains(where: { $0.id == tagID }) {
                computed = files(forTagID: tagID)
            } else {
                computed = []
            }
        }
        cachedSearchScopedFiles = SearchScopedFilesCache(key: key, result: computed)
        return computed
    }

    public var visibleFiles: [SXMMetadata] {
        let scoped = searchScopedFiles
        let search = self.appliedFilenameSearch
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let assocRevision: UInt64? = trimmed.isEmpty ? nil : associationRevisionProvider?()

        let scopedKey = SearchScopedFilesCacheKey(
            inventoryRevision: inventoryRevision,
            sessionRevision: sessionRevision,
            tagsRevision: tagsRevision,
            sortMode: sortMode,
            sortAscending: sortAscending,
            sidebarMode: sidebarMode,
            activeTagID: activeTagID
        )
        let key = VisibleFilesCacheKey(
            scopedKey: scopedKey,
            search: search,
            associationRevision: assocRevision
        )
        if let cached = cachedVisibleFiles, cached.key == key {
            return cached.result
        }

        visibleFilesComputeCount += 1
        let computed = filesMatchingSearch(in: scoped, query: search)
        visibleFilesVersion &+= 1
        cachedVisibleFiles = VisibleFilesCache(key: key, result: computed)
        return computed
    }

    public var searchResultCountText: String {
        let scopedCount = searchScopedFiles.count
        let hasQuery = !appliedFilenameSearch.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        guard hasQuery else {
            return "\(scopedCount)"
        }
        return "\(visibleFiles.count) / \(scopedCount)"
    }

    private func filesMatchingSearch(
        in candidates: [SXMMetadata],
        query: String
    ) -> [SXMMetadata] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidates
        }
        let projection = FilenameSearchProjection(
            query: query,
            candidates: candidates.map { file in
                FilenameSearchCandidate(
                    id: file.id,
                    sxmFilename: file.filename,
                    associatedDATFilenames: (associatedSpectraProvider?(file) ?? []).map(
                        \.filename
                    )
                )
            }
        )
        let matchingIDs = Set(projection.matchingIDs)
        return candidates.filter { matchingIDs.contains($0.id) }
    }

    private func invalidateDerivedCaches() {
        cachedSortedFiles = nil
        cachedFilesByTag.removeAll()
        cachedSearchScopedFiles = nil
        cachedVisibleFiles = nil
    }
}
