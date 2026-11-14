import AppKit
import Foundation
import SXMBrowserAppCore
import SXMBrowserCore

extension AppModel {
    public func select(_ file: SXMMetadata, tagContext: UUID? = nil) {
        activateTagContextIfNeeded(tagContext)
        updateSelection { state, visibleIDs in
            state.selectOnly(file.id, in: visibleIDs)
        }
    }

    public func select(
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

    public func selectAll() {
        if let textResponder = NSApp.keyWindow?.firstResponder as? NSText {
            textResponder.selectAll(nil)
            return
        }
        guard !visibleFiles.isEmpty else { return }
        updateSelection { state, visibleIDs in
            state.selectAll(in: visibleIDs)
        }
        status = "Selected \(selectedIDs.count) files."
    }

    public func jumpToFilenameSearch() {
        commitFilenameSearch()
        let query = appliedFilenameSearch.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return }

        let list = visibleFiles
        guard !list.isEmpty else { return }
        let currentIndex = selectedFile.flatMap { selected in
            list.firstIndex { $0.id == selected.id }
        } ?? -1
        let orderedIndices = Array((currentIndex + 1)..<list.count) + Array(0...max(currentIndex, 0))

        guard let matchIndex = orderedIndices.first else {
            status = "No file matching \"\(query)\"."
            return
        }

        select(list[matchIndex])
        status = "Selected \(list[matchIndex].filename)"
    }

    public func canStepSelection(by delta: Int) -> Bool {
        selection.canStep(by: delta, in: visibleFiles.map(\.id))
    }

    public func stepSelection(
        _ delta: Int,
        extendingSelection: Bool = false
    ) {
        let list = visibleFiles
        guard canStepSelection(by: delta) else { return }
        updateSelection { state, visibleIDs in
            if extendingSelection {
                state.extend(by: delta, in: visibleIDs)
            } else {
                state.step(by: delta, in: visibleIDs)
            }
        }
        if let selectedID,
           let selected = list.first(where: { $0.id == selectedID }) {
            status = selected.filename
        }
    }

    public func moveSelectionForArrow(
        _ direction: GridNavigationDirection,
        extendingSelection: Bool = false
    ) {
        switch mode {
        case .single:
            if direction == .left {
                stepSelection(
                    -1,
                    extendingSelection: extendingSelection
                )
            } else if direction == .right {
                stepSelection(
                    1,
                    extendingSelection: extendingSelection
                )
            }
        case .grid:
            let itemFileIDs: [SXMMetadata.ID?] = visibleDisplayItems.map { item in
                switch item {
                case .sxm(let file):
                    return file.id
                case .spectroscopy:
                    return nil
                }
            }
            guard let targetID = AdaptiveGridNavigation.targetFileID(
                from: selectedID,
                direction: direction,
                columnCount: gridNavigationColumnCount,
                itemFileIDs: itemFileIDs
            ) else {
                return
            }
            updateSelection { state, visibleIDs in
                if extendingSelection {
                    state.selectRange(to: targetID, in: visibleIDs)
                } else {
                    state.selectOnly(targetID, in: visibleIDs)
                }
            }
            if let selectedID,
               let selected = visibleFiles.first(where: { $0.id == selectedID }) {
                status = selected.filename
            }
        }
    }

    public func deleteSelectedFiles() {
        let targets = selectedFiles
        Task {
            await performDeleteFiles(targets)
        }
    }

    public func deleteFilesForContext(
        containing file: SXMMetadata,
        tagContext: UUID? = nil
    ) {
        let targets = contextFiles(containing: file, tagContext: tagContext)
        Task {
            await performDeleteFiles(targets)
        }
    }

    public func canDeleteFilesForContext(
        containing file: SXMMetadata,
        tagContext: UUID? = nil
    ) -> Bool {
        !isMetadataBusy
            && !contextFiles(
                containing: file,
                tagContext: tagContext
            ).isEmpty
    }

    public func contextFiles(
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

    public func revealInFinderForContext(
        containing file: SXMMetadata,
        tagContext: UUID? = nil
    ) {
        let urls = contextFiles(containing: file, tagContext: tagContext).map(\.path)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    public func openFilesForContext(
        containing file: SXMMetadata,
        tagContext: UUID? = nil
    ) {
        requestFilenameSearchBlur()
        select(file, tagContext: tagContext)
        setMode(.single)
    }

    public func addTag(
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

    public func removableTagsForContext(
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

    public func removeTag(
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

    public func promptForNewTag(
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

    public func promptToRenameTag(_ tagID: UUID) {
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

    public func renameTag(id tagID: UUID, to name: String) {
        guard activeDatasetSession != nil,
              tags.contains(where: { $0.id == tagID }) else {
            status = metadataUnavailableForTagChangesMessage
            return
        }
        performTagMutation(successMessage: "Tag renamed.") { record in
            try record.renameTag(id: tagID, to: name)
        }
    }

    public func deleteTag(id tagID: UUID) {
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

    public func sortTagsByName() {
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

    public func moveTag(sourceID: UUID, toTargetID targetID: UUID) {
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

    public func moveTag(
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

    public func toggleTagExpansion(_ tagID: UUID) {
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

    public func selectTag(_ tagID: UUID) {
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

    public func performDeleteFiles(_ targets: [SXMMetadata]) async {
        guard !targets.isEmpty else { return }
        guard !isMetadataBusy else {
            status = "Wait for the current metadata operation before deleting files."
            return
        }

        guard confirmDeletion(targets) else { return }
        guard !isMetadataBusy else {
            status = "Wait for the current metadata operation before deleting files."
            return
        }

        let expectedSessionID = dataset.currentSessionID
        let operationID = UUID()
        activeDeleteOperationID = operationID
        dataset.isDeletingFiles = true
        status = targets.count == 1
            ? "Moving 1 file to Trash..."
            : "Moving \(targets.count) files to Trash..."

        let workItems = targets.map { (id: $0.id, path: $0.path, filename: $0.filename) }
        let trash = trashFile
        let outcome = await Task.detached(priority: .userInitiated) {
            var trashedIDs: Set<SXMMetadata.ID> = []
            var trashedPaths: [URL] = []
            var trashedNames: [String] = []
            var failedNames: [String] = []
            for item in workItems {
                do {
                    try trash(item.path)
                    trashedIDs.insert(item.id)
                    trashedPaths.append(item.path)
                    trashedNames.append(item.filename)
                } catch {
                    failedNames.append(item.filename)
                }
            }
            return (
                trashedIDs: trashedIDs,
                trashedPaths: trashedPaths,
                trashedNames: trashedNames,
                failedNames: failedNames
            )
        }.value

        if activeDeleteOperationID == operationID {
            activeDeleteOperationID = nil
            dataset.isDeletingFiles = false
        }
        guard dataset.currentSessionID == expectedSessionID else {
            return
        }

        for path in outcome.trashedPaths {
            removeCachedData(for: path, clearThumbnails: false)
        }
        if !outcome.trashedIDs.isEmpty {
            thumbnails.invalidateAll()
        }

        guard !outcome.trashedIDs.isEmpty else {
            status = outcome.failedNames.isEmpty
                ? "No files deleted."
                : "Could not delete \(outcome.failedNames.count) files."
            if !outcome.failedNames.isEmpty {
                _ = presentBanner(
                    title: "Files could not be moved to Trash",
                    message:
                        "\(outcome.failedNames.count) file"
                        + (outcome.failedNames.count == 1 ? "" : "s")
                        + " could not be deleted.",
                    severity: .error
                )
                presentDeletionResultAlert([], outcome.failedNames)
            }
            return
        }

        let oldVisibleIDs = visibleFiles.map(\.id)
        files.removeAll { outcome.trashedIDs.contains($0.id) }
        datasetInventoryRevisionID = UUID()
        removeTags(forDeletedFiles: targets.filter { outcome.trashedIDs.contains($0.id) })
        restoreManualSpectrumAssociations()
        rebuildSpectrumGroups()
        var updatedSelection = selection
        updatedSelection.reconcileAfterRemoval(
            removedIDs: outcome.trashedIDs,
            oldVisibleIDs: oldVisibleIDs,
            newVisibleIDs: visibleFiles.map(\.id)
        )
        commitSelection(updatedSelection, resetScale: true)
        if selectedID == nil {
            clearSelectedRender()
        }

        let deletedText = outcome.trashedIDs.count == 1
            ? "Moved 1 file to Trash."
            : "Moved \(outcome.trashedIDs.count) files to Trash."
        status = outcome.failedNames.isEmpty
            ? deletedText
            : "\(deletedText) Could not delete \(outcome.failedNames.count)."
        if outcome.failedNames.isEmpty {
            presentToast(
                title: "Moved to Trash",
                message:
                    "\(outcome.trashedIDs.count) file"
                    + (outcome.trashedIDs.count == 1 ? "" : "s")
            )
        } else {
            _ = presentBanner(
                title: "Some files could not be moved to Trash",
                message:
                    "\(outcome.trashedIDs.count) succeeded; "
                    + "\(outcome.failedNames.count) failed.",
                severity: .warning
            )
            presentDeletionResultAlert(outcome.trashedNames, outcome.failedNames)
        }
    }

    internal func fileListAccessoryView(
        _ text: String,
        lineCount: Int
    ) -> NSView {
        Self.fileListAccessoryView(text, lineCount: lineCount)
    }

    internal static func runDeletionConfirmationAlert(for targets: [SXMMetadata]) -> Bool {
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
        return alert.runModal() == .alertFirstButtonReturn
    }

    internal static func fileListAccessoryView(
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

    internal static func runDeletionResultAlert(
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


    internal func createTag(
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

    internal func addTag(_ tagID: UUID, to targetFiles: [SXMMetadata]) {
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

    internal func removeTag(_ tagID: UUID, from targetFiles: [SXMMetadata]) {
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

    internal func removeTags(forDeletedFiles deletedFiles: [SXMMetadata]) {
        guard !deletedFiles.isEmpty,
              let session = activeDatasetSession else {
            return
        }
        let deletedPaths = Set(deletedFiles.compactMap {
            session.pathIndex.sxmPath(for: $0.id)
        })
        guard !deletedPaths.isEmpty else { return }
        let updatedAt = Date()
        performMetadataMutation(
            unavailableMessage: metadataUnavailableForTagChangesMessage,
            failurePrefix: "Files were deleted, but tag metadata cleanup failed",
            mutation: { record in
                for tag in record.tags {
                    try record.replaceTagMembers(
                        id: tag.id,
                        with: tag.sxmPaths.filter {
                            !deletedPaths.contains($0)
                        }
                    )
                }
                let remainingAssociations = record.manualAssociations.filter {
                    !deletedPaths.contains($0.sxmPath)
                }
                if remainingAssociations != record.manualAssociations {
                    try record.replaceManualAssociations(
                        with: remainingAssociations,
                        updatedAt: updatedAt
                    )
                }
                let remainingAxisPreferences = record.spectrumAxisPreferences.filter {
                    !deletedPaths.contains($0.key.sxmPath)
                }
                if remainingAxisPreferences != record.spectrumAxisPreferences {
                    try record.replaceSpectrumAxisPreferences(
                        with: remainingAxisPreferences,
                        updatedAt: updatedAt
                    )
                }
            },
            onVerified: { [weak self] updatedSession in
                guard let self else { return }
                publishUpdatedTagPresentation(
                    tags: updatedSession.verifiedRecord.tags,
                    expandingTagID: nil,
                    activeTagResolution: .firstAvailable,
                    datasetID: updatedSession.datasetID
                )
                restoreManualSpectrumAssociations()
                rebuildSpectrumGroups()
            }
        )
    }

    internal func performTagMutation(
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

    internal func performMetadataMutation(
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
                    presentToast(
                        title: "Metadata updated",
                        message: successMessage
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard metadataMutationID == mutationID,
                      datasetSessionGate.accepts(identity) else {
                    return
                }
                status = "\(failurePrefix): \(error.localizedDescription)"
                _ = presentBanner(
                    title: failurePrefix,
                    message: error.localizedDescription,
                    severity: .error,
                    actions: shouldPresentMetadataWarning
                        ? [.showMetadataDetails]
                        : []
                )
            }
        }
    }

    internal func finishMetadataMutation(id: UUID) {
        guard metadataMutationID == id else { return }
        metadataMutationID = nil
        metadataMutationTask = nil
        isMetadataMutationInFlight = false
    }

    internal func cancelMetadataMutation() {
        metadataMutationID = nil
        metadataMutationTask?.cancel()
        metadataMutationTask = nil
        isMetadataMutationInFlight = false
    }

    internal func publishInitialTagPresentation(
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

    internal func publishUpdatedTagPresentation(
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

    internal func saveExpandedTagIDs(for datasetID: UUID) {
        let values = expandedTagIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
        UserDefaults.standard.set(
            values,
            forKey: expandedTagIDsDefaultsKey(datasetID: datasetID)
        )
    }

    internal func expandedTagIDsDefaultsKey(datasetID: UUID) -> String {
        "\(BrowserDefaults.expandedTagIDsByDataset)."
            + datasetID.uuidString.lowercased()
    }

    internal var metadataUnavailableForTagChangesMessage: String {
        "Tag metadata is unavailable for this folder. Reopen the folder to retry."
    }

    internal var metadataUnavailableForSpectrumChangesMessage: String {
        "Spectrum association metadata is unavailable for this folder. "
            + "Reopen the folder to retry."
    }

    internal var metadataUnavailableForSpectrumVisibilityMessage: String {
        "Spectrum visibility metadata is unavailable for this folder. "
            + "Reopen the folder to retry."
    }

    internal var metadataUnavailableForSpectrumAxesMessage: String {
        "Spectrum axis metadata is unavailable for this folder. "
            + "Reopen the folder to retry."
    }

}
