import AppKit
import Foundation
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI
import UniformTypeIdentifiers

enum BrowserMode: String, CaseIterable, Identifiable {
    case grid
    case single

    var id: String { rawValue }
    var label: String { self == .grid ? "Grid" : "Single" }
}

enum SortMode: String, CaseIterable, Identifiable {
    case name
    case modifiedTime
    case recordedTime

    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: "File name"
        case .modifiedTime: "Modified time"
        case .recordedTime: "Recorded time"
        }
    }

    var sortCriterion: FileSortCriterion {
        switch self {
        case .name: .name
        case .modifiedTime: .modifiedTime
        case .recordedTime: .recordedTime
        }
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case all
    case tag

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .tag: "Tag"
        }
    }
}

enum GridDisplayItem: Identifiable {
    case sxm(SXMMetadata)
    case spectroscopy(SpectroscopyGroup)

    var id: String {
        switch self {
        case .sxm(let file): "sxm-\(file.id.uuidString)"
        case .spectroscopy(let group): "spectroscopy-\(group.renderID)"
        }
    }
}

enum ScalePreset: String, CaseIterable, Identifiable {
    case full
    case percentile
    case sigma
    case manual

    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: "Full"
        case .percentile: "1-99%"
        case .sigma: "2.5σ"
        case .manual: "Manual"
        }
    }
}

enum MetadataImportWorkflowPhase: Equatable {
    case loading
    case preview
    case applying
    case failed(String)
    case completed(String)
}

struct MetadataImportWorkflow: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let sessionIdentity: DatasetSessionIdentity
    var inventory: DatasetMetadataImportInventory?
    var fileSignature: DatasetInventorySignature?
    var plan: DatasetMetadataImportPlan?
    var phase: MetadataImportWorkflowPhase

    var sourceFilename: String {
        sourceURL.lastPathComponent
    }
}

private enum MetadataTransferWorkflowError: LocalizedError {
    case inventoryUnavailable
    case sxmPathUnavailable(String)
    case datPathUnavailable(String)
    case automaticParentPathUnavailable(String)
    case inventoryFileAttributesUnavailable(String)
    case inventoryFileIsNotRegular(String)
    case inventoryChanged
    case sessionChanged

    var errorDescription: String? {
        switch self {
        case .inventoryUnavailable:
            "The current dataset inventory is unavailable. Reopen the folder and try again."
        case .sxmPathUnavailable(let filename):
            "The SXM file “\(filename)” has no stable dataset-relative path."
        case .datPathUnavailable(let filename):
            "The DAT file “\(filename)” has no stable dataset-relative path."
        case .automaticParentPathUnavailable(let filename):
            "The automatic SXM parent for “\(filename)” has no stable dataset-relative path."
        case .inventoryFileAttributesUnavailable(let filename):
            "Could not read size or modification time for “\(filename)”."
        case .inventoryFileIsNotRegular(let filename):
            "The dataset entry “\(filename)” is not a regular file."
        case .inventoryChanged:
            "Dataset files changed after the preview. Start the import again."
        case .sessionChanged:
            "The open dataset changed. Start the metadata operation again."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private struct ThumbnailTaskEntry {
        let token: UUID
        let task: Task<NSImage?, Never>
    }

    private struct DatasetMetadataPreparation {
        let record: DatasetRecordV1?
        let warnings: MetadataWarningCollection
    }

    private enum MissingActiveTagResolution {
        case firstAvailable
        case preferred(UUID?)
    }

    static let defaultSidebarWidth: CGFloat = 300
    static let defaultInspectorWidth: CGFloat = 320
    static let sidebarWidthRange: ClosedRange<CGFloat> = 220...460
    static let inspectorWidthRange: ClosedRange<CGFloat> = 260...430

    @Published var folder: URL?
    @Published var files: [SXMMetadata] = []
    @Published var spectra: [SpectroscopyFile] = []
    @Published var spectrumGroupsByFileID: [SXMMetadata.ID: [SpectroscopyGroup]] = [:]
    @Published var spectrumParentIDBySpectrumID: [SpectroscopyFile.ID: SXMMetadata.ID] = [:]
    @Published private(set) var hiddenSpectrumIDs:
        Set<SpectroscopyFile.ID> = []
    @Published var sidebarSelectedSpectrumIDs: Set<SpectroscopyFile.ID> = []
    @Published private(set) var manuallyAssignedSXMIDBySpectrumID:
        [SpectroscopyFile.ID: SXMMetadata.ID] = [:]
    @Published private(set) var unassociatedSpectrumIDs:
        Set<SpectroscopyFile.ID> = []
    @Published var areSpectraVisible = true
    @Published private(set) var selection = SelectionState<SXMMetadata.ID>()
    @Published var sidebarMode: SidebarMode = .all
    @Published private(set) var activeTagID: UUID?
    @Published private(set) var filenameSearch = ""
    @Published private(set) var mode: BrowserMode = .grid
    @Published var sortMode: SortMode = AppModel.loadSortMode() {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: Defaults.sortMode) }
    }
    @Published var sortAscending = AppModel.loadBool(Defaults.sortAscending, fallback: false) {
        didSet { UserDefaults.standard.set(sortAscending, forKey: Defaults.sortAscending) }
    }
    @Published var sidebarWidth: CGFloat = AppModel.loadCGFloat(Defaults.sidebarWidth, fallback: AppModel.defaultSidebarWidth, range: AppModel.sidebarWidthRange)
    @Published var inspectorWidth: CGFloat = AppModel.loadCGFloat(Defaults.inspectorWidth, fallback: AppModel.defaultInspectorWidth, range: AppModel.inspectorWidthRange)
    @Published var isSidebarVisible = AppModel.loadBool(Defaults.sidebarVisible, fallback: true) {
        didSet { UserDefaults.standard.set(isSidebarVisible, forKey: Defaults.sidebarVisible) }
    }
    @Published var isInspectorVisible = AppModel.loadBool(Defaults.inspectorVisible, fallback: true) {
        didSet { UserDefaults.standard.set(isInspectorVisible, forKey: Defaults.inspectorVisible) }
    }
    @Published var isLoading = false
    @Published var status = "Choose a folder with .sxm files."
    @Published private(set) var scanIssues: [ScanIssue] = []
    @Published private(set) var metadataWarnings =
        MetadataWarningPresentationState()
    @Published private(set) var activeDatasetSession:
        ActiveDatasetSession?
    @Published private(set) var tags: [DatasetTagV1] = []
    @Published private(set) var expandedTagIDs: Set<UUID> = []
    @Published private(set) var isMetadataMutationInFlight = false
    @Published private(set) var isMetadataTransferInFlight = false
    @Published private(set) var metadataImportWorkflow:
        MetadataImportWorkflow?

    @Published var selectedChannel = ""
    @Published var selectedDirection: ScanDirection = .fwd
    @Published var selectedProcessing: ProcessingMode = .raw
    @Published var selectedPalette: PaletteName = .gwyddionNet
    @Published var invertPalette = false
    @Published private(set) var spectrumAxisState = SpectroscopyAxisState()
    @Published private(set) var spectrumAxisRestoreIssues:
        [SpectrumAxisPreferenceRestoreIssue] = []

    @Published private(set) var renderedFrame:
        CoordinatorRenderedFrame?
    @Published var scalePreset: ScalePreset = .percentile
    @Published var histogramBins: Int = AppModel.loadInt(Defaults.histogramBins, fallback: 256, range: 64...1024) {
        didSet {
            UserDefaults.standard.set(histogramBins, forKey: Defaults.histogramBins)
            if histogramBins != oldValue {
                histogramBinsChanged()
            }
        }
    }
    @Published var gridColumns: Int = AppModel.loadInt(Defaults.gridColumns, fallback: 3, range: 2...8) {
        didSet { UserDefaults.standard.set(gridColumns, forKey: Defaults.gridColumns) }
    }
    @Published var scaleLocked = false
    @Published var scaleMin: Double?
    @Published var scaleMax: Double?
    private let parser = SXMParser()
    private let spectroscopyParser = SpectroscopyParser()
    private let metadataStore: DatasetMetadataStore
    private let legacyTagMigrator: LegacyTagMigrator
    private let folderBookmarker: any FolderBookmarking
    private let renderCoordinator: RenderCoordinator
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailTasks: [String: ThumbnailTaskEntry] = [:]
    private let thumbnailLimiter = AsyncLimiter(limit: 4)
    private var startupTask: Task<Void, Never>?
    private var startupRequestID: UUID?
    private var scanTask: Task<Void, Never>?
    private var scaleRenderTask: Task<Void, Never>?
    private var datasetSessionGate = DatasetSessionGate()
    private var metadataMutationTask: Task<Void, Never>?
    private var metadataMutationID: UUID?
    private var metadataTransferTask: Task<Void, Never>?
    private var metadataTransferID: UUID?
    private var datasetInventoryRevisionID: UUID?
    private var manualTargetPathByDATPath:
        [DatasetRelativePath: DatasetRelativePath] = [:]
    private var manualAssociationProjection:
        ManualSpectrumAssociationProjection?
    private var spectrumDragPayloads: [String: [SpectroscopyFile.ID]] = [:]
    private var securityScopedFolderURL: URL?

    init(
        metadataStore: DatasetMetadataStore = DatasetMetadataStore(),
        folderBookmarker: any FolderBookmarking =
            MacOSFolderBookmarker(),
        renderCoordinator: RenderCoordinator = RenderCoordinator()
    ) {
        self.metadataStore = metadataStore
        legacyTagMigrator = LegacyTagMigrator(metadataStore: metadataStore)
        self.folderBookmarker = folderBookmarker
        self.renderCoordinator = renderCoordinator
        thumbnailCache.countLimit = 180
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024
        renderCoordinator.onEvent = { [weak self] event in
            self?.handleRenderCoordinatorEvent(event)
        }
    }

    var selectedID: SXMMetadata.ID? {
        selection.primaryID
    }

    var selectedIDs: Set<SXMMetadata.ID> {
        selection.selectedIDs
    }

    var selectedImage: NSImage? {
        guard renderedFrame?.request.fileID == selectedID else { return nil }
        return renderedFrame?.image
    }

    var selectedStats: HistogramStats? {
        guard renderedFrame?.request.fileID == selectedID,
              renderedFrame?.stats?.bins == histogramBins else {
            return nil
        }
        return renderedFrame?.stats
    }

    var selectedFile: SXMMetadata? {
        guard let selectedID else { return nil }
        return files.first { $0.id == selectedID }
    }

    var selectedFiles: [SXMMetadata] {
        visibleFiles.filter { selectedIDs.contains($0.id) }
    }

    var selectedCount: Int {
        selectedIDs.count
    }

    var isMetadataBusy: Bool {
        isLoading
            || isMetadataMutationInFlight
            || isMetadataTransferInFlight
            || metadataImportWorkflow != nil
    }

    var canDeleteSelection: Bool {
        !selectedFiles.isEmpty && !isMetadataBusy
    }

    var canModifyTags: Bool {
        activeDatasetSession != nil
            && !isMetadataBusy
    }

    var canAssociateSpectra: Bool {
        activeDatasetSession != nil
            && !isMetadataBusy
    }

    var canModifySpectrumVisibility: Bool {
        activeDatasetSession != nil
            && !isMetadataBusy
    }

    var canModifySpectrumAxes: Bool {
        activeDatasetSession != nil
            && !isMetadataBusy
    }

    var canExportMetadata: Bool {
        activeDatasetSession != nil && !isMetadataBusy
    }

    var canImportMetadata: Bool {
        activeDatasetSession != nil && !isMetadataBusy
    }

    var canOpenFolder: Bool {
        guard let workflow = metadataImportWorkflow else {
            return true
        }
        if case .applying = workflow.phase {
            return false
        }
        return true
    }

    var metadataWarning: String? {
        metadataWarnings.collection.isEmpty
            ? nil
            : metadataWarnings.collection.detailText
    }

    var shouldPresentMetadataWarning: Bool {
        metadataWarnings.isPresented
    }

    var metadataWarningSummary: String {
        let collection = metadataWarnings.collection
        guard collection.count > 1 else {
            return collection.messages.first ?? ""
        }
        return
            "\(collection.count) metadata issues require attention."
    }

    var canRetryMetadataWarning: Bool {
        folder != nil
            && !isLoading
            && !isMetadataMutationInFlight
            && !isMetadataTransferInFlight
            && canOpenFolder
    }

    var presentedSpectrumAxisRestoreIssues:
        [SpectrumAxisPreferenceRestoreIssue] {
        spectrumAxisRestoreIssues.filter { issue in
            switch issue.reason {
            case .experimentUnavailable,
                 .ambiguousExperiment,
                 .incompatibleSchema,
                 .missingColumn,
                 .ambiguousColumn:
                true
            case .missingSXMPath, .groupUnavailable:
                false
            }
        }
    }

    var visibleUnassociatedSpectra: [SpectroscopyFile] {
        let query = filenameSearch
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spectra
            .filter { unassociatedSpectrumIDs.contains($0.id) }
            .filter {
                query.isEmpty
                    || $0.filename.localizedCaseInsensitiveContains(query)
            }
            .sorted {
                $0.filename.localizedStandardCompare($1.filename)
                    == .orderedAscending
            }
    }

    var sortedFiles: [SXMMetadata] {
        files.sorted { lhs, rhs in
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
                criterion: sortMode.sortCriterion,
                ascending: sortAscending
            )
        }
    }

    var visibleFiles: [SXMMetadata] {
        let scopedFiles: [SXMMetadata]
        switch sidebarMode {
        case .all:
            scopedFiles = sortedFiles
        case .tag:
            guard let activeTagID,
                  tags.contains(where: { $0.id == activeTagID }) else {
                return []
            }
            scopedFiles = files(forTagID: activeTagID)
        }
        return filesMatchingSearch(in: scopedFiles)
    }

    var visibleDisplayItems: [GridDisplayItem] {
        visibleFiles.flatMap { file -> [GridDisplayItem] in
            var items: [GridDisplayItem] = [.sxm(file)]
            if areSpectraVisible {
                items.append(contentsOf: spectrumGroups(for: file).map(GridDisplayItem.spectroscopy))
            }
            return items
        }
    }

    var selectedChannelInfo: SXMChannel? {
        selectedFile?.channels.first { $0.name == selectedChannel }
    }

    var selectedPositionText: String {
        let list = visibleFiles
        guard !list.isEmpty, let selected = selectedFile,
              let index = list.firstIndex(where: { $0.id == selected.id }) else {
            return "0 / 0"
        }
        return "\(index + 1) / \(list.count)"
    }

    func files(forTagID tagID: UUID) -> [SXMMetadata] {
        guard let session = activeDatasetSession,
              let tag = tags.first(where: { $0.id == tagID }) else {
            return []
        }
        let taggedPaths = Set(tag.sxmPaths)
        return sortedFiles.filter { file in
            guard let path = session.pathIndex.sxmPath(for: file.id) else {
                return false
            }
            return taggedPaths.contains(path)
        }
    }

    func visibleFiles(forTagID tagID: UUID) -> [SXMMetadata] {
        filesMatchingSearch(in: files(forTagID: tagID))
    }

    func setSidebarMode(_ mode: SidebarMode) {
        if mode == .tag, activeDatasetSession == nil {
            sidebarMode = .all
            activeTagID = nil
            status = metadataUnavailableForTagChangesMessage
            ensureSelectionIsVisible()
            return
        }
        sidebarMode = mode
        if mode == .all {
            activeTagID = nil
            ensureSelectionIsVisible()
        } else if let activeTagID,
                  tags.contains(where: { $0.id == activeTagID }) {
            selectTag(activeTagID)
        } else if let firstTagID = tags.first?.id {
            selectTag(firstTagID)
        } else {
            ensureSelectionIsVisible()
        }
    }

    func setFilenameSearch(_ value: String) {
        guard filenameSearch != value else { return }
        filenameSearch = value
        updateSelection { state, visibleIDs in
            state.reconcile(with: visibleIDs, fallbackToFirst: false)
        }
    }

    func resetLayout() {
        isSidebarVisible = true
        isInspectorVisible = true
        sidebarWidth = Self.defaultSidebarWidth
        inspectorWidth = Self.defaultInspectorWidth
        saveLayoutWidths()
    }

    func saveLayoutWidths() {
        UserDefaults.standard.set(Double(sidebarWidth), forKey: Defaults.sidebarWidth)
        UserDefaults.standard.set(Double(inspectorWidth), forKey: Defaults.inspectorWidth)
    }

    func openStartupFolder() {
        cancelStartupLookup()
        let requestID = UUID()
        startupRequestID = requestID
        startupTask = Task { [weak self] in
            guard let self else { return }
            await restoreStartupFolder(requestID: requestID)
        }
    }

    func chooseFolder() {
        guard canOpenFolder else {
            status =
                "Wait for the metadata import to finish before "
                + "opening another folder."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func exportMetadata() {
        guard canExportMetadata,
              let session = activeDatasetSession else {
            return
        }
        let identity = session.identity

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = metadataExportFilename(
            for: session.folderURL
        )
        panel.prompt = "Export"
        guard panel.runModal() == .OK,
              let destination = panel.url else {
            return
        }
        guard let currentSession = activeDatasetSession,
              currentSession.matches(identity),
              datasetSessionGate.accepts(identity) else {
            return
        }

        let transferID = beginMetadataTransfer()
        let record = currentSession.verifiedRecord
        status = "Exporting metadata..."
        metadataTransferTask = Task { [weak self] in
            guard let self else { return }
            defer {
                finishMetadataTransfer(id: transferID)
            }
            do {
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity
                ) else {
                    return
                }
                let byteCount = try await runDetachedCancellable(
                    priority: .userInitiated
                ) {
                    try Task.checkCancellation()
                    let transfer = try DatasetMetadataTransferV1(
                        exporting: record
                    )
                    let data = try DatasetMetadataTransferCodec().encode(
                        transfer
                    )
                    try Task.checkCancellation()
                    let didAccess = destination
                        .startAccessingSecurityScopedResource()
                    defer {
                        if didAccess {
                            destination
                                .stopAccessingSecurityScopedResource()
                        }
                    }
                    try data.write(to: destination, options: .atomic)
                    return data.count
                }
                try Task.checkCancellation()
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity
                ) else {
                    return
                }
                status =
                    "Exported metadata to "
                    + "\(destination.lastPathComponent) "
                    + "(\(byteCount) bytes)."
            } catch is CancellationError {
                return
            } catch {
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity
                ) else {
                    return
                }
                status =
                    "Metadata export failed: "
                    + error.localizedDescription
            }
        }
    }

    func importMetadata() {
        guard canImportMetadata,
              let session = activeDatasetSession else {
            return
        }
        let identity = session.identity

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK,
              let sourceURL = panel.url else {
            return
        }
        guard let currentSession = activeDatasetSession,
              currentSession.matches(identity),
              datasetSessionGate.accepts(identity) else {
            return
        }

        let workflowID = UUID()
        metadataImportWorkflow = MetadataImportWorkflow(
            id: workflowID,
            sourceURL: sourceURL,
            sessionIdentity: identity,
            inventory: nil,
            fileSignature: nil,
            plan: nil,
            phase: .loading
        )
        let transferID = beginMetadataTransfer()
        let baselineRecord = currentSession.verifiedRecord
        status = "Preparing metadata import..."

        metadataTransferTask = Task { [weak self] in
            guard let self else { return }
            defer {
                finishMetadataTransfer(id: transferID)
            }
            do {
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity,
                    workflowID: workflowID
                ) else {
                    return
                }
                let inventory = try makeMetadataImportInventory(
                    for: currentSession
                )
                try Task.checkCancellation()
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity,
                    workflowID: workflowID
                ) else {
                    return
                }

                let fileSignature = try await runDetachedCancellable(
                    priority: .userInitiated
                ) {
                    try Self.makeDatasetInventorySignature(
                        for: currentSession.folderURL
                    )
                }
                try Task.checkCancellation()
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity,
                    workflowID: workflowID
                ) else {
                    return
                }

                let transfer = try await runDetachedCancellable(
                    priority: .userInitiated
                ) {
                    try Task.checkCancellation()
                    let didAccess = sourceURL
                        .startAccessingSecurityScopedResource()
                    defer {
                        if didAccess {
                            sourceURL
                                .stopAccessingSecurityScopedResource()
                        }
                    }
                    return try DatasetMetadataTransferCodec()
                        .decode(contentsOf: sourceURL)
                }
                try Task.checkCancellation()
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity,
                    workflowID: workflowID
                ) else {
                    return
                }

                let plan = try await runDetachedCancellable(
                    priority: .userInitiated
                ) {
                    try DatasetMetadataImportPlanner().plan(
                        transfer: transfer,
                        into: baselineRecord,
                        inventory: inventory,
                        policy: .safeDefault
                    )
                }
                try Task.checkCancellation()
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity,
                    workflowID: workflowID
                ), var workflow = metadataImportWorkflow else {
                    return
                }
                workflow.inventory = inventory
                workflow.fileSignature = fileSignature
                workflow.plan = plan
                workflow.phase = .preview
                metadataImportWorkflow = workflow
                status = plan.hasChanges
                    ? "Metadata import is ready for review."
                    : "Nothing to import."
            } catch is CancellationError {
                return
            } catch {
                publishMetadataImportFailure(
                    error,
                    transferID: transferID,
                    identity: identity,
                    workflowID: workflowID,
                    prefix: "Metadata import could not be prepared"
                )
            }
        }
    }

    func confirmMetadataImport() {
        guard var workflow = metadataImportWorkflow,
              let baselineInventory = workflow.inventory,
              let baselineFileSignature = workflow.fileSignature,
              let plan = workflow.plan else {
            return
        }
        switch workflow.phase {
        case .preview, .failed:
            break
        case .loading, .applying, .completed:
            return
        }
        guard plan.canApply else {
            workflow.phase = .failed(
                "The preview has unresolved conflicts and cannot be applied."
            )
            metadataImportWorkflow = workflow
            status = "Metadata import has unresolved conflicts."
            return
        }
        guard plan.hasChanges else {
            workflow.phase = .completed("Nothing to import.")
            metadataImportWorkflow = workflow
            status = "Nothing to import."
            return
        }
        guard let session = activeDatasetSession,
              session.matches(workflow.sessionIdentity),
              datasetSessionGate.accepts(workflow.sessionIdentity) else {
            workflow.phase = .failed(
                MetadataTransferWorkflowError.sessionChanged
                    .localizedDescription
            )
            metadataImportWorkflow = workflow
            status = "Metadata import preview is no longer current."
            return
        }

        let workflowID = workflow.id
        let identity = workflow.sessionIdentity
        let datasetID = session.datasetID
        let transferID = beginMetadataTransfer()
        workflow.phase = .applying
        metadataImportWorkflow = workflow
        status = "Applying metadata import..."

        metadataTransferTask = Task { [weak self] in
            guard let self else { return }
            defer {
                finishMetadataTransfer(id: transferID)
            }
            do {
                try Task.checkCancellation()
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity,
                    workflowID: workflowID
                ) else {
                    return
                }
                let currentFileSignature =
                    try await runDetachedCancellable(
                        priority: .userInitiated
                    ) {
                        try Self.makeDatasetInventorySignature(
                            for: session.folderURL
                        )
                    }
                try Task.checkCancellation()
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity,
                    workflowID: workflowID
                ) else {
                    return
                }
                guard currentFileSignature == baselineFileSignature else {
                    throw MetadataTransferWorkflowError.inventoryChanged
                }

                let currentInventory =
                    try makeMetadataImportInventory(for: session)
                guard currentInventory == baselineInventory else {
                    throw MetadataTransferWorkflowError.inventoryChanged
                }
                try Task.checkCancellation()
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity,
                    workflowID: workflowID
                ) else {
                    return
                }

                let updatedAt = Date()
                let verifiedRecord = try await metadataStore.updateDataset(
                    id: datasetID,
                    updatedAt: updatedAt
                ) { record in
                    record = try plan.applying(
                        to: record,
                        inventory: currentInventory,
                        updatedAt: updatedAt
                    )
                }
                try Task.checkCancellation()
                guard metadataTransferAccepts(
                    id: transferID,
                    identity: identity,
                    workflowID: workflowID
                ), let currentSession = activeDatasetSession,
                   currentSession.matches(identity) else {
                    return
                }

                let updatedSession = try ActiveDatasetSession(
                    sessionID: currentSession.sessionID,
                    datasetID: currentSession.datasetID,
                    folderURL: currentSession.folderURL,
                    verifiedRecord: verifiedRecord,
                    pathIndex: currentSession.pathIndex
                )
                guard datasetSessionGate.activate(updatedSession) else {
                    throw MetadataTransferWorkflowError.sessionChanged
                }

                activeDatasetSession = updatedSession
                publishUpdatedTagPresentation(
                    tags: verifiedRecord.tags,
                    expandingTagID: nil,
                    activeTagResolution: .firstAvailable,
                    datasetID: verifiedRecord.id
                )
                restoreManualSpectrumAssociations()
                restoreHiddenSpectrumVisibility()
                rebuildSpectrumGroups()
                ensureSelectionIsVisible()

                let report = metadataImportCompletionMessage(
                    for: plan.summary
                )
                guard var completedWorkflow = metadataImportWorkflow,
                      completedWorkflow.id == workflowID else {
                    return
                }
                completedWorkflow.phase = .completed(report)
                metadataImportWorkflow = completedWorkflow
                status = report
            } catch is CancellationError {
                return
            } catch {
                publishMetadataImportFailure(
                    error,
                    transferID: transferID,
                    identity: identity,
                    workflowID: workflowID,
                    prefix: "Metadata import failed"
                )
            }
        }
    }

    func dismissMetadataImport() {
        guard let workflow = metadataImportWorkflow else { return }
        if case .applying = workflow.phase {
            return
        }
        cancelMetadataTransfer(clearImportWorkflow: true)
    }

    func dismissMetadataWarning() {
        var next = metadataWarnings
        next.dismiss()
        metadataWarnings = next
    }

    func retryMetadataWarning() {
        guard canRetryMetadataWarning,
              let folderURL = folder else {
            return
        }
        let selectedPath = selectedFile?.path
        status = "Retrying metadata setup..."
        openFolder(folderURL, selecting: selectedPath)
    }

    func showMetadataWarningDetails() {
        let messages = metadataWarnings.collection.messages
        guard !messages.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messages.count == 1
            ? "Metadata warning"
            : "\(messages.count) metadata warnings"
        alert.informativeText =
            "Image browsing remains available. Some metadata features "
            + "may be limited until these issues are resolved."
        let details = messages.enumerated().map { index, message in
            "\(index + 1). \(message)"
        }
        let lineCount = details.reduce(0) { count, detail in
            count + max(1, detail.split(separator: "\n").count)
        }
        alert.accessoryView = fileListAccessoryView(
            details.joined(separator: "\n\n"),
            lineCount: lineCount
        )
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showScanIssues() {
        guard !scanIssues.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = scanIssues.count == 1
            ? "1 scan issue"
            : "\(scanIssues.count) scan issues"
        alert.informativeText = "Usable files were loaded. Review the files that were skipped or partially read."
        let details = scanIssues.map { issue in
            var title = "\(issue.file.lastPathComponent) — \(issue.stage.rawValue)"
            if let badLineCount = issue.badLineCount {
                title += " (\(badLineCount) bad line\(badLineCount == 1 ? "" : "s"))"
            }
            return "\(title)\n\(issue.reason)"
        }
        alert.accessoryView = fileListAccessoryView(
            details.joined(separator: "\n\n"),
            lineCount: details.count * 2
        )
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func openDroppedURL(_ url: URL) {
        guard canOpenFolder else {
            status =
                "Wait for the metadata import to finish before "
                + "opening another folder."
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }
        if isDirectory.boolValue {
            openFolder(url)
        } else if ["sxm", "dat"].contains(url.pathExtension.lowercased()) {
            openFolder(url.deletingLastPathComponent(), selecting: url)
        }
    }

    func openFolder(_ url: URL, selecting selectedPath: URL? = nil) {
        guard canOpenFolder else {
            status =
                "Wait for the metadata import to finish before "
                + "opening another folder."
            return
        }
        cancelStartupLookup()
        beginOpeningFolder(url, selecting: selectedPath)
    }

    private func beginOpeningFolder(
        _ url: URL,
        selecting selectedPath: URL? = nil,
        preferredDatasetID: UUID? = nil,
        existingBookmark: Data? = nil,
        initialMetadataWarnings: MetadataWarningCollection =
            MetadataWarningCollection()
    ) {
        scanTask?.cancel()
        cancelMetadataTransfer(clearImportWorkflow: true)
        cancelMetadataMutation()
        invalidateActiveRender(clearFrame: true)
        stopSecurityScopedFolderAccess()

        let sessionID = datasetSessionGate.begin()
        renderCoordinator.beginDataset(revision: sessionID)
        let openedURL = url.standardizedFileURL
        if openedURL.startAccessingSecurityScopedResource() {
            securityScopedFolderURL = openedURL
        }

        folder = openedURL
        UserDefaults.standard.set(
            openedURL.path,
            forKey: Defaults.lastFolder
        )
        isLoading = true
        status = "Scanning folder..."
        resetMetadataWarnings(to: initialMetadataWarnings)
        activeDatasetSession = nil
        tags = []
        activeTagID = nil
        expandedTagIDs = []
        files.removeAll()
        spectra.removeAll()
        scanIssues.removeAll()
        spectrumGroupsByFileID.removeAll()
        spectrumParentIDBySpectrumID.removeAll()
        hiddenSpectrumIDs.removeAll()
        sidebarSelectedSpectrumIDs.removeAll()
        manuallyAssignedSXMIDBySpectrumID.removeAll()
        unassociatedSpectrumIDs.removeAll()
        manualTargetPathByDATPath.removeAll()
        manualAssociationProjection = nil
        spectrumDragPayloads.removeAll()
        selection.clear()
        sidebarMode = .all
        filenameSearch = ""
        spectrumAxisState.clear()
        spectrumAxisRestoreIssues.removeAll()
        datasetInventoryRevisionID = nil
        thumbnailCache.removeAllObjects()
        cancelThumbnailTasks()

        scanTask = Task {
            let metadataPreparation: DatasetMetadataPreparation
            do {
                metadataPreparation = try await prepareDatasetMetadata(
                    for: openedURL,
                    preferredDatasetID: preferredDatasetID,
                    existingBookmark: existingBookmark,
                    initialWarnings: initialMetadataWarnings
                )
            } catch is CancellationError {
                return
            } catch {
                guard datasetSessionGate.acceptsOpeningResult(
                    sessionID: sessionID
                ) else {
                    return
                }
                var warnings = initialMetadataWarnings
                warnings.append(
                    "Metadata preparation failed: "
                        + error.localizedDescription
                )
                metadataPreparation = DatasetMetadataPreparation(
                    record: nil,
                    warnings: warnings
                )
            }
            guard !Task.isCancelled,
                  datasetSessionGate.acceptsOpeningResult(
                    sessionID: sessionID
                  ) else {
                return
            }
            mergeMetadataWarnings(metadataPreparation.warnings)

            do {
                let parser = self.parser
                let spectroscopyParser = self.spectroscopyParser
                let scanned = try await runDetachedCancellable(priority: .userInitiated) {
                    let sxmReport = try parser.scanFolder(openedURL)
                    let spectroscopyReport = try spectroscopyParser.scanFolder(
                        openedURL
                    )
                    return (sxmReport, spectroscopyReport)
                }
                guard !Task.isCancelled,
                      datasetSessionGate.acceptsOpeningResult(
                        sessionID: sessionID
                      ) else {
                    return
                }

                if let record = metadataPreparation.record {
                    do {
                        let pathIndex = try DatasetPathIndex(
                            folderURL: openedURL,
                            sxmFiles: scanned.0.items,
                            spectroscopyFiles: scanned.1.items
                        )
                        let session = try ActiveDatasetSession(
                            sessionID: sessionID,
                            datasetID: record.id,
                            folderURL: openedURL,
                            verifiedRecord: record,
                            pathIndex: pathIndex
                        )
                        guard datasetSessionGate.activate(session) else {
                            return
                        }
                        activeDatasetSession = session
                        publishInitialTagPresentation(for: session)
                    } catch {
                        activeDatasetSession = nil
                        tags = []
                        activeTagID = nil
                        expandedTagIDs = []
                        sidebarMode = .all
                        appendMetadataWarning(
                            "Metadata session is unavailable: "
                                + error.localizedDescription
                        )
                    }
                } else {
                    activeDatasetSession = nil
                    tags = []
                    activeTagID = nil
                    expandedTagIDs = []
                    sidebarMode = .all
                }

                guard datasetSessionGate.acceptsOpeningResult(
                    sessionID: sessionID
                ) else {
                    return
                }
                files = scanned.0.items
                spectra = scanned.1.items
                datasetInventoryRevisionID = UUID()
                scanIssues = scanned.0.issues + scanned.1.issues
                restoreManualSpectrumAssociations()
                restoreHiddenSpectrumVisibility()
                rebuildSpectrumGroups()
                var opensDroppedFileInSingleMode = false
                if let selectedPath,
                   let droppedFile = files.first(where: { $0.path.standardizedFileURL == selectedPath.standardizedFileURL }) {
                    selection.selectOnly(droppedFile.id, in: visibleFiles.map(\.id))
                    opensDroppedFileInSingleMode = true
                } else if let firstID = sortedFiles.first?.id {
                    selection.selectOnly(firstID, in: visibleFiles.map(\.id))
                }
                applyDefaultsFromSelection()
                isLoading = false
                let groupCount = spectrumGroupsByFileID.values.reduce(0) { $0 + $1.count }
                let axisIssueText =
                    presentedSpectrumAxisRestoreIssues.isEmpty
                    ? ""
                    : " Axis preference issues: "
                        + "\(presentedSpectrumAxisRestoreIssues.count)."
                status = "Loaded \(scanned.0.items.count) SXM files and \(scanned.1.items.count) spectra in \(groupCount) plots. Scan issues: \(scanIssues.count).\(axisIssueText)"
                if opensDroppedFileInSingleMode {
                    setMode(.single)
                } else if mode == .single {
                    refreshSelectedImage(resetScale: true)
                }
            } catch {
                guard !Task.isCancelled,
                      datasetSessionGate.acceptsOpeningResult(
                        sessionID: sessionID
                      ) else {
                    return
                }
                isLoading = false
                status = error.localizedDescription
            }
        }
    }

    private func prepareDatasetMetadata(
        for folderURL: URL,
        preferredDatasetID: UUID?,
        existingBookmark: Data?,
        initialWarnings: MetadataWarningCollection
    ) async throws -> DatasetMetadataPreparation {
        var warnings = initialWarnings
        var bookmark = existingBookmark

        let migrationReport = await legacyTagMigrator.migrateIfNeeded()
        if migrationReport.status == .incomplete {
            var migrationMessage =
                "Legacy tag migration is incomplete; the original tag data "
                + "was preserved and migration will retry."
            if !migrationReport.issues.isEmpty {
                migrationMessage += " Issues: \(migrationReport.issues.count)."
            }
            warnings.append(migrationMessage)
        }
        try Task.checkCancellation()

        if bookmark == nil {
            do {
                bookmark = try await createFolderBookmark(for: folderURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warnings.append(
                    "Folder access could not be saved: "
                        + error.localizedDescription
                )
            }
        }
        try Task.checkCancellation()

        do {
            let record: DatasetRecordV1
            if let preferredDatasetID {
                record = try await metadataStore.rebindDataset(
                    id: preferredDatasetID,
                    toFolderURL: folderURL,
                    folderBookmark: bookmark
                )
            } else {
                record = try await metadataStore.findOrCreateDataset(
                    forFolderURL: folderURL,
                    folderBookmark: bookmark
                )
            }
            try Task.checkCancellation()
            return DatasetMetadataPreparation(
                record: record,
                warnings: warnings
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append(
                "Metadata is read-only for this folder: "
                    + error.localizedDescription
            )
            return DatasetMetadataPreparation(
                record: nil,
                warnings: warnings
            )
        }
    }

    private func restoreStartupFolder(requestID: UUID) async {
        var warnings = MetadataWarningCollection()

        do {
            if let record = try await metadataStore.lastOpenedDataset() {
                guard startupRequestIsCurrent(requestID) else { return }

                if let storedBookmark = record.folderBookmark {
                    do {
                        if let resolution = try await resolveFolderBookmark(
                            storedBookmark
                        ) {
                            guard startupRequestIsCurrent(requestID) else {
                                return
                            }
                            if let resolvedFolder =
                                existingSecurityScopedDirectory(
                                    at: resolution.folderURL
                                ) {
                                var bookmark = storedBookmark
                                if resolution.isStale {
                                    do {
                                        if let refreshed =
                                            try await createFolderBookmark(
                                                for: resolvedFolder
                                            ) {
                                            bookmark = refreshed
                                        } else {
                                            warnings.append(
                                                "The stored folder "
                                                    + "bookmark is stale "
                                                    + "and could not be "
                                                    + "refreshed."
                                            )
                                        }
                                    } catch is CancellationError {
                                        return
                                    } catch {
                                        warnings.append(
                                            "The stored folder bookmark "
                                                + "is stale and could not "
                                                + "be refreshed: "
                                                + error.localizedDescription
                                        )
                                    }
                                }
                                guard startupRequestIsCurrent(requestID) else {
                                    return
                                }
                                openStartupFolderCandidate(
                                    resolvedFolder,
                                    requestID: requestID,
                                    datasetID: record.id,
                                    bookmark: bookmark,
                                    warnings: warnings
                                )
                                return
                            }
                            warnings.append(
                                "The stored folder bookmark points to an "
                                    + "unavailable directory."
                            )
                        } else {
                            warnings.append(
                                "The stored folder bookmark could not be "
                                    + "resolved."
                            )
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        warnings.append(
                            "The stored folder bookmark could not be "
                                + "resolved: "
                                + error.localizedDescription
                        )
                    }
                }

                let lastKnownURL = URL(
                    fileURLWithPath: record.lastKnownPath,
                    isDirectory: true
                )
                if let existingFolder = existingDirectory(
                    at: lastKnownURL
                ) {
                    guard startupRequestIsCurrent(requestID) else {
                        return
                    }
                    openStartupFolderCandidate(
                        existingFolder,
                        requestID: requestID,
                        datasetID: record.id,
                        bookmark: nil,
                        warnings: warnings
                    )
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            warnings.append(
                "Saved dataset metadata could not be loaded: "
                    + error.localizedDescription
            )
        }

        guard startupRequestIsCurrent(requestID) else { return }
        if let savedPath = UserDefaults.standard.string(
            forKey: Defaults.lastFolder
        ), let savedFolder = existingDirectory(
            at: URL(
                fileURLWithPath: savedPath,
                isDirectory: true
            )
        ) {
            openStartupFolderCandidate(
                savedFolder,
                requestID: requestID,
                warnings: warnings
            )
            return
        }

        if let exampleFolder = firstAvailableExampleFolder() {
            openStartupFolderCandidate(
                exampleFolder,
                requestID: requestID,
                warnings: warnings
            )
            return
        }

        startupRequestID = nil
        startupTask = nil
        resetMetadataWarnings(to: warnings)
    }

    private func openStartupFolderCandidate(
        _ folderURL: URL,
        requestID: UUID,
        datasetID: UUID? = nil,
        bookmark: Data? = nil,
        warnings: MetadataWarningCollection
    ) {
        guard startupRequestIsCurrent(requestID) else { return }
        startupRequestID = nil
        startupTask = nil
        beginOpeningFolder(
            folderURL,
            preferredDatasetID: datasetID,
            existingBookmark: bookmark,
            initialMetadataWarnings: warnings
        )
    }

    private func startupRequestIsCurrent(_ requestID: UUID) -> Bool {
        !Task.isCancelled && startupRequestID == requestID
    }

    private func cancelStartupLookup() {
        startupTask?.cancel()
        startupTask = nil
        startupRequestID = nil
    }

    private func createFolderBookmark(
        for folderURL: URL
    ) async throws -> Data? {
        let bookmarker = folderBookmarker
        return try await runDetachedCancellable(priority: .utility) {
            try bookmarker.createBookmark(for: folderURL)
        }
    }

    private func resolveFolderBookmark(
        _ bookmark: Data
    ) async throws -> FolderBookmarkResolution? {
        let bookmarker = folderBookmarker
        return try await runDetachedCancellable(priority: .utility) {
            try bookmarker.resolveBookmark(bookmark)
        }
    }

    private func existingDirectory(at url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }
        return url.standardizedFileURL
    }

    private func existingSecurityScopedDirectory(
        at url: URL
    ) -> URL? {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return existingDirectory(at: url)
    }

    private func firstAvailableExampleFolder() -> URL? {
        let appParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let workspaceParent = appParent.deletingLastPathComponent()
        let cwd = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let candidates = [
            workspaceParent.appendingPathComponent("example-graph"),
            workspaceParent.appendingPathComponent("example"),
            appParent.appendingPathComponent("example-graph"),
            appParent.appendingPathComponent("example"),
            cwd.appendingPathComponent("example-graph"),
            cwd.appendingPathComponent("example"),
            cwd.appendingPathComponent("../example-graph")
                .standardizedFileURL,
            cwd.appendingPathComponent("../example").standardizedFileURL,
            cwd.appendingPathComponent("../../example-graph")
                .standardizedFileURL,
            cwd.appendingPathComponent("../../example")
                .standardizedFileURL,
            cwd.appendingPathComponent("../../../example-graph")
                .standardizedFileURL,
            cwd.appendingPathComponent("../../../example")
                .standardizedFileURL,
        ]
        return candidates.lazy.compactMap(existingDirectory(at:)).first
    }

    private func stopSecurityScopedFolderAccess() {
        guard let securityScopedFolderURL else { return }
        securityScopedFolderURL.stopAccessingSecurityScopedResource()
        self.securityScopedFolderURL = nil
    }

    private func resetMetadataWarnings(
        to collection: MetadataWarningCollection =
            MetadataWarningCollection()
    ) {
        metadataWarnings = MetadataWarningPresentationState(
            collection: collection
        )
    }

    private func mergeMetadataWarnings(
        _ collection: MetadataWarningCollection
    ) {
        var next = metadataWarnings
        for message in collection.messages {
            _ = next.append(message)
        }
        metadataWarnings = next
    }

    private func appendMetadataWarning(_ message: String?) {
        var next = metadataWarnings
        guard next.append(message) else { return }
        metadataWarnings = next
    }

    private func metadataExportFilename(for folderURL: URL) -> String {
        let rawName = folderURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = rawName.isEmpty ? "dataset" : rawName
        return "\(folderName)-sxm-metadata.json"
    }

    @discardableResult
    private func beginMetadataTransfer(id: UUID = UUID()) -> UUID {
        metadataTransferTask?.cancel()
        metadataTransferID = id
        isMetadataTransferInFlight = true
        return id
    }

    private func finishMetadataTransfer(id: UUID) {
        guard metadataTransferID == id else { return }
        metadataTransferID = nil
        metadataTransferTask = nil
        isMetadataTransferInFlight = false
    }

    private func cancelMetadataTransfer(
        clearImportWorkflow: Bool
    ) {
        metadataTransferID = nil
        metadataTransferTask?.cancel()
        metadataTransferTask = nil
        isMetadataTransferInFlight = false
        if clearImportWorkflow {
            metadataImportWorkflow = nil
        }
    }

    private func metadataTransferAccepts(
        id: UUID,
        identity: DatasetSessionIdentity,
        workflowID: UUID? = nil
    ) -> Bool {
        guard metadataTransferID == id,
              datasetSessionGate.accepts(identity),
              let session = activeDatasetSession,
              session.matches(identity) else {
            return false
        }
        if let workflowID {
            return metadataImportWorkflow?.id == workflowID
        }
        return true
    }

    private func publishMetadataImportFailure(
        _ error: Error,
        transferID: UUID,
        identity: DatasetSessionIdentity,
        workflowID: UUID,
        prefix: String
    ) {
        guard metadataTransferAccepts(
            id: transferID,
            identity: identity,
            workflowID: workflowID
        ), var workflow = metadataImportWorkflow else {
            return
        }
        let message = "\(prefix): \(error.localizedDescription)"
        workflow.phase = .failed(message)
        metadataImportWorkflow = workflow
        status = message
    }

    private func makeMetadataImportInventory(
        for session: ActiveDatasetSession
    ) throws -> DatasetMetadataImportInventory {
        guard let revisionID = datasetInventoryRevisionID else {
            throw MetadataTransferWorkflowError.inventoryUnavailable
        }

        let sxmPaths = try files.map { file in
            guard let path = session.pathIndex.sxmPath(for: file.id) else {
                throw MetadataTransferWorkflowError
                    .sxmPathUnavailable(file.filename)
            }
            return path
        }
        let sxmByTime = files.sorted { lhs, rhs in
            if lhs.modifiedTime == rhs.modifiedTime {
                return lhs.filename.localizedStandardCompare(rhs.filename)
                    == .orderedAscending
            }
            return lhs.modifiedTime < rhs.modifiedTime
        }
        let sxmByName = files.sorted {
            sxmBasename($0).count > sxmBasename($1).count
        }
        let datFiles = try spectra.map { spectrum in
            guard let path = session.pathIndex.datPath(
                for: spectrum.id
            ) else {
                throw MetadataTransferWorkflowError
                    .datPathUnavailable(spectrum.filename)
            }
            let automaticParent = automaticSpectrumParent(
                for: spectrum,
                sxmFilesByTime: sxmByTime,
                sxmFilesByDescendingBasenameLength: sxmByName
            )
            let automaticParentPath: DatasetRelativePath?
            if let automaticParent {
                guard let path = session.pathIndex.sxmPath(
                    for: automaticParent.id
                ) else {
                    throw MetadataTransferWorkflowError
                        .automaticParentPathUnavailable(
                            spectrum.filename
                        )
                }
                automaticParentPath = path
            } else {
                automaticParentPath = nil
            }

            return DatasetMetadataImportDATFile(
                path: path,
                kind: spectrum.kind,
                experiment: spectrum.experiment,
                experimentIdentity: spectrum.experimentIdentity,
                schemaFingerprint:
                    spectrum.curve.columnSchema.fingerprint,
                columns: spectrum.curve.columns,
                automaticParentSXMPath: automaticParentPath
            )
        }

        return try DatasetMetadataImportInventory(
            revisionID: revisionID,
            sessionID: session.sessionID,
            datasetID: session.datasetID,
            sxmPaths: sxmPaths,
            datFiles: datFiles
        )
    }

    private nonisolated static func makeDatasetInventorySignature(
        for folderURL: URL
    ) throws -> DatasetInventorySignature {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        var stamps: [DatasetInventoryFileStamp] = []
        for url in urls {
            try Task.checkCancellation()
            let fileExtension = url.pathExtension.lowercased(
                with: Locale(identifier: "en_US_POSIX")
            )
            let kind: DatasetFileKind
            switch fileExtension {
            case DatasetFileKind.sxm.fileExtension:
                kind = .sxm
            case DatasetFileKind.dat.fileExtension:
                kind = .dat
            default:
                continue
            }

            let values = try url.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else {
                throw MetadataTransferWorkflowError
                    .inventoryFileIsNotRegular(url.lastPathComponent)
            }
            guard let byteCount = values.fileSize,
                  byteCount >= 0,
                  let modifiedAt = values.contentModificationDate else {
                throw MetadataTransferWorkflowError
                    .inventoryFileAttributesUnavailable(
                        url.lastPathComponent
                    )
            }
            let path = try DatasetRelativePath(
                url.lastPathComponent,
                requiring: kind
            )
            stamps.append(
                try DatasetInventoryFileStamp(
                    path: path,
                    byteCount: UInt64(byteCount),
                    modifiedAt: modifiedAt
                )
            )
        }
        return try DatasetInventorySignature(files: stamps)
    }

    private func metadataImportCompletionMessage(
        for summary: DatasetMetadataImportSummary
    ) -> String {
        var message =
            "Imported \(summary.actionCount) metadata change"
            + (summary.actionCount == 1 ? "" : "s")
            + "."
        if summary.skippedItemCount > 0 {
            message +=
                " Skipped \(summary.skippedItemCount) unavailable item"
                + (summary.skippedItemCount == 1 ? "." : "s.")
        }
        if summary.resolvedConflictCount > 0 {
            message +=
                " Kept existing values for "
                + "\(summary.resolvedConflictCount) conflict"
                + (summary.resolvedConflictCount == 1 ? "." : "s.")
        }
        return message
    }

    func select(_ file: SXMMetadata, tagContext: UUID? = nil) {
        activateTagContextIfNeeded(tagContext)
        updateSelection { state, visibleIDs in
            state.selectOnly(file.id, in: visibleIDs)
        }
    }

    func select(
        _ file: SXMMetadata,
        modifiers: NSEvent.ModifierFlags,
        tagContext: UUID? = nil
    ) {
        activateTagContextIfNeeded(tagContext)
        let relevantModifiers = modifiers.intersection([.command, .shift])
        if relevantModifiers.contains(.shift) {
            updateSelection { state, visibleIDs in
                state.selectRange(to: file.id, in: visibleIDs)
            }
        } else if relevantModifiers.contains(.command) {
            updateSelection { state, visibleIDs in
                state.toggle(file.id, in: visibleIDs)
            }
        } else {
            select(file, tagContext: tagContext)
        }
    }

    func selectAll() {
        updateSelection { state, visibleIDs in
            state.selectAll(in: visibleIDs)
        }
        status = "Selected \(selectedIDs.count) files."
    }

    func jumpToFilenameSearch() {
        let query = filenameSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let list = visibleFiles
        guard !list.isEmpty else { return }
        let currentIndex = selectedFile.flatMap { selected in
            list.firstIndex { $0.id == selected.id }
        } ?? -1
        let orderedIndices = Array((currentIndex + 1)..<list.count) + Array(0...max(currentIndex, 0))

        guard let matchIndex = orderedIndices.first(where: { index in
            list[index].filename.localizedCaseInsensitiveContains(query)
        }) else {
            status = "No file matching \"\(query)\"."
            return
        }

        select(list[matchIndex])
        status = "Selected \(list[matchIndex].filename)"
    }

    func canStepSelection(by delta: Int) -> Bool {
        selection.canStep(by: delta, in: visibleFiles.map(\.id))
    }

    func stepSelection(_ delta: Int) {
        let list = visibleFiles
        guard canStepSelection(by: delta) else { return }
        updateSelection { state, visibleIDs in
            state.step(by: delta, in: visibleIDs)
        }
        if let selectedID,
           let selected = list.first(where: { $0.id == selectedID }) {
            status = selected.filename
        }
    }

    func moveSelectionForArrow(_ direction: MoveCommandDirection) {
        switch mode {
        case .single:
            if direction == .left {
                stepSelection(-1)
            } else if direction == .right {
                stepSelection(1)
            }
        case .grid:
            switch direction {
            case .left:
                stepSelection(-1)
            case .right:
                stepSelection(1)
            case .up:
                stepSelection(-gridColumns)
            case .down:
                stepSelection(gridColumns)
            default:
                break
            }
        }
    }

    func deleteSelectedFiles() {
        let plan = FileDeletionPlan(
            visibleIDs: visibleFiles.map(\.id),
            selectedIDs: selectedIDs
        )
        let fileByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        deleteFiles(plan.targetIDs.compactMap { fileByID[$0] })
    }

    func deleteFilesForContext(
        containing file: SXMMetadata,
        tagContext: UUID? = nil
    ) {
        deleteFiles(contextFiles(containing: file, tagContext: tagContext))
    }

    func contextFiles(
        containing file: SXMMetadata,
        tagContext: UUID? = nil
    ) -> [SXMMetadata] {
        let scopedFiles: [SXMMetadata]
        if let tagContext {
            guard tags.contains(where: { $0.id == tagContext }),
                  activeDatasetSession != nil else {
                return []
            }
            scopedFiles = visibleFiles(forTagID: tagContext)
            guard scopedFiles.contains(where: { $0.id == file.id }) else {
                return []
            }
        } else {
            scopedFiles = visibleFiles
        }
        return selectedIDs.contains(file.id)
            ? scopedFiles.filter { selectedIDs.contains($0.id) }
            : [file]
    }

    func revealInFinderForContext(
        containing file: SXMMetadata,
        tagContext: UUID? = nil
    ) {
        let urls = contextFiles(containing: file, tagContext: tagContext).map(\.path)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openFilesForContext(
        containing file: SXMMetadata,
        tagContext: UUID? = nil
    ) {
        for target in contextFiles(containing: file, tagContext: tagContext) {
            NSWorkspace.shared.open(target.path)
        }
    }

    func addTag(
        _ tagID: UUID,
        toContextContaining file: SXMMetadata,
        tagContext: UUID? = nil
    ) {
        guard activeDatasetSession != nil else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        let targetFiles = contextFiles(
            containing: file,
            tagContext: tagContext
        )
        guard !targetFiles.isEmpty else {
            status = "The tag context is no longer available."
            return
        }
        addTag(
            tagID,
            to: targetFiles
        )
    }

    func removableTagsForContext(
        containing file: SXMMetadata,
        tagContext: UUID? = nil
    ) -> [DatasetTagV1] {
        guard let session = activeDatasetSession else { return [] }
        let targetPaths = Set(
            contextFiles(containing: file, tagContext: tagContext)
                .compactMap { session.pathIndex.sxmPath(for: $0.id) }
        )
        guard !targetPaths.isEmpty else { return [] }
        return tags.filter { tag in
            !Set(tag.sxmPaths).intersection(targetPaths).isEmpty
        }
    }

    func removeTag(
        _ tagID: UUID,
        fromContextContaining file: SXMMetadata,
        tagContext: UUID? = nil
    ) {
        guard activeDatasetSession != nil else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        let targetFiles = contextFiles(
            containing: file,
            tagContext: tagContext
        )
        guard !targetFiles.isEmpty else {
            status = "The tag context is no longer available."
            return
        }
        removeTag(
            tagID,
            from: targetFiles
        )
    }

    func promptForNewTag(
        toContextContaining file: SXMMetadata? = nil,
        tagContext: UUID? = nil
    ) {
        guard canModifyTags else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        let alert = NSAlert()
        alert.messageText = file == nil ? "Create Tag" : "Create and Add Tag"
        alert.informativeText = "Enter a tag name."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Tag name"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = normalizedTagName(field.stringValue)
        guard !name.isEmpty else { return }

        if let file {
            let targetFiles = contextFiles(
                containing: file,
                tagContext: tagContext
            )
            guard !targetFiles.isEmpty else {
                status = "The tag context is no longer available."
                return
            }
            createTag(named: name, adding: targetFiles)
        } else {
            createTag(named: name, adding: [])
        }
    }

    func promptToRenameTag(_ tagID: UUID) {
        guard canModifyTags,
              let tag = tags.first(where: { $0.id == tagID }) else {
            status = metadataUnavailableForTagChangesMessage
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename Tag"
        alert.informativeText = "Enter a new name for \(tag.name)."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 240, height: 24)
        )
        field.stringValue = tag.name
        field.placeholderString = "Tag name"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameTag(id: tagID, to: field.stringValue)
    }

    func renameTag(id tagID: UUID, to name: String) {
        guard activeDatasetSession != nil,
              tags.contains(where: { $0.id == tagID }) else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        performTagMutation(successMessage: "Tag renamed.") { record in
            try record.renameTag(id: tagID, to: name)
        }
    }

    func deleteTag(id tagID: UUID) {
        guard canModifyTags,
              let tag = tags.first(where: { $0.id == tagID }) else {
            status = metadataUnavailableForTagChangesMessage
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete Tag “\(tag.name)”?"
        alert.informativeText =
            "This only deletes the tag. No files will be deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard canModifyTags,
              let currentTag = tags.first(where: {
                  $0.id == tagID
              }) else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        let activeTagResolution: MissingActiveTagResolution =
            activeTagID == tagID
            ? .preferred(
                TagPresentationProjection.successorTagID(
                    afterDeleting: tagID,
                    from: tags
                )
            )
            : .firstAvailable
        performTagMutation(
            activeTagResolution: activeTagResolution,
            successMessage: "Deleted tag \(currentTag.name)."
        ) { record in
            guard record.deleteTag(id: tagID) != nil else {
                throw DatasetMetadataValidationError.tagNotFound(tagID)
            }
        }
    }

    func sortTagsByName() {
        guard activeDatasetSession != nil else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        guard !isMetadataBusy else {
            status = "Wait for the current metadata operation to finish."
            return
        }
        performTagMutation(successMessage: "Sorted tags A–Z.") { record in
            record.sortTagsByName()
        }
    }

    func moveTag(sourceID: UUID, toTargetID targetID: UUID) {
        guard activeDatasetSession != nil else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        guard !isMetadataBusy else {
            status = "Wait for the current metadata operation to finish."
            return
        }

        let currentPlan: TagReorderPlan
        do {
            currentPlan = try TagReorderPlan.make(
                sourceID: sourceID,
                targetID: targetID,
                tags: tags
            )
        } catch {
            status = error.localizedDescription
            return
        }
        guard currentPlan != .noChange else {
            status = "Tag order unchanged."
            return
        }

        performTagMutation(successMessage: "Reordered tags.") { record in
            switch try TagReorderPlan.make(
                sourceID: sourceID,
                targetID: targetID,
                tags: record.tags
            ) {
            case .noChange:
                return
            case .move(let verifiedSourceID, let destinationIndex):
                try record.moveTag(
                    id: verifiedSourceID,
                    to: destinationIndex
                )
            }
        }
    }

    func moveTag(
        fromDropData data: Data,
        typeIdentifier: String,
        toTargetID targetID: UUID
    ) {
        do {
            let payload = try TagDropPayload(
                data: data,
                typeIdentifier: typeIdentifier
            )
            moveTag(
                sourceID: payload.tagID,
                toTargetID: targetID
            )
        } catch {
            status = error.localizedDescription
        }
    }

    func toggleTagExpansion(_ tagID: UUID) {
        guard let session = activeDatasetSession,
              tags.contains(where: { $0.id == tagID }) else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        if expandedTagIDs.contains(tagID) {
            expandedTagIDs.remove(tagID)
        } else {
            expandedTagIDs.insert(tagID)
        }
        saveExpandedTagIDs(for: session.datasetID)
    }

    func selectTag(_ tagID: UUID) {
        guard let tag = tags.first(where: { $0.id == tagID }),
              let session = activeDatasetSession else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        sidebarMode = .tag
        activeTagID = tagID
        expandedTagIDs.insert(tagID)
        saveExpandedTagIDs(for: session.datasetID)

        let tagFiles = files(forTagID: tagID)
        updateSelection { state, visibleIDs in
            state.reconcile(with: visibleIDs, fallbackToFirst: true)
        }
        status = "Showing \(tagFiles.count) files in \(tag.name)."
    }

    private func deleteFiles(_ targets: [SXMMetadata]) {
        guard !targets.isEmpty else { return }
        guard !isMetadataBusy else {
            status = "Wait for the current metadata operation before deleting files."
            return
        }

        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Delete this SXM file?" : "Delete \(targets.count) SXM files?"
        alert.informativeText = "The original file\(targets.count == 1 ? "" : "s") will be moved to the system Trash."
        alert.alertStyle = .warning
        alert.accessoryView = fileListAccessoryView(
            targets.map(\.filename).joined(separator: "\n"),
            lineCount: targets.count
        )
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var trashedIDs: Set<SXMMetadata.ID> = []
        var trashedNames: [String] = []
        var failedNames: [String] = []
        for file in targets {
            do {
                try FileManager.default.trashItem(at: file.path, resultingItemURL: nil)
                trashedIDs.insert(file.id)
                trashedNames.append(file.filename)
                removeCachedData(for: file.path)
            } catch {
                failedNames.append(file.filename)
            }
        }

        guard !trashedIDs.isEmpty else {
            status = failedNames.isEmpty ? "No files deleted." : "Could not delete \(failedNames.count) files."
            if !failedNames.isEmpty {
                showDeletionResult(trashedNames: [], failedNames: failedNames)
            }
            return
        }

        let oldVisibleIDs = visibleFiles.map(\.id)
        files.removeAll { trashedIDs.contains($0.id) }
        datasetInventoryRevisionID = UUID()
        removeTags(forDeletedFiles: targets.filter { trashedIDs.contains($0.id) })
        restoreManualSpectrumAssociations()
        rebuildSpectrumGroups()
        var updatedSelection = selection
        updatedSelection.reconcileAfterRemoval(
            removedIDs: trashedIDs,
            oldVisibleIDs: oldVisibleIDs,
            newVisibleIDs: visibleFiles.map(\.id)
        )
        commitSelection(updatedSelection, resetScale: true)
        if selectedID == nil {
            clearSelectedRender()
        }

        let deletedText = trashedIDs.count == 1 ? "Moved 1 file to Trash." : "Moved \(trashedIDs.count) files to Trash."
        status = failedNames.isEmpty ? deletedText : "\(deletedText) Could not delete \(failedNames.count)."
        if !failedNames.isEmpty {
            showDeletionResult(trashedNames: trashedNames, failedNames: failedNames)
        }
    }

    private func fileListAccessoryView(
        _ text: String,
        lineCount: Int
    ) -> NSView {
        let width: CGFloat = 380
        let height = min(220, max(64, CGFloat(lineCount) * 18 + 18))
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    private func showDeletionResult(
        trashedNames: [String],
        failedNames: [String]
    ) {
        let resultAlert = NSAlert()
        resultAlert.alertStyle = failedNames.isEmpty ? .informational : .warning
        resultAlert.messageText = trashedNames.isEmpty
            ? "Files could not be deleted"
            : "Some files could not be deleted"
        resultAlert.informativeText = "Successful and failed files are listed separately."

        var sections: [String] = []
        if !trashedNames.isEmpty {
            sections.append(
                "Moved to Trash (\(trashedNames.count))\n"
                    + trashedNames.joined(separator: "\n")
            )
        }
        if !failedNames.isEmpty {
            sections.append(
                "Could not delete (\(failedNames.count))\n"
                    + failedNames.joined(separator: "\n")
            )
        }
        let lineCount = trashedNames.count + failedNames.count + sections.count
        resultAlert.accessoryView = fileListAccessoryView(
            sections.joined(separator: "\n\n"),
            lineCount: lineCount
        )
        resultAlert.addButton(withTitle: "OK")
        resultAlert.runModal()
    }

    func applyDefaultsFromSelection() {
        guard let file = selectedFile else { return }
        selectedChannel = file.defaultChannel ?? file.channels.first?.name ?? ""
        let channel = file.channels.first { $0.name == selectedChannel } ?? file.channels.first
        selectedDirection = channel?.directions.first ?? .fwd
        selectedPalette = defaultPalette(for: selectedChannel)
        selectedProcessing = defaultProcessing(for: selectedChannel)
        invertPalette = false
        scalePreset = .percentile
        scaleLocked = false
        scaleMin = nil
        scaleMax = nil
        renderCoordinator.discardProcessedData()
    }

    func setMode(_ newMode: BrowserMode) {
        if mode == newMode {
            if newMode == .single, selectedImage == nil {
                refreshSelectedImage(resetScale: false)
            }
            return
        }
        mode = newMode
        switch newMode {
        case .single:
            refreshSelectedImage(resetScale: false)
        case .grid:
            scaleRenderTask?.cancel()
            renderCoordinator.invalidate(clearFrame: false)
        }
    }

    func toggleSpectraVisibility() {
        areSpectraVisible.toggle()
        status = areSpectraVisible ? "Spectra visible." : "Spectra hidden."
    }

    func spectrumGroups(for file: SXMMetadata) -> [SpectroscopyGroup] {
        spectrumGroupsByFileID[file.id] ?? []
    }

    func spectrumXAxis(for group: SpectroscopyGroup) -> String {
        spectrumAxisState.selection(forGroupID: group.id)?.xColumn
            ?? group.canonicalColumn(matching: group.xLabel)
            ?? group.availableColumns.first
            ?? ""
    }

    func spectrumYAxis(for group: SpectroscopyGroup) -> String {
        spectrumAxisState.selection(forGroupID: group.id)?.yColumn
            ?? group.canonicalColumn(matching: group.yLabel)
            ?? group.availableColumns.dropFirst().first
            ?? group.availableColumns.first
            ?? ""
    }

    func setSpectrumXAxis(_ column: String, for group: SpectroscopyGroup) {
        setSpectrumAxis(.x, to: column, for: group)
    }

    func setSpectrumYAxis(_ column: String, for group: SpectroscopyGroup) {
        setSpectrumAxis(.y, to: column, for: group)
    }

    private func setSpectrumAxis(
        _ axis: SpectrumAxis,
        to column: String,
        for group: SpectroscopyGroup
    ) {
        guard let session = activeDatasetSession else {
            status = metadataUnavailableForSpectrumAxesMessage
            return
        }
        guard !isLoading else {
            status = "Wait for the folder scan to finish."
            return
        }
        guard !isMetadataBusy else {
            status = "Wait for the current metadata operation to finish."
            return
        }
        guard let currentGroup = spectrumGroupsByFileID.values
            .flatMap({ $0 })
            .first(where: { $0.id == group.id }) else {
            status = "The spectroscopy group is no longer available."
            return
        }

        let currentSelection = AxisSelection(
            xColumn: spectrumXAxis(for: currentGroup),
            yColumn: spectrumYAxis(for: currentGroup)
        )
        let currentColumn = axis == .x
            ? currentSelection.xColumn
            : currentSelection.yColumn
        guard column != currentColumn else { return }

        let plan: SpectrumAxisPreferenceUpdatePlan
        do {
            plan = try SpectrumAxisPreferenceUpdatePlan(
                group: SpectrumAxisRuntimeGroup(currentGroup),
                changing: axis,
                to: column,
                currentSelection: currentSelection,
                pathIndex: session.pathIndex
            )
        } catch {
            status = "Spectrum axes could not be updated: "
                + error.localizedDescription
            return
        }

        let updatedAt = Date()
        let successMessage =
            "Using \(plan.selection.xColumn) vs "
            + "\(plan.selection.yColumn) for \(currentGroup.title)."
        performMetadataMutation(
            unavailableMessage: metadataUnavailableForSpectrumAxesMessage,
            successMessage: successMessage,
            failurePrefix: "Spectrum axes could not be updated",
            mutation: { record in
                let updated = try plan.applying(
                    to: record.spectrumAxisPreferences
                )
                try record.replaceSpectrumAxisPreferences(
                    with: updated,
                    updatedAt: updatedAt
                )
            },
            onVerified: { [weak self] _ in
                self?.restoreSpectrumAxisPreferences()
            }
        )
    }

    func spectra(for file: SXMMetadata) -> [SpectroscopyFile] {
        spectra
            .filter { spectrumParentIDBySpectrumID[$0.id] == file.id }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    func spectraForMarkers(on file: SXMMetadata) -> [SpectroscopyFile] {
        spectrumGroups(for: file).flatMap(\.spectra)
    }

    func isSpectrumVisible(_ spectrum: SpectroscopyFile) -> Bool {
        !hiddenSpectrumIDs.contains(spectrum.id)
    }

    func setSpectrum(_ spectrum: SpectroscopyFile, visible: Bool) {
        guard let session = activeDatasetSession else {
            status = metadataUnavailableForSpectrumVisibilityMessage
            return
        }
        guard !isLoading else {
            status = "Wait for the folder scan to finish."
            return
        }
        guard !isMetadataBusy else {
            status = "Wait for the current metadata operation to finish."
            return
        }
        guard spectra.contains(where: { $0.id == spectrum.id }) else {
            status = "The spectrum is no longer available."
            return
        }
        guard visible != isSpectrumVisible(spectrum) else { return }

        let plan: HiddenSpectrumUpdatePlan
        do {
            plan = try HiddenSpectrumUpdatePlan(
                datID: spectrum.id,
                visible: visible,
                pathIndex: session.pathIndex
            )
        } catch {
            status = "Spectrum visibility could not be updated: "
                + error.localizedDescription
            return
        }

        let parentID = spectrumParentIDBySpectrumID[spectrum.id]
        let updatedAt = Date()
        performMetadataMutation(
            unavailableMessage:
                metadataUnavailableForSpectrumVisibilityMessage,
            successMessage: visible
                ? "Showing \(spectrum.filename)."
                : "Hidden \(spectrum.filename).",
            failurePrefix: "Spectrum visibility could not be updated",
            mutation: { record in
                let updated = try plan.applying(
                    to: record.hiddenDATPaths
                )
                try record.replaceHiddenDATPaths(
                    with: updated,
                    updatedAt: updatedAt
                )
            },
            onVerified: { [weak self] _ in
                guard let self else { return }
                restoreHiddenSpectrumVisibility()
                if let parentID {
                    rebuildSpectrumGroups(for: [parentID])
                } else {
                    rebuildSpectrumGroups()
                }
            }
        )
    }

    func selectSpectrumRow(
        _ spectrum: SpectroscopyFile,
        modifiers: NSEvent.ModifierFlags,
        tagContext: UUID? = nil
    ) {
        let relevantModifiers = modifiers.intersection([.command, .shift])
        if relevantModifiers.contains(.command) || relevantModifiers.contains(.shift) {
            if sidebarSelectedSpectrumIDs.contains(spectrum.id) {
                sidebarSelectedSpectrumIDs.remove(spectrum.id)
            } else {
                sidebarSelectedSpectrumIDs.insert(spectrum.id)
            }
        } else {
            sidebarSelectedSpectrumIDs = [spectrum.id]
        }

        if let parentID = spectrumParentIDBySpectrumID[spectrum.id],
           let parent = files.first(where: { $0.id == parentID }) {
            if selectedID != parent.id {
                select(parent, tagContext: tagContext)
            }
        }
    }

    func dragToken(for spectrum: SpectroscopyFile) -> String {
        if !sidebarSelectedSpectrumIDs.contains(spectrum.id) {
            sidebarSelectedSpectrumIDs = [spectrum.id]
        }
        let ids = Array(sidebarSelectedSpectrumIDs)
        let token = UUID().uuidString
        spectrumDragPayloads[token] = ids
        return token
    }

    func associateSpectra(
        fromDragToken token: String,
        to file: SXMMetadata,
        tagContext: UUID? = nil
    ) -> Bool {
        guard let ids = spectrumDragPayloads.removeValue(forKey: token),
              !ids.isEmpty else {
            return false
        }
        guard let session = activeDatasetSession else {
            status = metadataUnavailableForSpectrumChangesMessage
            return false
        }
        guard !isMetadataBusy else {
            status = "Wait for the current metadata operation to finish."
            return false
        }
        let currentSpectrumIDs = Set(spectra.map(\.id))
        guard currentSpectrumIDs.isSuperset(of: ids),
              files.contains(where: { $0.id == file.id }) else {
            status = "The association selection is no longer available."
            return false
        }

        let plan: ManualAssociationUpdatePlan
        do {
            plan = try ManualAssociationUpdatePlan(
                datIDs: ids,
                targetSXMID: file.id,
                pathIndex: session.pathIndex
            )
        } catch {
            status = "Spectra could not be associated: "
                + error.localizedDescription
            return false
        }

        let updatedAt = Date()
        let successMessage =
            "Associated \(ids.count) spectrum file"
            + (ids.count == 1 ? "" : "s")
            + " with \(file.filename)."
        performMetadataMutation(
            unavailableMessage: metadataUnavailableForSpectrumChangesMessage,
            successMessage: successMessage,
            failurePrefix: "Spectra could not be associated",
            mutation: { record in
                let updated = try plan.applying(
                    to: record.manualAssociations
                )
                try record.replaceManualAssociations(
                    with: updated,
                    updatedAt: updatedAt
                )
            },
            onVerified: { [weak self] _ in
                guard let self else { return }
                restoreManualSpectrumAssociations()
                rebuildSpectrumGroups()
                activateTagContextIfNeeded(tagContext)
                sidebarSelectedSpectrumIDs = Set(ids)
                updateSelection { state, visibleIDs in
                    state.selectOnly(file.id, in: visibleIDs)
                }
            }
        )
        return true
    }

    func normalizedMarkerPosition(for spectrum: SpectroscopyFile, on file: SXMMetadata) -> CGPoint? {
        guard let position = spectrum.position,
              let offset = file.scanOffset,
              let range = file.scanRange,
              range.x > 0,
              range.y > 0 else {
            return nil
        }

        let dx = position.x - offset.x
        let dy = position.y - offset.y
        let angle = (file.scanAngle ?? 0) * .pi / 180
        let scanX = cos(angle) * dx - sin(angle) * dy
        let scanY = sin(angle) * dx + cos(angle) * dy
        let u = 0.5 + scanX / range.x
        let scanDir = file.scanDir?.lowercased() ?? ""
        let v = scanDir.contains("up") ? 0.5 + scanY / range.y : 0.5 - scanY / range.y
        guard u.isFinite, v.isFinite else { return nil }
        return CGPoint(x: u, y: v)
    }

    func controlsChanged(resetScale: Bool = false) {
        guard mode == .single else {
            invalidateActiveRender(clearFrame: true)
            return
        }
        refreshSelectedImage(resetScale: resetScale)
    }

    func channelChanged() {
        guard let channel = selectedFile?.channels.first(where: { $0.name == selectedChannel }) else { return }
        if !channel.directions.contains(selectedDirection) {
            selectedDirection = channel.directions.first ?? .fwd
        }
        selectedPalette = defaultPalette(for: selectedChannel)
        selectedProcessing = defaultProcessing(for: selectedChannel)
        if mode == .single {
            refreshSelectedImage(resetScale: true)
        } else {
            invalidateActiveRender(clearFrame: true)
        }
    }

    func setFullScale() {
        guard let stats = selectedStats else { return }
        scalePreset = .full
        scaleLocked = true
        scaleMin = stats.min
        scaleMax = stats.max
        refreshSelectedImage(resetScale: false)
    }

    func setPercentileScale() {
        guard let stats = selectedStats else { return }
        scalePreset = .percentile
        scaleLocked = true
        scaleMin = stats.p1
        scaleMax = stats.p99
        refreshSelectedImage(resetScale: false)
    }

    func setSigmaScale(_ sigma: Double = 2.5) {
        guard let stats = selectedStats else { return }
        scalePreset = .sigma
        scaleLocked = true
        scaleMin = stats.mean - sigma * stats.std
        scaleMax = stats.mean + sigma * stats.std
        refreshSelectedImage(resetScale: false)
    }

    func applyScalePreset(_ preset: ScalePreset) {
        switch preset {
        case .full:
            setFullScale()
        case .percentile:
            setPercentileScale()
        case .sigma:
            setSigmaScale()
        case .manual:
            scalePreset = .manual
        }
    }

    func updateScale(min: Double, max: Double) {
        guard max > min else { return }
        scalePreset = .manual
        scaleLocked = true
        scaleMin = min
        scaleMax = max
        scaleRenderTask?.cancel()
        scaleRenderTask = Task {
            try? await Task.sleep(for: .milliseconds(70))
            if Task.isCancelled { return }
            refreshSelectedImage(resetScale: false)
        }
    }

    func thumbnail(for file: SXMMetadata, usingSelection: Bool = false) async -> NSImage? {
        let defaultChannel = file.defaultChannel ?? file.channels.first?.name ?? ""
        let channel = usingSelection && !selectedChannel.isEmpty ? selectedChannel : defaultChannel
        let channelInfo = file.channels.first(where: { $0.name == channel }) ?? file.channels.first(where: { $0.name == defaultChannel })
        let direction = usingSelection ? selectedDirection : (channelInfo?.directions.first ?? .fwd)
        let processing = usingSelection ? selectedProcessing : defaultProcessing(for: channel)
        let palette = usingSelection ? selectedPalette : defaultPalette(for: channel)
        let invert = usingSelection ? invertPalette : false
        let key = "\(file.path.path)|thumb|\(channel)|\(direction.rawValue)|\(processing.rawValue)|\(palette.rawValue)|\(invert)"
        if let cached = thumbnailCache.object(forKey: key as NSString) {
            return cached
        }

        if let existing = thumbnailTasks[key] {
            return await existing.task.value
        }

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await self?.generateThumbnail(
                for: file,
                cacheKey: key,
                channel: channel,
                direction: direction,
                processing: processing,
                palette: palette,
                invert: invert
            )
        }
        thumbnailTasks[key] = ThumbnailTaskEntry(token: token, task: task)
        let image = await task.value
        if thumbnailTasks[key]?.token == token {
            thumbnailTasks.removeValue(forKey: key)
        }
        return image
    }

    func refreshSelectedImage(resetScale: Bool) {
        guard let file = selectedFile, !selectedChannel.isEmpty else {
            invalidateActiveRender(clearFrame: true)
            return
        }
        if resetScale {
            scaleLocked = false
            scaleMin = nil
            scaleMax = nil
        }

        renderCoordinator.render(
            file: file,
            configuration: currentRenderConfiguration
        )
    }

    func exportPNG() {
        guard let file = selectedFile else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = exportFilename(for: file)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let channel = selectedChannel
        let direction = selectedDirection
        let processing = selectedProcessing
        let palette = selectedPalette
        let vmin = scaleMin
        let vmax = scaleMax
        let invert = invertPalette

        Task {
            do {
                let matrix = try await renderCoordinator.matrix(
                    for: file,
                    key: MatrixKey(
                        channel: channel,
                        direction: direction
                    ),
                    priority: .userInitiated
                )
                let options = RenderOptions(
                    channel: channel,
                    direction: direction,
                    processing: processing,
                    palette: palette,
                    vmin: vmin,
                    vmax: vmax,
                    invert: invert
                )
                let data = try await runDetachedCancellable(
                    priority: .userInitiated
                ) {
                    try SXMRenderer.pngData(
                        matrix: matrix,
                        options: options,
                        cancellation: .task
                    )
                }
                try data.write(to: destination)
                status = "Exported \(destination.lastPathComponent)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func updateSelection(
        resetScale: Bool = true,
        _ mutation: (
            inout SelectionState<SXMMetadata.ID>,
            [SXMMetadata.ID]
        ) -> Void
    ) {
        var updatedSelection = selection
        mutation(&updatedSelection, visibleFiles.map(\.id))
        commitSelection(updatedSelection, resetScale: resetScale)
    }

    private func commitSelection(
        _ updatedSelection: SelectionState<SXMMetadata.ID>,
        resetScale: Bool
    ) {
        let previousPrimaryID = selection.primaryID
        guard selection != updatedSelection else { return }
        selection = updatedSelection
        guard previousPrimaryID != selection.primaryID else { return }

        clearSelectedRender()
        guard selectedID != nil else {
            status = "No file selected."
            return
        }

        applyDefaultsFromSelection()
        if mode == .single {
            refreshSelectedImage(resetScale: resetScale)
        }
    }

    private var currentRenderConfiguration: SelectedRenderConfiguration {
        SelectedRenderConfiguration(
            channel: selectedChannel,
            direction: selectedDirection,
            processing: selectedProcessing,
            palette: selectedPalette,
            invert: invertPalette,
            histogramBins: histogramBins,
            scale: scaleLocked
                ? .locked(min: scaleMin, max: scaleMax)
                : .automatic
        )
    }

    private func histogramBinsChanged() {
        guard mode == .single, let file = selectedFile else {
            return
        }
        renderCoordinator.updateHistogram(
            fileID: file.id,
            configuration: currentRenderConfiguration
        )
    }

    private func handleRenderCoordinatorEvent(
        _ event: RenderCoordinatorEvent
    ) {
        switch event {
        case .started(let request, let configuration):
            guard acceptsCoordinatorRequest(
                request,
                configuration: configuration
            ) else {
                return
            }
            renderedFrame = nil
            let filename = files.first {
                $0.id == request.fileID
            }?.filename ?? "image"
            status = "Rendering \(filename)..."

        case .imageReady(let frame):
            guard acceptsCoordinatorFrame(frame) else { return }
            renderedFrame = frame
            if case .automatic = frame.configuration.scale {
                scaleMin = frame.automaticScaleMin
                scaleMax = frame.automaticScaleMax
            }
            status = files.first {
                $0.id == frame.request.fileID
            }?.filename ?? "Image rendered."

        case .histogramReady(let frame):
            guard acceptsCoordinatorFrame(frame) else { return }
            renderedFrame = frame

        case .failed(let failure):
            guard mode == .single,
                  selectedID == failure.request.fileID,
                  failure.request.configuration
                    == currentRenderConfiguration
                        .imageConfiguration else {
                return
            }
            renderedFrame = nil
            status = failure.message

        case .cleared:
            renderedFrame = nil
        }
    }

    private func acceptsCoordinatorRequest(
        _ request: RenderRequestIdentity<SXMMetadata.ID>,
        configuration: SelectedRenderConfiguration
    ) -> Bool {
        mode == .single
            && selectedID == request.fileID
            && configuration == currentRenderConfiguration
            && request.configuration
                == configuration.imageConfiguration
    }

    private func acceptsCoordinatorFrame(
        _ frame: CoordinatorRenderedFrame
    ) -> Bool {
        acceptsCoordinatorRequest(
            frame.request,
            configuration: frame.configuration
        )
    }

    private func invalidateActiveRender(clearFrame: Bool) {
        scaleRenderTask?.cancel()
        scaleRenderTask = nil
        renderCoordinator.invalidate(clearFrame: clearFrame)
    }

    private func clearSelectedRender() {
        invalidateActiveRender(clearFrame: true)
    }

    private func activateTagContextIfNeeded(_ tagID: UUID?) {
        guard let tagID,
              let session = activeDatasetSession,
              tags.contains(where: { $0.id == tagID }) else {
            return
        }
        sidebarMode = .tag
        activeTagID = tagID
        expandedTagIDs.insert(tagID)
        saveExpandedTagIDs(for: session.datasetID)
    }

    private func filesMatchingSearch(in candidates: [SXMMetadata]) -> [SXMMetadata] {
        let query = filenameSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }

        return candidates.filter { file in
            file.filename.localizedCaseInsensitiveContains(query)
                || spectra(for: file).contains {
                    $0.filename.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private func removeCachedData(for url: URL) {
        let path = url.standardizedFileURL.path
        renderCoordinator.removeMatrixEntries(
            forStandardizedPath: path
        )
        if selectedFile?.path.standardizedFileURL.path == path {
            renderCoordinator.discardProcessedData()
        }
        thumbnailCache.removeAllObjects()
        cancelThumbnailTasks()
    }

    private func ensureSelectionIsVisible() {
        updateSelection { state, visibleIDs in
            state.reconcile(with: visibleIDs, fallbackToFirst: true)
        }
    }

    private func createTag(
        named rawName: String,
        adding targetFiles: [SXMMetadata]
    ) {
        let name = normalizedTagName(rawName)
        guard !name.isEmpty else { return }
        guard let session = activeDatasetSession else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        let paths = targetFiles.compactMap {
            session.pathIndex.sxmPath(for: $0.id)
        }
        let tagID = UUID()
        let successMessage: String
        if paths.isEmpty {
            successMessage = "Created tag \(name)."
        } else {
            successMessage =
                "Created \(name) and added \(paths.count) file"
                + (paths.count == 1 ? "." : "s.")
        }
        performTagMutation(
            expandingTagID: tagID,
            successMessage: successMessage
        ) { record in
            _ = try record.createTag(
                id: tagID,
                name: name,
                sxmPaths: paths
            )
        }
    }

    private func addTag(_ tagID: UUID, to targetFiles: [SXMMetadata]) {
        guard let session = activeDatasetSession,
              let tag = tags.first(where: { $0.id == tagID }) else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        let paths = targetFiles.compactMap {
            session.pathIndex.sxmPath(for: $0.id)
        }
        guard !paths.isEmpty else { return }
        let additions = Set(paths).subtracting(tag.sxmPaths)
        let addedCount = additions.count
        guard addedCount > 0 else {
            expandedTagIDs.insert(tagID)
            saveExpandedTagIDs(for: session.datasetID)
            status = "The selected files are already in \(tag.name)."
            return
        }
        let successMessage = addedCount == 1
            ? "Added 1 file to \(tag.name)."
            : "Added \(addedCount) files to \(tag.name)."
        performTagMutation(
            expandingTagID: tagID,
            successMessage: successMessage
        ) { record in
            guard let storedTag = record.tags.first(where: {
                $0.id == tagID
            }) else {
                throw DatasetMetadataValidationError.tagNotFound(tagID)
            }
            try record.replaceTagMembers(
                id: tagID,
                with: storedTag.sxmPaths + paths
            )
        }
    }

    private func removeTag(_ tagID: UUID, from targetFiles: [SXMMetadata]) {
        guard let session = activeDatasetSession,
              let tag = tags.first(where: { $0.id == tagID }) else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        let pathsToRemove = Set(targetFiles.compactMap {
            session.pathIndex.sxmPath(for: $0.id)
        })
        guard !pathsToRemove.isEmpty else { return }
        let removedCount = Set(tag.sxmPaths)
            .intersection(pathsToRemove)
            .count
        guard removedCount > 0 else {
            status = "The selected files are not in \(tag.name)."
            return
        }
        let successMessage = removedCount == 1
            ? "Removed 1 file from \(tag.name)."
            : "Removed \(removedCount) files from \(tag.name)."
        performTagMutation(successMessage: successMessage) { record in
            guard let storedTag = record.tags.first(where: {
                $0.id == tagID
            }) else {
                throw DatasetMetadataValidationError.tagNotFound(tagID)
            }
            try record.replaceTagMembers(
                id: tagID,
                with: storedTag.sxmPaths.filter {
                    !pathsToRemove.contains($0)
                }
            )
        }
    }

    private func removeTags(forDeletedFiles deletedFiles: [SXMMetadata]) {
        guard !deletedFiles.isEmpty,
              let session = activeDatasetSession else {
            return
        }
        let deletedPaths = Set(deletedFiles.compactMap {
            session.pathIndex.sxmPath(for: $0.id)
        })
        guard !deletedPaths.isEmpty else { return }
        performTagMutation(
            failurePrefix: "Files were deleted, but tag metadata cleanup failed"
        ) { record in
            for tag in record.tags {
                try record.replaceTagMembers(
                    id: tag.id,
                    with: tag.sxmPaths.filter {
                        !deletedPaths.contains($0)
                    }
                )
            }
        }
    }

    private func performTagMutation(
        expandingTagID: UUID? = nil,
        activeTagResolution: MissingActiveTagResolution = .firstAvailable,
        successMessage: String? = nil,
        failurePrefix: String = "Tag metadata could not be updated",
        mutation: @escaping @Sendable (
            inout DatasetRecordV1
        ) throws -> Void
    ) {
        performMetadataMutation(
            unavailableMessage: metadataUnavailableForTagChangesMessage,
            successMessage: successMessage,
            failurePrefix: failurePrefix,
            mutation: mutation,
            onVerified: { [weak self] updatedSession in
                guard let self else { return }
                publishUpdatedTagPresentation(
                    tags: updatedSession.verifiedRecord.tags,
                    expandingTagID: expandingTagID,
                    activeTagResolution: activeTagResolution,
                    datasetID: updatedSession.datasetID
                )
            }
        )
    }

    private func performMetadataMutation(
        unavailableMessage: String,
        successMessage: String? = nil,
        failurePrefix: String,
        mutation: @escaping @Sendable (
            inout DatasetRecordV1
        ) throws -> Void,
        onVerified: @escaping @MainActor (
            ActiveDatasetSession
        ) -> Void
    ) {
        guard let session = activeDatasetSession else {
            status = unavailableMessage
            return
        }
        guard !isMetadataBusy else {
            status = "Wait for the current metadata operation to finish."
            return
        }

        let identity = session.identity
        let datasetID = session.datasetID
        let mutationID = UUID()
        metadataMutationID = mutationID
        isMetadataMutationInFlight = true

        metadataMutationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                finishMetadataMutation(id: mutationID)
            }
            do {
                let verifiedRecord = try await metadataStore.updateDataset(
                    id: datasetID,
                    mutation: mutation
                )
                try Task.checkCancellation()
                guard metadataMutationID == mutationID,
                      datasetSessionGate.accepts(identity),
                      let currentSession = activeDatasetSession,
                      currentSession.matches(identity) else {
                    return
                }
                let updatedSession = try ActiveDatasetSession(
                    sessionID: currentSession.sessionID,
                    datasetID: currentSession.datasetID,
                    folderURL: currentSession.folderURL,
                    verifiedRecord: verifiedRecord,
                    pathIndex: currentSession.pathIndex
                )
                guard datasetSessionGate.activate(updatedSession) else {
                    return
                }
                activeDatasetSession = updatedSession
                onVerified(updatedSession)
                if let successMessage {
                    status = successMessage
                }
            } catch is CancellationError {
                return
            } catch {
                guard metadataMutationID == mutationID,
                      datasetSessionGate.accepts(identity) else {
                    return
                }
                status = "\(failurePrefix): \(error.localizedDescription)"
            }
        }
    }

    private func finishMetadataMutation(id: UUID) {
        guard metadataMutationID == id else { return }
        metadataMutationID = nil
        metadataMutationTask = nil
        isMetadataMutationInFlight = false
    }

    private func cancelMetadataMutation() {
        metadataMutationID = nil
        metadataMutationTask?.cancel()
        metadataMutationTask = nil
        isMetadataMutationInFlight = false
    }

    private func publishInitialTagPresentation(
        for session: ActiveDatasetSession
    ) {
        tags = session.verifiedRecord.tags
        activeTagID = nil
        let storedExpandedIDs = Set(
            UserDefaults.standard
                .stringArray(
                    forKey: expandedTagIDsDefaultsKey(
                        datasetID: session.datasetID
                    )
                )?
                .compactMap(UUID.init(uuidString:)) ?? []
        )
        expandedTagIDs = TagPresentationProjection
            .filteredExpandedTagIDs(
                storedExpandedIDs,
                tags: tags
            )
    }

    private func publishUpdatedTagPresentation(
        tags updatedTags: [DatasetTagV1],
        expandingTagID: UUID?,
        activeTagResolution: MissingActiveTagResolution,
        datasetID: UUID
    ) {
        tags = updatedTags
        activeTagID = TagPresentationProjection.reconciledActiveTagID(
            activeTagID,
            tags: updatedTags
        )
        expandedTagIDs = TagPresentationProjection.filteredExpandedTagIDs(
            expandedTagIDs,
            tags: updatedTags
        )
        if let expandingTagID,
           updatedTags.contains(where: { $0.id == expandingTagID }) {
            expandedTagIDs.insert(expandingTagID)
        }
        if sidebarMode == .tag {
            if activeTagID == nil {
                switch activeTagResolution {
                case .firstAvailable:
                    activeTagID = updatedTags.first?.id
                case .preferred(let preferredID):
                    if let preferredID,
                       updatedTags.contains(where: {
                           $0.id == preferredID
                       }) {
                        activeTagID = preferredID
                    }
                }
                if activeTagID == nil {
                    sidebarMode = .all
                }
            }
            if sidebarMode == .tag {
                ensureSelectionIsVisible()
            }
        }
        saveExpandedTagIDs(for: datasetID)
    }

    private func saveExpandedTagIDs(for datasetID: UUID) {
        let values = expandedTagIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
        UserDefaults.standard.set(
            values,
            forKey: expandedTagIDsDefaultsKey(datasetID: datasetID)
        )
    }

    private func expandedTagIDsDefaultsKey(datasetID: UUID) -> String {
        "\(Defaults.expandedTagIDsByDataset)."
            + datasetID.uuidString.lowercased()
    }

    private var metadataUnavailableForTagChangesMessage: String {
        "Tag metadata is unavailable for this folder. Reopen the folder to retry."
    }

    private var metadataUnavailableForSpectrumChangesMessage: String {
        "Spectrum association metadata is unavailable for this folder. "
            + "Reopen the folder to retry."
    }

    private var metadataUnavailableForSpectrumVisibilityMessage: String {
        "Spectrum visibility metadata is unavailable for this folder. "
            + "Reopen the folder to retry."
    }

    private var metadataUnavailableForSpectrumAxesMessage: String {
        "Spectrum axis metadata is unavailable for this folder. "
            + "Reopen the folder to retry."
    }

    private func restoreManualSpectrumAssociations() {
        guard let session = activeDatasetSession else {
            manualTargetPathByDATPath = [:]
            manualAssociationProjection = nil
            manuallyAssignedSXMIDBySpectrumID = [:]
            return
        }
        let projection = ManualSpectrumAssociationProjection(
            associations: session.verifiedRecord.manualAssociations,
            pathIndex: session.pathIndex,
            availableSXMIDs: Set(files.map(\.id))
        )
        manualTargetPathByDATPath = projection.targetPathByDATPath
        manualAssociationProjection = projection
        manuallyAssignedSXMIDBySpectrumID =
            projection.resolvedSXMIDByDATID
    }

    private func restoreHiddenSpectrumVisibility() {
        guard let session = activeDatasetSession else {
            hiddenSpectrumIDs = []
            return
        }
        let projection = HiddenSpectrumProjection(
            hiddenDATPaths: session.verifiedRecord.hiddenDATPaths,
            pathIndex: session.pathIndex
        )
        hiddenSpectrumIDs = projection.hiddenDATIDs
    }

    private func rebuildSpectrumGroups() {
        let associated = associateSpectra(spectra, with: files)
        spectrumParentIDBySpectrumID = associated.parents
        spectrumGroupsByFileID = associated.groups
        unassociatedSpectrumIDs = associated.unassociated
        restoreSpectrumAxisPreferences()
    }

    private func rebuildSpectrumGroups(for parentIDs: Set<SXMMetadata.ID>) {
        guard !parentIDs.isEmpty else { return }
        var updatedGroups = spectrumGroupsByFileID
        for parentID in parentIDs {
            guard let file = files.first(where: { $0.id == parentID }) else {
                updatedGroups.removeValue(forKey: parentID)
                continue
            }
            let visibleSpectra = spectra.filter {
                spectrumParentIDBySpectrumID[$0.id] == parentID && !hiddenSpectrumIDs.contains($0.id)
            }
            let groups = SpectroscopyGroup.compatibleGroups(
                sxm: file,
                spectra: visibleSpectra
            )
            if groups.isEmpty {
                updatedGroups.removeValue(forKey: parentID)
            } else {
                updatedGroups[parentID] = groups
            }
        }
        spectrumGroupsByFileID = updatedGroups
        restoreSpectrumAxisPreferences()
    }

    private func restoreSpectrumAxisPreferences() {
        let groups = spectrumGroupsByFileID.values
            .flatMap { $0 }
            .map(SpectrumAxisRuntimeGroup.init)
        guard let session = activeDatasetSession else {
            spectrumAxisState =
                SpectrumAxisPreferenceProjection.safeDefaults(
                    for: groups
                )
            spectrumAxisRestoreIssues = []
            return
        }
        let projection = SpectrumAxisPreferenceProjection(
            preferences:
                session.verifiedRecord.spectrumAxisPreferences,
            groups: groups,
            pathIndex: session.pathIndex
        )
        spectrumAxisState = projection.axisState
        spectrumAxisRestoreIssues = projection.issues
    }

    private func associateSpectra(
        _ spectra: [SpectroscopyFile],
        with sxmFiles: [SXMMetadata]
    ) -> (
        groups: [SXMMetadata.ID: [SpectroscopyGroup]],
        parents: [SpectroscopyFile.ID: SXMMetadata.ID],
        unassociated: Set<SpectroscopyFile.ID>
    ) {
        let sxmByTime = sxmFiles.sorted { lhs, rhs in
            if lhs.modifiedTime == rhs.modifiedTime {
                return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
            }
            return lhs.modifiedTime < rhs.modifiedTime
        }
        let sxmByName = sxmFiles.sorted {
            sxmBasename($0).count > sxmBasename($1).count
        }
        guard !sxmByTime.isEmpty else {
            return ([:], [:], Set(spectra.map(\.id)))
        }

        var buckets: [SXMMetadata.ID: [SpectroscopyFile]] = [:]
        var parents: [SpectroscopyFile.ID: SXMMetadata.ID] = [:]
        var unassociated: Set<SpectroscopyFile.ID> = []
        for spectrum in spectra.sorted(by: { lhs, rhs in
            lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }) {
            let resolution = manualAssociationProjection?
                .resolution(forDATID: spectrum.id)
                ?? .automaticAllowed
            let parent: SXMMetadata?
            switch resolution {
            case .automaticAllowed:
                parent = automaticSpectrumParent(
                    for: spectrum,
                    sxmFilesByTime: sxmByTime,
                    sxmFilesByDescendingBasenameLength: sxmByName
                )
            case .manual(let sxmID):
                parent = sxmFiles.first { $0.id == sxmID }
            case .missingManualTarget:
                parent = nil
            }
            guard let parent else {
                unassociated.insert(spectrum.id)
                continue
            }
            parents[spectrum.id] = parent.id
            if !hiddenSpectrumIDs.contains(spectrum.id) {
                buckets[parent.id, default: []].append(spectrum)
            }
        }

        var output: [SXMMetadata.ID: [SpectroscopyGroup]] = [:]
        for file in sxmFiles {
            guard let fileSpectra = buckets[file.id] else { continue }
            output[file.id] = SpectroscopyGroup.compatibleGroups(
                sxm: file,
                spectra: fileSpectra
            )
        }
        return (output, parents, unassociated)
    }

    private func automaticSpectrumParent(
        for spectrum: SpectroscopyFile,
        sxmFilesByTime: [SXMMetadata],
        sxmFilesByDescendingBasenameLength: [SXMMetadata]
    ) -> SXMMetadata? {
        sxmMatchingFilename(
            for: spectrum,
            in: sxmFilesByDescendingBasenameLength
        )
            ?? sxmFilesByTime.last(where: {
                $0.modifiedTime <= spectrum.modifiedTime
            })
            ?? nearestSXM(to: spectrum, in: sxmFilesByTime)
    }

    private func sxmMatchingFilename(for spectrum: SpectroscopyFile, in sxmFilesByDescendingBasenameLength: [SXMMetadata]) -> SXMMetadata? {
        let spectrumBase = spectrum.path.deletingPathExtension().lastPathComponent.lowercased()
        return sxmFilesByDescendingBasenameLength.first { file in
            spectrumBase.hasPrefix(sxmBasename(file).lowercased())
        }
    }

    private func sxmBasename(_ file: SXMMetadata) -> String {
        file.path.deletingPathExtension().lastPathComponent
    }

    private func nearestSXM(to spectrum: SpectroscopyFile, in sxmFiles: [SXMMetadata]) -> SXMMetadata? {
        sxmFiles.min { lhs, rhs in
            abs(lhs.modifiedTime.timeIntervalSince(spectrum.modifiedTime)) < abs(rhs.modifiedTime.timeIntervalSince(spectrum.modifiedTime))
        }
    }

    private func normalizedTagName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateThumbnail(
        for file: SXMMetadata,
        cacheKey: String,
        channel: String,
        direction: ScanDirection,
        processing: ProcessingMode,
        palette: PaletteName,
        invert: Bool
    ) async -> NSImage? {
        guard await thumbnailLimiter.acquire() else {
            return nil
        }
        defer {
            Task {
                await thumbnailLimiter.release()
            }
        }

        do {
            if Task.isCancelled { return nil }
            let matrix = try await renderCoordinator.matrix(
                for: file,
                key: MatrixKey(
                    channel: channel,
                    direction: direction
                ),
                priority: .utility
            )
            if Task.isCancelled { return nil }
            let options = RenderOptions(
                channel: channel,
                direction: direction,
                processing: processing,
                palette: palette,
                outputSize: 260,
                invert: invert
            )
            let image = try await runDetachedCancellable(priority: .utility) {
                try SXMRenderer.renderImage(
                    matrix: matrix,
                    options: options,
                    cancellation: .task
                )
            }
            if Task.isCancelled { return nil }
            thumbnailCache.setObject(image, forKey: cacheKey as NSString, cost: estimatedImageCost(image))
            return image
        } catch {
            return nil
        }
    }

    private func cancelThumbnailTasks() {
        for entry in thumbnailTasks.values {
            entry.task.cancel()
        }
        thumbnailTasks.removeAll()
    }

    private func estimatedImageCost(_ image: NSImage) -> Int {
        let width = max(1, Int(image.size.width.rounded(.up)))
        let height = max(1, Int(image.size.height.rounded(.up)))
        return width * height * 4
    }

    private func exportFilename(for file: SXMMetadata) -> String {
        let base = file.filename.replacingOccurrences(of: ".sxm", with: "", options: [.caseInsensitive, .anchored], range: nil)
        let channel = selectedChannel.replacingOccurrences(of: "/", with: "-")
        return "\(base)__\(channel)__\(selectedDirection.rawValue)__\(selectedProcessing.rawValue).png"
    }

    private enum Defaults {
        static let sortMode = "native.sortMode"
        static let sortAscending = "native.sortAscending"
        static let sidebarWidth = "native.sidebarWidth"
        static let inspectorWidth = "native.inspectorWidth"
        static let sidebarVisible = "native.sidebarVisible"
        static let inspectorVisible = "native.inspectorVisible"
        static let lastFolder = "native.lastFolder"
        static let histogramBins = "native.histogramBins"
        static let gridColumns = "native.gridColumns"
        static let expandedTagIDsByDataset =
            "native.expandedTagIDsByDataset"
    }

    private static func loadSortMode() -> SortMode {
        if let raw = UserDefaults.standard.string(forKey: Defaults.sortMode),
           let mode = SortMode(rawValue: raw) {
            return mode
        }
        return .name
    }

    private static func loadCGFloat(_ key: String, fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        let value = CGFloat(UserDefaults.standard.double(forKey: key))
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private static func loadBool(_ key: String, fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func loadInt(_ key: String, fallback: Int, range: ClosedRange<Int>) -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        let value = UserDefaults.standard.integer(forKey: key)
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
