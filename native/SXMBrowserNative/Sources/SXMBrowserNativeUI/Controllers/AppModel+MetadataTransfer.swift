import AppKit
import Foundation
import SXMBrowserAppCore
import SXMBrowserCore
import UniformTypeIdentifiers

extension AppModel {
    public func exportMetadata() {
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
                presentToast(
                    title: "Metadata exported",
                    message:
                        "\(destination.lastPathComponent) "
                        + "(\(byteCount) bytes)"
                )
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
                _ = presentBanner(
                    title: "Metadata export failed",
                    message: error.localizedDescription,
                    severity: .error
                )
            }
        }
    }

    public func importMetadata() {
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

    public func confirmMetadataImport() {
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
                presentToast(
                    title: "Metadata imported",
                    message: report
                )
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

    public func dismissMetadataImport() {
        guard let workflow = metadataImportWorkflow else { return }
        if case .applying = workflow.phase {
            return
        }
        cancelMetadataTransfer(clearImportWorkflow: true)
    }


    internal func metadataExportFilename(for folderURL: URL) -> String {
        let rawName = folderURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = rawName.isEmpty ? "dataset" : rawName
        return "\(folderName)-sxm-metadata.json"
    }

    @discardableResult
    internal func beginMetadataTransfer(id: UUID = UUID()) -> UUID {
        metadataTransferTask?.cancel()
        metadataTransferID = id
        isMetadataTransferInFlight = true
        return id
    }

    internal func finishMetadataTransfer(id: UUID) {
        guard metadataTransferID == id else { return }
        metadataTransferID = nil
        metadataTransferTask = nil
        isMetadataTransferInFlight = false
    }

    internal func cancelMetadataTransfer(
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

    internal func metadataTransferAccepts(
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

    internal func publishMetadataImportFailure(
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
        _ = presentBanner(
            title: prefix,
            message: error.localizedDescription,
            severity: .error
        )
    }

    internal func makeMetadataImportInventory(
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

    internal func metadataImportCompletionMessage(
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

}
