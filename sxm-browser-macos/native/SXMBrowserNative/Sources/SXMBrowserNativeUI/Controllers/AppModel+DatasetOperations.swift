import AppKit
import Foundation
import SXMBrowserAppCore
import SXMBrowserCore

extension AppModel {
    public func openStartupFolder() {
        cancelStartupLookup()
        let requestID = UUID()
        startupRequestID = requestID
        startupTask = Task { [weak self] in
            guard let self else { return }
            await restoreStartupFolder(requestID: requestID)
        }
    }

    public func chooseFolder() {
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

    public func retryCurrentFolder() {
        guard let folder else {
            chooseFolder()
            return
        }
        openFolder(folder, selecting: selectedFile?.path)
    }

    public func retrySelectedRender() {
        guard mode == .single, selectedFile != nil else {
            return
        }
        refreshSelectedImage(resetScale: false)
    }

    public func revealSelectedFileInFinder() {
        guard let path = selectedFile?.path else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }

    public func revealSelectedFilesInFinder() {
        let paths = selectedFiles.map(\.path)
        guard !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths)
    }

    public func addTagToSelection(_ tagID: UUID) {
        addTag(tagID, to: selectedFiles)
    }

    public func removeTagFromSelection(_ tagID: UUID) {
        removeTag(tagID, from: selectedFiles)
    }

    public func removableTagsForSelection() -> [DatasetTagV1] {
        guard let session = activeDatasetSession else { return [] }
        let selectedPaths = Set(
            selectedFiles.compactMap {
                session.pathIndex.sxmPath(for: $0.id)
            }
        )
        guard !selectedPaths.isEmpty else { return [] }
        return tags.filter {
            !Set($0.sxmPaths).intersection(selectedPaths).isEmpty
        }
    }

    public func promptForNewTagForSelection() {
        guard let first = selectedFiles.first else { return }
        promptForNewTag(
            toContextContaining: first,
            tagContext: sidebarMode == .tag ? activeTagID : nil
        )
    }

    public func dismissNoticeBanner(id: UUID) {
        var next = noticePresentation
        guard next.dismissBanner(id: id) else { return }
        noticePresentation = next
        if renderFailureNoticeID == id {
            renderFailureNoticeID = nil
        }
    }

    public func dismissNoticeToast(id: UUID) {
        var next = noticePresentation
        guard next.dismissToast(id: id) else { return }
        noticePresentation = next
        toastDismissTask?.cancel()
        toastDismissTask = nil
    }

    public func performNoticeAction(_ action: NoticeAction) {
        switch action {
        case .retryFolder:
            retryCurrentFolder()
        case .retryRender:
            retrySelectedRender()
        case .showInFinder:
            revealSelectedFileInFinder()
        case .showScanIssues:
            showScanIssues()
        case .showMetadataDetails:
            showMetadataWarningDetails()
        }
    }


    public func dismissMetadataWarning() {
        var next = metadataWarnings
        next.dismiss()
        metadataWarnings = next
    }

    public func retryMetadataWarning() {
        guard canRetryMetadataWarning,
              let folderURL = folder else {
            return
        }
        let selectedPath = selectedFile?.path
        status = "Retrying metadata setup..."
        openFolder(folderURL, selecting: selectedPath)
    }

    public func showMetadataWarningDetails() {
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

    public func showScanIssues() {
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

    public func openDroppedURL(_ url: URL) {
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

    public func openFolder(_ url: URL, selecting selectedPath: URL? = nil) {
        guard canOpenFolder else {
            status =
                "Wait for the metadata import to finish before "
                + "opening another folder."
            return
        }
        cancelStartupLookup()
        beginOpeningFolder(url, selecting: selectedPath)
    }

    internal func beginOpeningFolder(
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
        clearUserNotices()

        let sessionID = datasetSessionGate.begin()
        dataset.currentSessionID = sessionID
        activeDeleteOperationID = nil
        dataset.isDeletingFiles = false
        renderCoordinator.beginDataset(revision: sessionID)
        viewer.clearFrequencyShiftBoundsCache()
        let openedURL = url.standardizedFileURL
        if openedURL.startAccessingSecurityScopedResource() {
            securityScopedFolderURL = openedURL
        }

        folder = openedURL
        UserDefaults.standard.set(
            openedURL.path,
            forKey: BrowserDefaults.lastFolder
        )
        datasetLoadState = .loading
        selectedRenderState = .idle
        status = "Scanning folder..."
        resetMetadataWarnings(to: initialMetadataWarnings)
        activeDatasetSession = nil
        tags = []
        activeTagID = nil
        expandedTagIDs = []
        files.removeAll()
        spectra.removeAll()
        scanIssues.removeAll()
        spectroscopy.resetForNewFolder()
        selection.clear()
        viewerTransform = ViewerTransform()
        sidebarMode = .all
        clearFilenameSearch()
        reconcileSingleSpectroscopyState()
        datasetInventoryRevisionID = nil
        thumbnails.invalidateAll()

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
                reconcileSingleSpectroscopyState()
                applyDefaultsFromSelection()
                datasetLoadState = .ready
                let groupCount = spectrumGroupsByFileID.values.reduce(0) { $0 + $1.count }
                let axisIssueText =
                    presentedSpectrumAxisRestoreIssues.isEmpty
                    ? ""
                    : " Axis preference issues: "
                        + "\(presentedSpectrumAxisRestoreIssues.count)."
                status = "Loaded \(scanned.0.items.count) SXM files and \(scanned.1.items.count) spectra in \(groupCount) groups. Scan issues: \(scanIssues.count).\(axisIssueText)"
                let loadedSummary =
                    "\(scanned.0.items.count) SXM files, "
                    + "\(scanned.1.items.count) spectra, "
                    + "\(groupCount) spectrum groups."
                if !scanIssues.isEmpty
                    || !presentedSpectrumAxisRestoreIssues.isEmpty {
                    var issueLabels: [String] = []
                    if !scanIssues.isEmpty {
                        issueLabels.append(
                            "\(scanIssues.count) scan issue"
                                + (scanIssues.count == 1 ? "" : "s")
                        )
                    }
                    if !presentedSpectrumAxisRestoreIssues.isEmpty {
                        issueLabels.append(
                            "\(presentedSpectrumAxisRestoreIssues.count) "
                                + "axis preference issue"
                                + (
                                    presentedSpectrumAxisRestoreIssues.count
                                        == 1
                                    ? ""
                                    : "s"
                                )
                        )
                    }
                    var actions: [NoticeAction] = []
                    if !scanIssues.isEmpty {
                        actions.append(.showScanIssues)
                    }
                    if shouldPresentMetadataWarning {
                        actions.append(.showMetadataDetails)
                    }
                    _ = presentBanner(
                        title: "Some files need attention",
                        message:
                            "\(loadedSummary) "
                            + issueLabels.joined(separator: " and ")
                            + " need attention.",
                        severity: .warning,
                        actions: actions
                    )
                } else if !scanned.0.items.isEmpty {
                    presentToast(
                        title: "Folder loaded",
                        message: loadedSummary
                    )
                }
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
                let message = error.localizedDescription
                datasetLoadState = .failed(message: message)
                status = message
                _ = presentBanner(
                    title: "Folder could not be opened",
                    message: message,
                    severity: .error,
                    actions: [.retryFolder]
                )
            }
        }
    }

    internal func prepareDatasetMetadata(
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

    internal func restoreStartupFolder(requestID: UUID) async {
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
            forKey: BrowserDefaults.lastFolder
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

    internal func openStartupFolderCandidate(
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

    internal func startupRequestIsCurrent(_ requestID: UUID) -> Bool {
        !Task.isCancelled && startupRequestID == requestID
    }

    internal func cancelStartupLookup() {
        startupTask?.cancel()
        startupTask = nil
        startupRequestID = nil
    }

    internal func createFolderBookmark(
        for folderURL: URL
    ) async throws -> Data? {
        let bookmarker = folderBookmarker
        return try await runDetachedCancellable(priority: .utility) {
            try bookmarker.createBookmark(for: folderURL)
        }
    }

    internal func resolveFolderBookmark(
        _ bookmark: Data
    ) async throws -> FolderBookmarkResolution? {
        let bookmarker = folderBookmarker
        return try await runDetachedCancellable(priority: .utility) {
            try bookmarker.resolveBookmark(bookmark)
        }
    }

    internal func existingDirectory(at url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }
        return url.standardizedFileURL
    }

    internal func existingSecurityScopedDirectory(
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

    internal func firstAvailableExampleFolder() -> URL? {
        let appParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let workspaceParent = appParent.deletingLastPathComponent()
        let cwd = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let baseDirectories = [
            workspaceParent,
            appParent,
            cwd,
            cwd.appendingPathComponent("..").standardizedFileURL,
            cwd.appendingPathComponent("../..").standardizedFileURL,
            cwd.appendingPathComponent("../../..").standardizedFileURL,
        ]
        let relativeCandidates = [
            "examples/example-graph",
            "examples",
            "example-graph",
            "example",
        ]
        let candidates = baseDirectories.flatMap { base in
            relativeCandidates.map { base.appendingPathComponent($0).standardizedFileURL }
        }
        return candidates.lazy.compactMap(existingDirectory(at:)).first
    }

    internal func stopSecurityScopedFolderAccess() {
        guard let securityScopedFolderURL else { return }
        securityScopedFolderURL.stopAccessingSecurityScopedResource()
        self.securityScopedFolderURL = nil
    }

    @discardableResult
    internal func presentBanner(
        title: String,
        message: String,
        severity: NoticeSeverity,
        actions: [NoticeAction] = []
    ) -> UUID {
        let notice = UserNotice(
            title: title,
            message: message,
            severity: severity,
            actions: actions
        )
        var next = noticePresentation
        next.presentBanner(notice)
        noticePresentation = next
        return notice.id
    }

    internal func presentToast(
        title: String,
        message: String
    ) {
        toastDismissTask?.cancel()
        let notice = UserNotice(
            title: title,
            message: message,
            severity: .success
        )
        var next = noticePresentation
        next.presentToast(notice)
        noticePresentation = next

        toastDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self else { return }
            var current = self.noticePresentation
            guard current.dismissToast(id: notice.id) else { return }
            self.noticePresentation = current
            self.toastDismissTask = nil
        }
    }

    internal func clearRenderFailureNotice() {
        guard let renderFailureNoticeID else { return }
        var next = noticePresentation
        if next.dismissBanner(id: renderFailureNoticeID) {
            noticePresentation = next
        }
        self.renderFailureNoticeID = nil
    }

    internal func clearUserNotices() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        renderFailureNoticeID = nil
        var next = noticePresentation
        next.clear()
        noticePresentation = next
    }

    internal func resetMetadataWarnings(
        to collection: MetadataWarningCollection =
            MetadataWarningCollection()
    ) {
        metadataWarnings = MetadataWarningPresentationState(
            collection: collection
        )
    }

    internal func mergeMetadataWarnings(
        _ collection: MetadataWarningCollection
    ) {
        var next = metadataWarnings
        for message in collection.messages {
            _ = next.append(message)
        }
        metadataWarnings = next
    }

    internal func appendMetadataWarning(_ message: String?) {
        var next = metadataWarnings
        guard next.append(message) else { return }
        metadataWarnings = next
    }

}
