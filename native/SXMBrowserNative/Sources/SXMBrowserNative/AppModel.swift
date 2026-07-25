import AppKit
import Foundation
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

enum BrowserMode: String, CaseIterable, Identifiable {
    case grid
    case single

    var id: String { rawValue }
    var label: String { self == .grid ? "Grid" : "Single" }
}

enum SortMode: String, CaseIterable, Identifiable {
    case name
    case modifiedTime

    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: "File name"
        case .modifiedTime: "Modified time"
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

@MainActor
final class AppModel: ObservableObject {
    static let defaultSidebarWidth: CGFloat = 300
    static let defaultInspectorWidth: CGFloat = 320
    static let sidebarWidthRange: ClosedRange<CGFloat> = 220...460
    static let inspectorWidthRange: ClosedRange<CGFloat> = 260...430

    @Published var folder: URL?
    @Published var files: [SXMMetadata] = []
    @Published var spectra: [SpectroscopyFile] = []
    @Published var spectrumGroupsByFileID: [SXMMetadata.ID: [SpectroscopyGroup]] = [:]
    @Published var spectrumParentIDBySpectrumID: [SpectroscopyFile.ID: SXMMetadata.ID] = [:]
    @Published var hiddenSpectrumIDs: Set<SpectroscopyFile.ID> = []
    @Published var sidebarSelectedSpectrumIDs: Set<SpectroscopyFile.ID> = []
    @Published var manuallyAssignedSXMIDBySpectrumID: [SpectroscopyFile.ID: SXMMetadata.ID] = [:]
    @Published var areSpectraVisible = true
    @Published private(set) var selection = SelectionState<SXMMetadata.ID>()
    @Published var sidebarMode: SidebarMode = .all
    @Published var activeTagName: String?
    @Published private(set) var filenameSearch = ""
    @Published var mode: BrowserMode = .grid
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

    @Published var selectedChannel = ""
    @Published var selectedDirection: ScanDirection = .fwd
    @Published var selectedProcessing: ProcessingMode = .raw
    @Published var selectedPalette: PaletteName = .gwyddionNet
    @Published var invertPalette = false
    @Published var selectedSpectrumXColumn = ""
    @Published var selectedSpectrumYColumn = ""

    @Published var selectedImage: NSImage?
    @Published var selectedStats: HistogramStats?
    @Published var scalePreset: ScalePreset = .percentile
    @Published var histogramBins: Int = AppModel.loadInt(Defaults.histogramBins, fallback: 256, range: 64...1024) {
        didSet {
            UserDefaults.standard.set(histogramBins, forKey: Defaults.histogramBins)
            controlsChanged()
        }
    }
    @Published var gridColumns: Int = AppModel.loadInt(Defaults.gridColumns, fallback: 3, range: 2...8) {
        didSet { UserDefaults.standard.set(gridColumns, forKey: Defaults.gridColumns) }
    }
    @Published var scaleLocked = false
    @Published var scaleMin: Double?
    @Published var scaleMax: Double?
    @Published var tagNames: [String] = []
    @Published var taggedFilePathsByTag: [String: Set<String>] = [:]
    @Published var expandedTagNames: Set<String> = []

    private let parser = SXMParser()
    private let spectroscopyParser = SpectroscopyParser()
    private var fullCache: [URL: SXMFullFile] = [:]
    private var fullCacheOrder: [URL] = []
    private let fullCacheLimit = 24
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailTasks: [String: Task<NSImage?, Never>] = [:]
    private let thumbnailLimiter = AsyncLimiter(limit: 4)
    private var scanTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var scaleRenderTask: Task<Void, Never>?
    private var processedCacheKey: String?
    private var processedCacheMatrix: Matrix?
    private var processedCacheStats: HistogramStats?
    private var processedCacheStatsBins: Int?
    private var spectrumDragPayloads: [String: [SpectroscopyFile.ID]] = [:]

    init() {
        thumbnailCache.countLimit = 180
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024
    }

    var selectedID: SXMMetadata.ID? {
        selection.primaryID
    }

    var selectedIDs: Set<SXMMetadata.ID> {
        selection.selectedIDs
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

    var canDeleteSelection: Bool {
        !selectedFiles.isEmpty && !isLoading
    }

    var sortedFiles: [SXMMetadata] {
        files.sorted { lhs, rhs in
            let result: Bool
            switch sortMode {
            case .modifiedTime:
                result = lhs.modifiedTime < rhs.modifiedTime
            case .name:
                result = lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
            }
            return sortAscending ? result : !result
        }
    }

    var visibleFiles: [SXMMetadata] {
        let scopedFiles: [SXMMetadata]
        switch sidebarMode {
        case .all:
            scopedFiles = sortedFiles
        case .tag:
            guard let activeTagName, tagNames.contains(activeTagName) else {
                return []
            }
            scopedFiles = files(forTag: activeTagName)
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

    var selectedSpectrumColumns: [String] {
        guard let file = selectedFile else { return [] }
        var columns: [String] = []
        var seen: Set<String> = []
        for spectrum in spectra(for: file) {
            for column in spectrum.curve.columns where !seen.contains(column) {
                columns.append(column)
                seen.insert(column)
            }
        }
        return columns
    }

    var selectedPositionText: String {
        let list = visibleFiles
        guard !list.isEmpty, let selected = selectedFile,
              let index = list.firstIndex(where: { $0.id == selected.id }) else {
            return "0 / 0"
        }
        return "\(index + 1) / \(list.count)"
    }

    func files(forTag tag: String) -> [SXMMetadata] {
        guard let taggedPaths = taggedFilePathsByTag[tag] else { return [] }
        return sortedFiles.filter { taggedPaths.contains(fileKey($0.path)) }
    }

    func visibleFiles(forTag tag: String) -> [SXMMetadata] {
        filesMatchingSearch(in: files(forTag: tag))
    }

    func setSidebarMode(_ mode: SidebarMode) {
        sidebarMode = mode
        if mode == .all {
            activeTagName = nil
            ensureSelectionIsVisible()
        } else if let activeTagName, tagNames.contains(activeTagName) {
            selectTag(activeTagName)
        } else if let firstTag = tagNames.first {
            selectTag(firstTag)
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
        if let savedPath = UserDefaults.standard.string(forKey: Defaults.lastFolder) {
            let savedURL = URL(fileURLWithPath: savedPath)
            if FileManager.default.fileExists(atPath: savedURL.path) {
                openFolder(savedURL)
                return
            }
        }

        let appParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let workspaceParent = appParent.deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let exampleFolders = [
            workspaceParent.appendingPathComponent("example-graph"),
            workspaceParent.appendingPathComponent("example"),
            appParent.appendingPathComponent("example-graph"),
            appParent.appendingPathComponent("example"),
            cwd.appendingPathComponent("example-graph"),
            cwd.appendingPathComponent("example"),
            cwd.appendingPathComponent("../example-graph").standardizedFileURL,
            cwd.appendingPathComponent("../example").standardizedFileURL,
            cwd.appendingPathComponent("../../example-graph").standardizedFileURL,
            cwd.appendingPathComponent("../../example").standardizedFileURL,
            cwd.appendingPathComponent("../../../example-graph").standardizedFileURL,
            cwd.appendingPathComponent("../../../example").standardizedFileURL,
        ]
        if let example = exampleFolders.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            openFolder(example)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openDroppedURL(_ url: URL) {
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
        scanTask?.cancel()
        imageTask?.cancel()
        scaleRenderTask?.cancel()
        folder = url
        UserDefaults.standard.set(url.path, forKey: Defaults.lastFolder)
        isLoading = true
        status = "Scanning folder..."
        files.removeAll()
        spectra.removeAll()
        spectrumGroupsByFileID.removeAll()
        spectrumParentIDBySpectrumID.removeAll()
        hiddenSpectrumIDs.removeAll()
        sidebarSelectedSpectrumIDs.removeAll()
        manuallyAssignedSXMIDBySpectrumID.removeAll()
        spectrumDragPayloads.removeAll()
        selection.clear()
        sidebarMode = .all
        activeTagName = nil
        filenameSearch = ""
        selectedImage = nil
        selectedStats = nil
        selectedSpectrumXColumn = ""
        selectedSpectrumYColumn = ""
        processedCacheKey = nil
        processedCacheMatrix = nil
        processedCacheStats = nil
        processedCacheStatsBins = nil
        fullCache.removeAll()
        fullCacheOrder.removeAll()
        thumbnailCache.removeAllObjects()
        cancelThumbnailTasks()
        loadTags(for: url)

        scanTask = Task {
            do {
                let parser = self.parser
                let spectroscopyParser = self.spectroscopyParser
                let scanned = try await Task.detached(priority: .userInitiated) {
                    let sxmFiles = try parser.scanFolder(url)
                    let spectroscopyFiles = (try? spectroscopyParser.scanFolder(url)) ?? []
                    return (sxmFiles, spectroscopyFiles)
                }.value
                guard !Task.isCancelled, folder == url else { return }
                files = scanned.0
                spectra = scanned.1
                rebuildSpectrumGroups()
                pruneTagsToCurrentFiles()
                if let selectedPath,
                   let droppedFile = files.first(where: { $0.path.standardizedFileURL == selectedPath.standardizedFileURL }) {
                    selection.selectOnly(droppedFile.id, in: visibleFiles.map(\.id))
                    mode = .single
                } else if let firstID = sortedFiles.first?.id {
                    selection.selectOnly(firstID, in: visibleFiles.map(\.id))
                }
                applyDefaultsFromSelection()
                isLoading = false
                let groupCount = spectrumGroupsByFileID.values.reduce(0) { $0 + $1.count }
                status = "Loaded \(scanned.0.count) SXM files and \(scanned.1.count) spectra in \(groupCount) plots."
                if mode == .single {
                    refreshSelectedImage(resetScale: true)
                }
            } catch {
                guard !Task.isCancelled, folder == url else { return }
                isLoading = false
                status = error.localizedDescription
            }
        }
    }

    func select(_ file: SXMMetadata, tagContext: String? = nil) {
        activateTagContextIfNeeded(tagContext)
        updateSelection { state, visibleIDs in
            state.selectOnly(file.id, in: visibleIDs)
        }
    }

    func select(
        _ file: SXMMetadata,
        modifiers: NSEvent.ModifierFlags,
        tagContext: String? = nil
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

    func stepSelection(_ delta: Int, switchToSingle: Bool = true) {
        let list = visibleFiles
        guard !list.isEmpty else { return }
        let current = selectedFile.flatMap { selected in list.firstIndex { $0.id == selected.id } } ?? 0
        let next = min(list.count - 1, max(0, current + delta))
        select(list[next])
        if switchToSingle {
            mode = .single
        }
        status = list[next].filename
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
                stepSelection(-1, switchToSingle: false)
            case .right:
                stepSelection(1, switchToSingle: false)
            case .up:
                stepSelection(-gridColumns, switchToSingle: false)
            case .down:
                stepSelection(gridColumns, switchToSingle: false)
            default:
                break
            }
        }
    }

    func deleteSelectedFiles() {
        deleteFiles(selectedFiles)
    }

    func deleteFilesForContext(
        containing file: SXMMetadata,
        tagContext: String? = nil
    ) {
        deleteFiles(contextFiles(containing: file, tagContext: tagContext))
    }

    func contextFiles(
        containing file: SXMMetadata,
        tagContext: String? = nil
    ) -> [SXMMetadata] {
        let scopedFiles = tagContext.map(visibleFiles(forTag:)) ?? visibleFiles
        return selectedIDs.contains(file.id)
            ? scopedFiles.filter { selectedIDs.contains($0.id) }
            : [file]
    }

    func revealInFinderForContext(
        containing file: SXMMetadata,
        tagContext: String? = nil
    ) {
        let urls = contextFiles(containing: file, tagContext: tagContext).map(\.path)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openFilesForContext(
        containing file: SXMMetadata,
        tagContext: String? = nil
    ) {
        for target in contextFiles(containing: file, tagContext: tagContext) {
            NSWorkspace.shared.open(target.path)
        }
    }

    func addTag(
        _ tag: String,
        toContextContaining file: SXMMetadata,
        tagContext: String? = nil
    ) {
        addTag(tag, to: contextFiles(containing: file, tagContext: tagContext))
    }

    func removableTagsForContext(
        containing file: SXMMetadata,
        tagContext: String? = nil
    ) -> [String] {
        let targetPaths = Set(
            contextFiles(containing: file, tagContext: tagContext)
                .map { fileKey($0.path) }
        )
        guard !targetPaths.isEmpty else { return [] }
        return tagNames.filter { tag in
            guard let taggedPaths = taggedFilePathsByTag[tag] else { return false }
            return !taggedPaths.intersection(targetPaths).isEmpty
        }
    }

    func removeTag(
        _ tag: String,
        fromContextContaining file: SXMMetadata,
        tagContext: String? = nil
    ) {
        removeTag(tag, from: contextFiles(containing: file, tagContext: tagContext))
    }

    func promptForNewTag(
        toContextContaining file: SXMMetadata? = nil,
        tagContext: String? = nil
    ) {
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

        createTag(named: name)
        if let file {
            addTag(name, toContextContaining: file, tagContext: tagContext)
        }
    }

    func toggleTagExpansion(_ tag: String) {
        if expandedTagNames.contains(tag) {
            expandedTagNames.remove(tag)
        } else {
            expandedTagNames.insert(tag)
        }
        saveTags()
    }

    func selectTag(_ tag: String) {
        sidebarMode = .tag
        activeTagName = tag
        expandedTagNames.insert(tag)
        saveTags()

        let tagFiles = files(forTag: tag)
        updateSelection { state, visibleIDs in
            state.reconcile(with: visibleIDs, fallbackToFirst: true)
        }
        status = "Showing \(tagFiles.count) files in \(tag)."
    }

    private func deleteFiles(_ targets: [SXMMetadata]) {
        guard !targets.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Delete this SXM file?" : "Delete \(targets.count) SXM files?"
        alert.informativeText = "The original file\(targets.count == 1 ? "" : "s") will be moved to the system Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var trashedIDs: Set<SXMMetadata.ID> = []
        var failedNames: [String] = []
        for file in targets {
            do {
                try FileManager.default.trashItem(at: file.path, resultingItemURL: nil)
                trashedIDs.insert(file.id)
                removeCachedData(for: file.path)
            } catch {
                failedNames.append(file.filename)
            }
        }

        guard !trashedIDs.isEmpty else {
            status = failedNames.isEmpty ? "No files deleted." : "Could not delete \(failedNames.count) files."
            return
        }

        let oldVisibleIDs = visibleFiles.map(\.id)
        files.removeAll { trashedIDs.contains($0.id) }
        removeTags(forDeletedFiles: targets.filter { trashedIDs.contains($0.id) })
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
        processedCacheKey = nil
        processedCacheMatrix = nil
        processedCacheStats = nil
        processedCacheStatsBins = nil
        syncSpectrumAxesWithSelection()
    }

    func syncSpectrumAxesWithSelection(preferredSpectrum: SpectroscopyFile? = nil) {
        let columns = selectedSpectrumColumns
        guard !columns.isEmpty else {
            selectedSpectrumXColumn = ""
            selectedSpectrumYColumn = ""
            return
        }

        let fallbackSpectrum = preferredSpectrum ?? selectedFile.flatMap { spectra(for: $0).first }
        let fallbackX = fallbackSpectrum?.xLabel ?? columns[0]
        let fallbackY = fallbackSpectrum?.yLabel ?? columns[min(1, columns.count - 1)]

        if !columns.contains(selectedSpectrumXColumn) {
            selectedSpectrumXColumn = columns.contains(fallbackX) ? fallbackX : columns[0]
        }
        if !columns.contains(selectedSpectrumYColumn) {
            selectedSpectrumYColumn = columns.contains(fallbackY) ? fallbackY : columns[min(1, columns.count - 1)]
        }
    }

    func setMode(_ newMode: BrowserMode) {
        mode = newMode
        if newMode == .single {
            refreshSelectedImage(resetScale: false)
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
        group.availableColumns.contains(selectedSpectrumXColumn) ? selectedSpectrumXColumn : group.xLabel
    }

    func spectrumYAxis(for group: SpectroscopyGroup) -> String {
        group.availableColumns.contains(selectedSpectrumYColumn) ? selectedSpectrumYColumn : group.yLabel
    }

    func spectrumAxisChanged() {
        status = "Using \(selectedSpectrumXColumn) vs \(selectedSpectrumYColumn)."
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
        if visible {
            hiddenSpectrumIDs.remove(spectrum.id)
        } else {
            hiddenSpectrumIDs.insert(spectrum.id)
        }
        if let parentID = spectrumParentIDBySpectrumID[spectrum.id] {
            rebuildSpectrumGroups(for: [parentID])
        } else {
            rebuildSpectrumGroups()
        }
        status = visible ? "Showing \(spectrum.filename)." : "Hidden \(spectrum.filename)."
    }

    func selectSpectrumRow(
        _ spectrum: SpectroscopyFile,
        modifiers: NSEvent.ModifierFlags,
        tagContext: String? = nil
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
            syncSpectrumAxesWithSelection(preferredSpectrum: spectrum)
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

    func assignSpectra(
        fromDragToken token: String,
        to file: SXMMetadata,
        tagContext: String? = nil
    ) -> Bool {
        guard let ids = spectrumDragPayloads.removeValue(forKey: token), !ids.isEmpty else {
            return false
        }
        activateTagContextIfNeeded(tagContext)
        let oldParentIDs = Set(ids.compactMap { spectrumParentIDBySpectrumID[$0] })
        for id in ids {
            manuallyAssignedSXMIDBySpectrumID[id] = file.id
            spectrumParentIDBySpectrumID[id] = file.id
        }
        hiddenSpectrumIDs.subtract(ids)
        sidebarSelectedSpectrumIDs = Set(ids)
        updateSelection { state, visibleIDs in
            state.selectOnly(file.id, in: visibleIDs)
        }
        rebuildSpectrumGroups(for: oldParentIDs.union([file.id]))
        syncSpectrumAxesWithSelection()
        status = "Moved \(ids.count) spectrum file\(ids.count == 1 ? "" : "s") to \(file.filename)."
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
            imageTask?.cancel()
            selectedImage = nil
            selectedStats = nil
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
            imageTask?.cancel()
            selectedImage = nil
            selectedStats = nil
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
            return await existing.value
        }

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
        thumbnailTasks[key] = task
        let image = await task.value
        thumbnailTasks.removeValue(forKey: key)
        return image
    }

    func refreshSelectedImage(resetScale: Bool) {
        imageTask?.cancel()
        guard let file = selectedFile, !selectedChannel.isEmpty else {
            selectedImage = nil
            selectedStats = nil
            return
        }
        selectedImage = nil
        status = "Rendering \(file.filename)..."
        if resetScale {
            scaleLocked = false
            scaleMin = nil
            scaleMax = nil
        }

        let channel = selectedChannel
        let direction = selectedDirection
        let processing = selectedProcessing
        let palette = selectedPalette
        let invert = invertPalette
        let locked = scaleLocked
        let manualMin = scaleMin
        let manualMax = scaleMax
        let bins = histogramBins
        let cacheKey = processedKey(file: file, channel: channel, direction: direction, processing: processing)

        imageTask = Task {
            do {
                let processed: Matrix
                if processedCacheKey == cacheKey,
                   let cachedMatrix = processedCacheMatrix {
                    processed = cachedMatrix
                } else {
                    let full = try await fullFile(for: file)
                    guard let matrix = full.matrices[MatrixKey(channel: channel, direction: direction)] else {
                        status = "Direction is not available for this channel."
                        return
                    }
                    processed = await Task.detached(priority: .userInitiated) {
                        SXMRenderer.processedMatrix(matrix, processing: processing)
                    }.value
                }
                let stats: HistogramStats?
                if processedCacheKey == cacheKey,
                   processedCacheStatsBins == bins,
                   let cachedStats = processedCacheStats {
                    stats = cachedStats
                } else {
                    stats = await Task.detached(priority: .userInitiated) {
                        SXMRenderer.histogram(processed, bins: bins)
                    }.value
                }
                let autoScale = SXMRenderer.automaticScale(processed)
                let renderMin = locked ? manualMin : autoScale?.vmin
                let renderMax = locked ? manualMax : autoScale?.vmax
                let options = RenderOptions(
                    channel: channel,
                    direction: direction,
                    processing: processing,
                    palette: palette,
                    vmin: renderMin,
                    vmax: renderMax,
                    invert: invert
                )
                let image = try await Task.detached(priority: .userInitiated) {
                    try SXMRenderer.renderProcessedImage(matrix: processed, options: options)
                }.value
                if Task.isCancelled { return }
                processedCacheKey = cacheKey
                processedCacheMatrix = processed
                processedCacheStats = stats
                processedCacheStatsBins = bins
                selectedStats = stats
                if !locked {
                    scaleMin = autoScale?.vmin
                    scaleMax = autoScale?.vmax
                }
                selectedImage = image
                status = file.filename
            } catch {
                status = error.localizedDescription
            }
        }
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
                let full = try await fullFile(for: file)
                guard let matrix = full.matrices[MatrixKey(channel: channel, direction: direction)] else { return }
                let options = RenderOptions(
                    channel: channel,
                    direction: direction,
                    processing: processing,
                    palette: palette,
                    vmin: vmin,
                    vmax: vmax,
                    invert: invert
                )
                let data = try await Task.detached(priority: .userInitiated) {
                    try SXMRenderer.pngData(matrix: matrix, options: options)
                }.value
                try data.write(to: destination)
                status = "Exported \(destination.lastPathComponent)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func fullFile(for metadata: SXMMetadata) async throws -> SXMFullFile {
        if let cached = fullCache[metadata.path] {
            touchCache(metadata.path)
            return cached
        }
        let parser = self.parser
        let full = try await Task.detached(priority: .userInitiated) {
            try parser.loadFullFile(metadata)
        }.value
        fullCache[metadata.path] = full
        fullCacheOrder.append(metadata.path)
        while fullCacheOrder.count > fullCacheLimit {
            let old = fullCacheOrder.removeFirst()
            fullCache.removeValue(forKey: old)
        }
        return full
    }

    private func touchCache(_ url: URL) {
        fullCacheOrder.removeAll { $0 == url }
        fullCacheOrder.append(url)
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
            selectedSpectrumXColumn = ""
            selectedSpectrumYColumn = ""
            status = "No file selected."
            return
        }

        applyDefaultsFromSelection()
        if mode == .single {
            refreshSelectedImage(resetScale: resetScale)
        }
    }

    private func clearSelectedRender() {
        imageTask?.cancel()
        scaleRenderTask?.cancel()
        selectedImage = nil
        selectedStats = nil
    }

    private func activateTagContextIfNeeded(_ tag: String?) {
        guard let tag, tagNames.contains(tag) else { return }
        sidebarMode = .tag
        activeTagName = tag
        expandedTagNames.insert(tag)
        saveTags()
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
        fullCache.removeValue(forKey: url)
        fullCacheOrder.removeAll { $0 == url }
        processedCacheKey = nil
        processedCacheMatrix = nil
        processedCacheStats = nil
        processedCacheStatsBins = nil
        thumbnailCache.removeAllObjects()
        cancelThumbnailTasks()
    }

    private func ensureSelectionIsVisible() {
        updateSelection { state, visibleIDs in
            state.reconcile(with: visibleIDs, fallbackToFirst: true)
        }
    }

    private func createTag(named rawName: String) {
        let name = normalizedTagName(rawName)
        guard !name.isEmpty else { return }
        if !tagNames.contains(name) {
            tagNames.append(name)
            var updatedTags = taggedFilePathsByTag
            updatedTags[name] = updatedTags[name] ?? []
            taggedFilePathsByTag = updatedTags
        }
        expandedTagNames.insert(name)
        saveTags()
        status = "Created tag \(name)."
    }

    private func addTag(_ rawName: String, to targetFiles: [SXMMetadata]) {
        let name = normalizedTagName(rawName)
        guard !name.isEmpty else { return }
        createTag(named: name)
        var paths = taggedFilePathsByTag[name] ?? []
        for file in targetFiles {
            paths.insert(fileKey(file.path))
        }
        var updatedTags = taggedFilePathsByTag
        updatedTags[name] = paths
        taggedFilePathsByTag = updatedTags
        expandedTagNames.insert(name)
        saveTags()
        if targetFiles.isEmpty {
            status = "Created tag \(name)."
        } else {
            status = "Added \(targetFiles.count) file\(targetFiles.count == 1 ? "" : "s") to \(name)."
        }
    }

    private func removeTag(_ tag: String, from targetFiles: [SXMMetadata]) {
        guard !targetFiles.isEmpty else { return }
        let pathsToRemove = Set(targetFiles.map { fileKey($0.path) })
        guard var taggedPaths = taggedFilePathsByTag[tag] else { return }

        let beforeCount = taggedPaths.count
        taggedPaths.subtract(pathsToRemove)
        var updatedTags = taggedFilePathsByTag
        updatedTags[tag] = taggedPaths
        taggedFilePathsByTag = updatedTags
        saveTags()

        let removedCount = beforeCount - taggedPaths.count
        if activeTagName == tag {
            ensureSelectionIsVisible()
        }

        status = removedCount == 1 ? "Removed 1 file from \(tag)." : "Removed \(removedCount) files from \(tag)."
    }

    private func removeTags(forDeletedFiles deletedFiles: [SXMMetadata]) {
        guard !deletedFiles.isEmpty else { return }
        let deletedPaths = Set(deletedFiles.map { fileKey($0.path) })
        var updatedTags = taggedFilePathsByTag
        for tag in tagNames {
            updatedTags[tag]?.subtract(deletedPaths)
        }
        taggedFilePathsByTag = updatedTags
        saveTags()
    }

    private func pruneTagsToCurrentFiles() {
        let validPaths = Set(files.map { fileKey($0.path) })
        var updatedTags = taggedFilePathsByTag
        for tag in tagNames {
            updatedTags[tag] = updatedTags[tag, default: []].intersection(validPaths)
        }
        taggedFilePathsByTag = updatedTags
        saveTags()
    }

    private func rebuildSpectrumGroups() {
        let associated = associateSpectra(spectra, with: files)
        spectrumParentIDBySpectrumID = associated.parents
        spectrumGroupsByFileID = associated.groups
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
            let buckets = Dictionary(grouping: visibleSpectra, by: \.kind)
            let groups = buckets
                .map { SpectroscopyGroup(sxm: file, kind: $0.key, spectra: $0.value) }
                .sorted { lhs, rhs in
                    spectroscopyKindSortRank(lhs.kind) < spectroscopyKindSortRank(rhs.kind)
                }
            if groups.isEmpty {
                updatedGroups.removeValue(forKey: parentID)
            } else {
                updatedGroups[parentID] = groups
            }
        }
        spectrumGroupsByFileID = updatedGroups
    }

    private func associateSpectra(_ spectra: [SpectroscopyFile], with sxmFiles: [SXMMetadata]) -> (groups: [SXMMetadata.ID: [SpectroscopyGroup]], parents: [SpectroscopyFile.ID: SXMMetadata.ID]) {
        let sxmByTime = sxmFiles.sorted { lhs, rhs in
            if lhs.modifiedTime == rhs.modifiedTime {
                return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
            }
            return lhs.modifiedTime < rhs.modifiedTime
        }
        let sxmByName = sxmFiles.sorted {
            sxmBasename($0).count > sxmBasename($1).count
        }
        guard !sxmByTime.isEmpty else { return ([:], [:]) }

        var buckets: [SXMMetadata.ID: [SpectroscopyKind: [SpectroscopyFile]]] = [:]
        var parents: [SpectroscopyFile.ID: SXMMetadata.ID] = [:]
        for spectrum in spectra.sorted(by: { lhs, rhs in
            lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }) {
            let parent = manuallyAssignedSXMIDBySpectrumID[spectrum.id].flatMap { id in sxmFiles.first { $0.id == id } }
                ?? sxmMatchingFilename(for: spectrum, in: sxmByName)
                ?? sxmByTime.last(where: { $0.modifiedTime <= spectrum.modifiedTime })
                ?? nearestSXM(to: spectrum, in: sxmByTime)
            guard let parent else { continue }
            parents[spectrum.id] = parent.id
            if !hiddenSpectrumIDs.contains(spectrum.id) {
                buckets[parent.id, default: [:]][spectrum.kind, default: []].append(spectrum)
            }
        }

        var output: [SXMMetadata.ID: [SpectroscopyGroup]] = [:]
        for file in sxmFiles {
            guard let kindBuckets = buckets[file.id] else { continue }
            output[file.id] = kindBuckets
                .map { SpectroscopyGroup(sxm: file, kind: $0.key, spectra: $0.value) }
                .sorted { lhs, rhs in
                    spectroscopyKindSortRank(lhs.kind) < spectroscopyKindSortRank(rhs.kind)
                }
        }
        return (output, parents)
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

    private func spectroscopyKindSortRank(_ kind: SpectroscopyKind) -> Int {
        switch kind {
        case .z: 0
        case .bias: 1
        case .other: 2
        }
    }

    private func nearestSXM(to spectrum: SpectroscopyFile, in sxmFiles: [SXMMetadata]) -> SXMMetadata? {
        sxmFiles.min { lhs, rhs in
            abs(lhs.modifiedTime.timeIntervalSince(spectrum.modifiedTime)) < abs(rhs.modifiedTime.timeIntervalSince(spectrum.modifiedTime))
        }
    }

    private func loadTags(for folder: URL) {
        guard let data = UserDefaults.standard.data(forKey: tagsDefaultsKey(for: folder)),
              let store = try? JSONDecoder().decode(TagStore.self, from: data) else {
            tagNames = []
            taggedFilePathsByTag = [:]
            expandedTagNames = []
            return
        }

        tagNames = store.tagNames
        taggedFilePathsByTag = store.taggedFilePathsByTag.mapValues { Set($0) }
        expandedTagNames = Set(store.expandedTagNames)
    }

    private func saveTags() {
        guard let folder else { return }
        let store = TagStore(
            tagNames: tagNames,
            taggedFilePathsByTag: taggedFilePathsByTag.mapValues { Array($0).sorted() },
            expandedTagNames: Array(expandedTagNames).sorted()
        )
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: tagsDefaultsKey(for: folder))
    }

    private func normalizedTagName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fileKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func tagsDefaultsKey(for folder: URL) -> String {
        let encoded = Data(folder.standardizedFileURL.path.utf8).base64EncodedString()
        return "\(Defaults.tagsByFolder).\(encoded)"
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
            let full = try await fullFile(for: file)
            if Task.isCancelled { return nil }
            guard let matrix = full.matrices[MatrixKey(channel: channel, direction: direction)] else { return nil }
            let options = RenderOptions(
                channel: channel,
                direction: direction,
                processing: processing,
                palette: palette,
                outputSize: 260,
                invert: invert
            )
            let image = try await Task.detached(priority: .utility) {
                try SXMRenderer.renderImage(matrix: matrix, options: options)
            }.value
            if Task.isCancelled { return nil }
            thumbnailCache.setObject(image, forKey: cacheKey as NSString, cost: estimatedImageCost(image))
            return image
        } catch {
            return nil
        }
    }

    private func cancelThumbnailTasks() {
        for task in thumbnailTasks.values {
            task.cancel()
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

    private func processedKey(
        file: SXMMetadata,
        channel: String,
        direction: ScanDirection,
        processing: ProcessingMode
    ) -> String {
        "\(file.path.path)|\(channel)|\(direction.rawValue)|\(processing.rawValue)"
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
        static let tagsByFolder = "native.tagsByFolder"
    }

    private struct TagStore: Codable {
        let tagNames: [String]
        let taggedFilePathsByTag: [String: [String]]
        let expandedTagNames: [String]
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
