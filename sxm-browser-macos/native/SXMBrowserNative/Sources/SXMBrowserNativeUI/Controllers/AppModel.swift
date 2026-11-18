import AppKit
import Foundation
import Observation
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

@Observable
@MainActor
public final class AppModel {
    private struct VisibleDisplayItemsCache {
        let visibleFilesVersion: UInt64
        let showsCards: Bool
        let presentationRevision: UInt64?
        let items: [GridDisplayItem]
    }

    internal struct DatasetMetadataPreparation {
        let record: DatasetRecordV1?
        let warnings: MetadataWarningCollection
    }

    public static let defaultSidebarWidth: CGFloat = 300
    public static let defaultInspectorWidth: CGFloat = 320
    public static let sidebarWidthRange: ClosedRange<CGFloat> = 220...460
    public static let inspectorWidthRange: ClosedRange<CGFloat> = 260...430

    public let dataset: DatasetSessionController
    public let viewer: ImageViewerController
    public let spectroscopy: SpectroscopyController
    public let thumbnails: ThumbnailPipeline

    public var selection = SelectionState<SXMMetadata.ID>()
    public var sidebarWidth: CGFloat = BrowserDefaults.loadCGFloat(
        BrowserDefaults.sidebarWidth,
        fallback: AppModel.defaultSidebarWidth,
        range: AppModel.sidebarWidthRange
    )
    public var inspectorWidth: CGFloat = BrowserDefaults.loadCGFloat(
        BrowserDefaults.inspectorWidth,
        fallback: AppModel.defaultInspectorWidth,
        range: AppModel.inspectorWidthRange
    )
    public var isSidebarVisible = BrowserDefaults.loadBool(
        BrowserDefaults.sidebarVisible,
        fallback: true
    ) {
        didSet {
            UserDefaults.standard.set(isSidebarVisible, forKey: BrowserDefaults.sidebarVisible)
        }
    }
    public var isInspectorVisible = BrowserDefaults.loadBool(
        BrowserDefaults.inspectorVisible,
        fallback: true
    ) {
        didSet {
            UserDefaults.standard.set(isInspectorVisible, forKey: BrowserDefaults.inspectorVisible)
        }
    }
    // Effective visibility is window-local state; automatic folding must not
    // overwrite the user's saved pane preferences.
    public internal(set) var actualSidebarVisible = true
    public internal(set) var actualInspectorVisible = true
    public internal(set) var sidebarVisibilityRequestID: UUID?
    public internal(set) var inspectorVisibilityRequestID: UUID?

    public var gridDensity: GridDensity = BrowserDefaults.loadGridDensity() {
        didSet {
            UserDefaults.standard.set(gridDensity.rawValue, forKey: BrowserDefaults.gridDensity)
        }
    }
    public internal(set) var gridNavigationColumnCount = 1
    public internal(set) var filenameSearchFocusRequestID: UUID?
    public internal(set) var filenameSearchBlurRequestID: UUID?

    /// Interactions that continuously change the image viewport defer
    /// geometry-derived state so SwiftUI does not rebuild the whole window on
    /// every frame. `splitLayoutInteracting` covers native pane animation and
    /// divider dragging; `viewportResizing` covers the spectroscopy drawer and
    /// live window resize.
    @ObservationIgnored internal var splitLayoutInteracting = false
    @ObservationIgnored internal var viewportResizing = false
    internal var defersViewportGeometry: Bool {
        splitLayoutInteracting || viewportResizing
    }
    @ObservationIgnored internal var pendingGridNavigationColumnCount: Int?

    @ObservationIgnored internal let parser = SXMParser()
    @ObservationIgnored internal let spectroscopyParser = SpectroscopyParser()
    @ObservationIgnored internal let metadataStore: DatasetMetadataStore
    @ObservationIgnored internal let legacyTagMigrator: LegacyTagMigrator
    @ObservationIgnored internal let folderBookmarker: any FolderBookmarking

    @ObservationIgnored internal var startupTask: Task<Void, Never>?
    @ObservationIgnored internal var startupRequestID: UUID?
    @ObservationIgnored internal var scanTask: Task<Void, Never>?
    @ObservationIgnored internal var datasetSessionGate = DatasetSessionGate()
    @ObservationIgnored internal var metadataMutationTask: Task<Void, Never>?
    @ObservationIgnored internal var metadataMutationID: UUID?
    @ObservationIgnored internal var metadataTransferTask: Task<Void, Never>?
    @ObservationIgnored internal var metadataTransferID: UUID?
    @ObservationIgnored internal var filenameSearchTask: Task<Void, Never>?
    @ObservationIgnored internal var filenameSearchRequestGate = FilenameSearchRequestGate()
    @ObservationIgnored internal var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored internal var renderFailureNoticeID: UUID?
    @ObservationIgnored internal var datasetInventoryRevisionID: UUID?
    @ObservationIgnored internal var securityScopedFolderURL: URL?
    @ObservationIgnored internal var activeDeleteOperationID: UUID?
    @ObservationIgnored private var cachedVisibleDisplayItems: VisibleDisplayItemsCache?

    @ObservationIgnored public var confirmDeletion: @MainActor ([SXMMetadata]) -> Bool = { targets in
        AppModel.runDeletionConfirmationAlert(for: targets)
    }
    @ObservationIgnored public var trashFile: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    @ObservationIgnored public var presentDeletionResultAlert: @MainActor ([String], [String]) -> Void = { trashedNames, failedNames in
        AppModel.runDeletionResultAlert(trashedNames: trashedNames, failedNames: failedNames)
    }

    public init(
        metadataStore: DatasetMetadataStore = DatasetMetadataStore(),
        folderBookmarker: any FolderBookmarking = MacOSFolderBookmarker(),
        renderCoordinator: RenderCoordinator = RenderCoordinator(),
        thumbnailPipeline: ThumbnailPipeline? = nil
    ) {
        let dataset = DatasetSessionController()
        let viewer = ImageViewerController(renderCoordinator: renderCoordinator)
        let spectroscopy = SpectroscopyController()
        let thumbnails = thumbnailPipeline ?? ThumbnailPipeline(renderCoordinator: renderCoordinator)

        self.dataset = dataset
        self.viewer = viewer
        self.spectroscopy = spectroscopy
        self.thumbnails = thumbnails
        self.metadataStore = metadataStore
        self.legacyTagMigrator = LegacyTagMigrator(metadataStore: metadataStore)
        self.folderBookmarker = folderBookmarker

        dataset.associatedSpectraProvider = { [weak spectroscopy, weak dataset] file in
            guard let spectroscopy, let dataset else { return [] }
            return spectroscopy.spectra(for: file, in: dataset.spectra)
        }
        dataset.associationRevisionProvider = { [weak spectroscopy] in
            spectroscopy?.associationRevision ?? 0
        }
        viewer.onSTMPreviewPaletteChanged = { [weak thumbnails] in
            thumbnails?.invalidateAll()
        }
        viewer.onHistogramBinsChanged = { [weak self] in
            self?.histogramBinsChanged()
        }
        renderCoordinator.onEvent = { [weak self] event in
            self?.handleRenderCoordinatorEvent(event)
        }
    }

    // MARK: - Sub-controller Forwarders (preserve fine-grained @Observable tracking)

    public var folder: URL? {
        get { dataset.folder }
        set { dataset.folder = newValue }
    }
    public var files: [SXMMetadata] {
        get { dataset.files }
        set { dataset.files = newValue }
    }
    public var spectra: [SpectroscopyFile] {
        get { dataset.spectra }
        set { dataset.spectra = newValue }
    }
    public var scanIssues: [ScanIssue] {
        get { dataset.scanIssues }
        set { dataset.scanIssues = newValue }
    }
    public var datasetLoadState: DatasetLoadState {
        get { dataset.datasetLoadState }
        set { dataset.datasetLoadState = newValue }
    }
    public var status: String {
        get { dataset.status }
        set { dataset.status = newValue }
    }
    public var metadataWarnings: MetadataWarningPresentationState {
        get { dataset.metadataWarnings }
        set { dataset.metadataWarnings = newValue }
    }
    public var noticePresentation: NoticePresentationState {
        get { dataset.noticePresentation }
        set { dataset.noticePresentation = newValue }
    }
    public var activeDatasetSession: ActiveDatasetSession? {
        get { dataset.activeDatasetSession }
        set { dataset.activeDatasetSession = newValue }
    }
    public var tags: [DatasetTagV1] {
        get { dataset.tags }
        set { dataset.tags = newValue }
    }
    public var expandedTagIDs: Set<UUID> {
        get { dataset.expandedTagIDs }
        set { dataset.expandedTagIDs = newValue }
    }
    public var sidebarMode: SidebarMode {
        get { dataset.sidebarMode }
        set { dataset.sidebarMode = newValue }
    }
    public var activeTagID: UUID? {
        get { dataset.activeTagID }
        set { dataset.activeTagID = newValue }
    }
    public var filenameSearch: String {
        get { dataset.filenameSearch }
        set { dataset.filenameSearch = newValue }
    }
    public var appliedFilenameSearch: String {
        get { dataset.appliedFilenameSearch }
        set { dataset.appliedFilenameSearch = newValue }
    }
    public var sortMode: SortMode {
        get { dataset.sortMode }
        set { dataset.sortMode = newValue }
    }
    public var sortAscending: Bool {
        get { dataset.sortAscending }
        set { dataset.sortAscending = newValue }
    }
    public var isMetadataMutationInFlight: Bool {
        get { dataset.isMetadataMutationInFlight }
        set { dataset.isMetadataMutationInFlight = newValue }
    }
    public var isMetadataTransferInFlight: Bool {
        get { dataset.isMetadataTransferInFlight }
        set { dataset.isMetadataTransferInFlight = newValue }
    }
    public var metadataImportWorkflow: MetadataImportWorkflow? {
        get { dataset.metadataImportWorkflow }
        set { dataset.metadataImportWorkflow = newValue }
    }

    public var mode: BrowserMode {
        get { viewer.mode }
        set { viewer.mode = newValue }
    }
    public var selectedChannel: String {
        get { viewer.selectedChannel }
        set { viewer.selectedChannel = newValue }
    }
    public var selectedDirection: ScanDirection {
        get { viewer.selectedDirection }
        set { viewer.selectedDirection = newValue }
    }
    public var selectedProcessing: ProcessingMode {
        get { viewer.selectedProcessing }
        set { viewer.selectedProcessing = newValue }
    }
    public var selectedPalette: PaletteName {
        get { viewer.selectedPalette }
        set { viewer.selectedPalette = newValue }
    }
    public var stmPreviewPalette: PaletteName {
        get { viewer.stmPreviewPalette }
        set { viewer.stmPreviewPalette = newValue }
    }
    public var invertPalette: Bool {
        get { viewer.invertPalette }
        set { viewer.invertPalette = newValue }
    }
    public var scalePreset: ScalePreset {
        get { viewer.scalePreset }
        set { viewer.scalePreset = newValue }
    }
    public var histogramBins: Int {
        get { viewer.histogramBins }
        set { viewer.histogramBins = newValue }
    }
    public var scaleLocked: Bool {
        get { viewer.scaleLocked }
        set { viewer.scaleLocked = newValue }
    }
    public var scaleMin: Double? {
        get { viewer.scaleMin }
        set { viewer.scaleMin = newValue }
    }
    public var scaleMax: Double? {
        get { viewer.scaleMax }
        set { viewer.scaleMax = newValue }
    }
    public var renderedFrame: CoordinatorRenderedFrame? {
        get { viewer.renderedFrame }
        set { viewer.renderedFrame = newValue }
    }
    public var selectedRenderState: SelectedRenderState<SXMMetadata.ID> {
        get { viewer.selectedRenderState }
        set { viewer.selectedRenderState = newValue }
    }
    public var viewerTransform: ViewerTransform {
        get { viewer.viewerTransform }
        set { viewer.viewerTransform = newValue }
    }
    public var renderCoordinator: RenderCoordinator {
        viewer.renderCoordinator
    }

    public var spectrumGroupsByFileID: [SXMMetadata.ID: [SpectroscopyGroup]] {
        get { spectroscopy.spectrumGroupsByFileID }
        set { spectroscopy.spectrumGroupsByFileID = newValue }
    }
    public var spectrumParentIDBySpectrumID: [SpectroscopyFile.ID: SXMMetadata.ID] {
        get { spectroscopy.spectrumParentIDBySpectrumID }
        set { spectroscopy.spectrumParentIDBySpectrumID = newValue }
    }
    public var hiddenSpectrumIDs: Set<SpectroscopyFile.ID> {
        get { spectroscopy.hiddenSpectrumIDs }
        set { spectroscopy.hiddenSpectrumIDs = newValue }
    }
    public var sidebarSelectedSpectrumIDs: Set<SpectroscopyFile.ID> {
        get { spectroscopy.sidebarSelectedSpectrumIDs }
        set { spectroscopy.sidebarSelectedSpectrumIDs = newValue }
    }
    public var unassociatedSpectrumIDs: Set<SpectroscopyFile.ID> {
        get { spectroscopy.unassociatedSpectrumIDs }
        set { spectroscopy.unassociatedSpectrumIDs = newValue }
    }
    public var showsGridSpectroscopyCards: Bool {
        get { spectroscopy.showsGridSpectroscopyCards }
        set { spectroscopy.showsGridSpectroscopyCards = newValue }
    }
    public var singleSpectroscopyState: SingleSpectroscopyState {
        get { spectroscopy.singleSpectroscopyState }
        set { spectroscopy.singleSpectroscopyState = newValue }
    }
    public var spectrumAxisState: SpectroscopyAxisState {
        get { spectroscopy.spectrumAxisState }
        set { spectroscopy.spectrumAxisState = newValue }
    }
    public var spectrumAxisRestoreIssues: [SpectrumAxisPreferenceRestoreIssue] {
        get { spectroscopy.spectrumAxisRestoreIssues }
        set { spectroscopy.spectrumAxisRestoreIssues = newValue }
    }
    internal var manualAssociationProjection: ManualSpectrumAssociationProjection? {
        get { spectroscopy.manualAssociationProjection }
        set { spectroscopy.manualAssociationProjection = newValue }
    }
    internal var spectrumDragPayloads: [String: [SpectroscopyFile.ID]] {
        get { spectroscopy.spectrumDragPayloads }
        set { spectroscopy.spectrumDragPayloads = newValue }
    }

    // MARK: - Derived State

    public var selectedID: SXMMetadata.ID? {
        selection.primaryID
    }

    public var selectedIDs: Set<SXMMetadata.ID> {
        selection.selectedIDs
    }

    public var selectedImage: NSImage? {
        viewer.renderedImage(for: selectedID)
    }

    public var selectedStats: HistogramStats? {
        viewer.renderedStats(for: selectedID)
    }

    public var canAdjustViewerTransform: Bool {
        viewer.canAdjustViewerTransform(selectedID: selectedID)
    }

    public var canZoomViewerIn: Bool {
        viewer.canZoomViewerIn(selectedID: selectedID)
    }

    public var canZoomViewerOut: Bool {
        viewer.canZoomViewerOut(selectedID: selectedID)
    }

    public var viewerZoomLabel: String {
        viewer.viewerZoomLabel
    }

    public var selectedFile: SXMMetadata? {
        guard let selectedID else { return nil }
        return files.first { $0.id == selectedID }
    }

    public var selectedFiles: [SXMMetadata] {
        let fileByID = Dictionary(
            uniqueKeysWithValues: files.map { ($0.id, $0) }
        )
        return selectionActionPresentation.orderedIDs.compactMap {
            fileByID[$0]
        }
    }

    public var selectedCount: Int {
        selectionActionPresentation.orderedIDs.count
    }

    public var selectionActionPresentation: SelectionActionPresentation<SXMMetadata.ID> {
        SelectionActionPresentation(
            visibleIDs: visibleFiles.map(\.id),
            selectedIDs: selectedIDs
        )
    }

    public var isLoading: Bool {
        dataset.isLoading
    }

    public var browserContentState: BrowserContentState<SXMMetadata.ID> {
        BrowserContentProjection.resolve(
            datasetState: datasetLoadState,
            totalFileCount: files.count,
            visibleFileCount: visibleFiles.count,
            searchIsActive: !appliedFilenameSearch
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            isSingleMode: mode == .single,
            selectedFileID: selectedID,
            renderState: selectedRenderState
        )
    }

    public var isMetadataBusy: Bool {
        dataset.isMetadataBusy
    }

    public var canDeleteSelection: Bool {
        !selectedFiles.isEmpty && !isMetadataBusy
    }

    public var canModifyTags: Bool {
        dataset.canModifyTags
    }

    public var canAssociateSpectra: Bool {
        dataset.canAssociateSpectra
    }

    public var canModifySpectrumVisibility: Bool {
        dataset.canModifySpectrumVisibility
    }

    public var canModifySpectrumAxes: Bool {
        dataset.canModifySpectrumAxes
    }

    public var canExportMetadata: Bool {
        dataset.canExportMetadata
    }

    public var canImportMetadata: Bool {
        dataset.canImportMetadata
    }

    public var canOpenFolder: Bool {
        dataset.canOpenFolder
    }

    public var metadataWarning: String? {
        dataset.metadataWarning
    }

    public var shouldPresentMetadataWarning: Bool {
        dataset.shouldPresentMetadataWarning
    }

    public var metadataWarningSummary: String {
        dataset.metadataWarningSummary
    }

    public var canRetryMetadataWarning: Bool {
        dataset.canRetryMetadataWarning
    }

    public var presentedSpectrumAxisRestoreIssues: [SpectrumAxisPreferenceRestoreIssue] {
        spectroscopy.presentedSpectrumAxisRestoreIssues
    }

    public var visibleUnassociatedSpectra: [SpectroscopyFile] {
        spectroscopy.visibleUnassociatedSpectra(in: spectra, search: appliedFilenameSearch)
    }

    public var sortedFiles: [SXMMetadata] {
        dataset.sortedFiles
    }

    public var visibleFiles: [SXMMetadata] {
        dataset.visibleFiles
    }

    public var searchResultCountText: String {
        dataset.searchResultCountText
    }

    public var visibleDisplayItems: [GridDisplayItem] {
        let currentVisibleFiles = dataset.visibleFiles
        let currentVisibleVersion = dataset.visibleFilesVersion
        let showsCards = spectroscopy.showsGridSpectroscopyCards
        let currentPresentationRevision: UInt64? = showsCards
            ? spectroscopy.presentationRevision
            : nil

        if let cached = cachedVisibleDisplayItems,
           cached.visibleFilesVersion == currentVisibleVersion,
           cached.showsCards == showsCards,
           cached.presentationRevision == currentPresentationRevision {
            return cached.items
        }

        let items: [GridDisplayItem] = currentVisibleFiles.flatMap { file -> [GridDisplayItem] in
            var row: [GridDisplayItem] = [.sxm(file)]
            if showsCards {
                row.append(
                    contentsOf: presentedSpectrumGroups(for: file)
                        .filter(\.shouldShowGridCard)
                        .map(GridDisplayItem.spectroscopy)
                )
            }
            return row
        }
        cachedVisibleDisplayItems = VisibleDisplayItemsCache(
            visibleFilesVersion: currentVisibleVersion,
            showsCards: showsCards,
            presentationRevision: currentPresentationRevision,
            items: items
        )
        return items
    }

    public var selectedChannelInfo: SXMChannel? {
        selectedFile?.channels.first { $0.name == selectedChannel }
    }

    public var selectedPositionText: String {
        let list = visibleFiles
        guard !list.isEmpty, let selected = selectedFile,
              let index = list.firstIndex(where: { $0.id == selected.id }) else {
            return "0 / 0"
        }
        return "\(index + 1) / \(list.count)"
    }

    public func files(forTagID tagID: UUID) -> [SXMMetadata] {
        dataset.files(forTagID: tagID)
    }

    public func visibleFiles(forTagID tagID: UUID) -> [SXMMetadata] {
        dataset.visibleFiles(forTagID: tagID)
    }

    // MARK: - Search & Layout Controls

    public func setSidebarMode(_ mode: SidebarMode) {
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

    public func setFilenameSearch(_ value: String) {
        guard filenameSearch != value else { return }
        filenameSearch = value
        filenameSearchTask?.cancel()
        filenameSearchTask = nil

        let request = filenameSearchRequestGate.begin(query: value)
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyFilenameSearch(request)
            return
        }

        filenameSearchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard let self else { return }
            self.applyFilenameSearch(request)
        }
    }

    public func clearFilenameSearch() {
        filenameSearchTask?.cancel()
        filenameSearchTask = nil
        filenameSearchRequestGate.cancel()
        filenameSearch = ""
        setAppliedFilenameSearch("")
    }

    public func requestFilenameSearchFocus() {
        showSidebar()
        filenameSearchFocusRequestID = UUID()
    }

    public func requestFilenameSearchBlur() {
        filenameSearchBlurRequestID = UUID()
    }

    internal func commitFilenameSearch() {
        filenameSearchTask?.cancel()
        filenameSearchTask = nil
        let request = filenameSearchRequestGate.begin(query: filenameSearch)
        applyFilenameSearch(request)
    }

    internal func applyFilenameSearch(_ request: FilenameSearchRequest) {
        guard filenameSearchRequestGate.accepts(request) else { return }
        filenameSearchTask = nil
        setAppliedFilenameSearch(request.query)
    }

    internal func setAppliedFilenameSearch(_ value: String) {
        guard appliedFilenameSearch != value else { return }
        appliedFilenameSearch = value
        updateSelection { state, visibleIDs in
            state.reconcile(with: visibleIDs, fallbackToFirst: false)
        }
    }

    public func updatePaneVisibility(sidebar: Bool, inspector: Bool) {
        if actualSidebarVisible != sidebar { actualSidebarVisible = sidebar }
        if actualInspectorVisible != inspector { actualInspectorVisible = inspector }
    }

    public func setSplitLayoutInteracting(_ interacting: Bool) {
        guard splitLayoutInteracting != interacting else { return }
        splitLayoutInteracting = interacting
        flushDeferredViewportGeometry()
    }

    public func setViewportResizing(_ resizing: Bool) {
        guard viewportResizing != resizing else { return }
        viewportResizing = resizing
        flushDeferredViewportGeometry()
    }

    private func flushDeferredViewportGeometry() {
        guard !defersViewportGeometry else { return }
        if let pending = viewer.pendingViewerGeometry {
            viewer.pendingViewerGeometry = nil
            reconcileViewerGeometry(
                imageSize: pending.imageSize,
                viewportSize: pending.viewportSize
            )
        }
        if let columns = pendingGridNavigationColumnCount {
            pendingGridNavigationColumnCount = nil
            setGridNavigationColumnCount(columns)
        }
    }

    public func toggleSidebar() {
        isSidebarVisible = !actualSidebarVisible
        sidebarVisibilityRequestID = UUID()
    }

    public func showSidebar() {
        isSidebarVisible = true
        sidebarVisibilityRequestID = UUID()
    }

    public func toggleInspector() {
        isInspectorVisible = !actualInspectorVisible
        inspectorVisibilityRequestID = UUID()
    }

    public func resetLayout() {
        sidebarVisibilityRequestID = nil
        inspectorVisibilityRequestID = nil
        isSidebarVisible = true
        isInspectorVisible = true
        sidebarWidth = Self.defaultSidebarWidth
        inspectorWidth = Self.defaultInspectorWidth
        setSingleSpectroscopyDrawerExpanded(true)
        setSingleSpectroscopyDrawerHeight(
            CGFloat(SingleSpectroscopyState.defaultHeight)
        )
        saveLayoutWidths()
    }

    public func saveLayoutWidths() {
        UserDefaults.standard.set(Double(sidebarWidth), forKey: BrowserDefaults.sidebarWidth)
        UserDefaults.standard.set(Double(inspectorWidth), forKey: BrowserDefaults.inspectorWidth)
    }

    public func setGridNavigationColumnCount(_ value: Int) {
        let normalized = max(1, value)
        if defersViewportGeometry {
            pendingGridNavigationColumnCount = normalized
            return
        }
        guard gridNavigationColumnCount != normalized else {
            return
        }
        gridNavigationColumnCount = normalized
    }
}
