import AppKit
import Foundation
import SXMBrowserAppCore
import SXMBrowserCore

extension AppModel {
    /// Palette used for previews and thumbnails when the user has not made an
    /// explicit per-image selection. AFM always keeps the neutral gray map.
    public func previewPalette(for channelName: String) -> PaletteName {
        classifyChannel(channelName).usesSTMPalette ? stmPreviewPalette : .gray
    }

    /// Replaces the STM preview palette everywhere: the persisted default,
    /// thumbnails, and the current image when it is an STM channel.
    public func setSTMPreviewPalette(_ palette: PaletteName) {
        stmPreviewPalette = palette
        guard !selectedChannel.isEmpty,
              classifyChannel(selectedChannel).usesSTMPalette else { return }
        selectedPalette = palette
        if mode == .single {
            refreshSelectedImage(resetScale: false)
        } else {
            invalidateActiveRender(clearFrame: false)
        }
    }

    public func applyDefaultsFromSelection() {
        guard let file = selectedFile else { return }
        selectedChannel = file.defaultChannel ?? file.channels.first?.name ?? ""
        let channel = file.channels.first { $0.name == selectedChannel } ?? file.channels.first
        selectedDirection = channel?.directions.first ?? .fwd
        selectedPalette = previewPalette(for: selectedChannel)
        selectedProcessing = defaultProcessing(for: selectedChannel)
        invertPalette = false
        scalePreset = .full
        scaleLocked = false
        scaleMin = nil
        scaleMax = nil
        renderCoordinator.discardProcessedData()
    }

    public func setMode(_ newMode: BrowserMode) {
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
            invalidateActiveRender(clearFrame: false)
        }
    }

    public func toggleGridSpectroscopyCards() {
        setGridSpectroscopyCardsVisible(
            !showsGridSpectroscopyCards
        )
    }

    public func setGridSpectroscopyCardsVisible(_ value: Bool) {
        guard showsGridSpectroscopyCards != value else { return }
        showsGridSpectroscopyCards = value
        status = showsGridSpectroscopyCards
            ? "Spectrum cards visible in Grid."
            : "Spectrum cards hidden in Grid."
    }

    public func setSingleSpectroscopyDrawerExpanded(_ value: Bool) {
        singleSpectroscopyState.setExpanded(value)
        UserDefaults.standard.set(
            singleSpectroscopyState.isExpanded,
            forKey: BrowserDefaults.singleSpectroscopyDrawerExpanded
        )
    }

    public func setSingleSpectroscopyDrawerHeight(_ value: CGFloat) {
        singleSpectroscopyState.setHeight(Double(value))
        UserDefaults.standard.set(
            singleSpectroscopyState.height,
            forKey: BrowserDefaults.singleSpectroscopyDrawerHeight
        )
    }

    public func reconcileViewerGeometry(
        imageSize: CGSize,
        viewportSize: CGSize
    ) {
        if defersViewportGeometry {
            viewer.pendingViewerGeometry = (imageSize, viewportSize)
            return
        }
        var updated = viewerTransform
        updated.reconcile(
            imageSize: ViewerSize(
                width: imageSize.width,
                height: imageSize.height
            ),
            viewportSize: ViewerSize(
                width: viewportSize.width,
                height: viewportSize.height
            )
        )
        guard updated != viewerTransform else { return }
        viewerTransform = updated
    }

    public func fitViewer() {
        guard canAdjustViewerTransform else { return }
        var updated = viewerTransform
        updated.fit()
        guard updated != viewerTransform else { return }
        viewerTransform = updated
    }

    public func showViewerActualSize() {
        setViewerScale(1)
    }

    public func setViewerScale(_ scale: Double) {
        guard canAdjustViewerTransform else { return }
        var updated = viewerTransform
        updated.setCustomScale(
            scale,
            around: updated.viewportSize.center
        )
        guard updated != viewerTransform else { return }
        viewerTransform = updated
    }

    public func zoomViewerIn() {
        guard let scale = nextViewerScale(
            increasing: true
        ) else {
            return
        }
        setViewerScale(scale)
    }

    public func zoomViewerOut() {
        guard let scale = nextViewerScale(
            increasing: false
        ) else {
            return
        }
        setViewerScale(scale)
    }

    public func commitViewerTransform(
        _ proposed: ViewerTransform
    ) {
        guard canAdjustViewerTransform else { return }
        var updated = proposed
        updated.reconcile(
            imageSize: viewerTransform.imageSize,
            viewportSize: viewerTransform.viewportSize
        )
        guard updated != viewerTransform else { return }
        viewerTransform = updated
    }


    public func activateSingleSpectroscopyGroup(_ id: String?) {
        singleSpectroscopyState.activateGroup(id)
        reconcileSingleSpectroscopyState()
    }

    public func focusSingleSpectrum(_ spectrum: SpectroscopyFile) {
        guard let parentID =
            spectrumParentIDBySpectrumID[spectrum.id],
              let parent = files.first(where: {
                  $0.id == parentID
              }) else {
            return
        }
        if selectedID != parentID {
            select(parent)
        }
        guard selectedID == parentID else {
            reconcileSingleSpectroscopyState()
            return
        }

        let groups = presentedSpectrumGroups(for: parent)
        guard let plan = SpectrumFocusPlan.resolve(
            spectrumID: spectrum.id,
            groups: groups
        ) else {
            reconcileSingleSpectroscopyState()
            return
        }
        singleSpectroscopyState.activateGroup(plan.groupID)
        singleSpectroscopyState.focusSpectrum(
            plan.spectrumID
        )
        singleSpectroscopyState.reconcile(with: groups)
    }

    public func spectrumGroups(for file: SXMMetadata) -> [SpectroscopyGroup] {
        spectrumGroupsByFileID[file.id] ?? []
    }

    public func presentedSpectrumGroups(
        for file: SXMMetadata
    ) -> [PresentedSpectroscopyGroup] {
        SpectroscopyPresentationProjection(
            groups: spectrumGroups(for: file),
            hiddenSpectrumIDs: hiddenSpectrumIDs
        ).groups
    }

    public func spectrumXAxis(for group: SpectroscopyGroup) -> String {
        spectrumAxisState.selection(forGroupID: group.id)?.xColumn
            ?? group.canonicalColumn(matching: group.xLabel)
            ?? group.availableColumns.first
            ?? ""
    }

    public func spectrumYAxis(for group: SpectroscopyGroup) -> String {
        spectrumAxisState.selection(forGroupID: group.id)?.yColumn
            ?? group.canonicalColumn(matching: group.yLabel)
            ?? group.availableColumns.dropFirst().first
            ?? group.availableColumns.first
            ?? ""
    }

    public func setSpectrumXAxis(_ column: String, for group: SpectroscopyGroup) {
        setSpectrumAxis(.x, to: column, for: group)
    }

    public func setSpectrumYAxis(_ column: String, for group: SpectroscopyGroup) {
        setSpectrumAxis(.y, to: column, for: group)
    }

    internal func setSpectrumAxis(
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

    public func spectra(for file: SXMMetadata) -> [SpectroscopyFile] {
        spectra
            .filter { spectrumParentIDBySpectrumID[$0.id] == file.id }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    public func spectraForMarkers(on file: SXMMetadata) -> [SpectroscopyFile] {
        SpectroscopyPresentationProjection(
            groups: spectrumGroups(for: file),
            hiddenSpectrumIDs: hiddenSpectrumIDs
        ).markerSpectra
    }

    public func isSpectrumVisible(_ spectrum: SpectroscopyFile) -> Bool {
        !hiddenSpectrumIDs.contains(spectrum.id)
    }

    public func setSpectrum(_ spectrum: SpectroscopyFile, visible: Bool) {
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
                reconcileSingleSpectroscopyState()
            }
        )
    }

    public func selectSpectrumRow(
        _ spectrum: SpectroscopyFile,
        modifiers: NSEvent.ModifierFlags,
        tagContext: UUID? = nil
    ) {
        let relevantModifiers = modifiers.intersection([.command, .shift])
        let rowModifier: SpectrumRowModifier
        if relevantModifiers.contains(.command) {
            rowModifier = .command
        } else if relevantModifiers.contains(.shift) {
            rowModifier = .shift
        } else {
            rowModifier = .plain
        }
        let interaction = SpectrumRowInteractionPlan(
            existingAssociationIDs:
                sidebarSelectedSpectrumIDs,
            clickedID: spectrum.id,
            modifier: rowModifier,
            clickedIsVisible: isSpectrumVisible(spectrum)
        )
        sidebarSelectedSpectrumIDs =
            interaction.associationIDs

        if let parentID = spectrumParentIDBySpectrumID[spectrum.id],
           let parent = files.first(where: { $0.id == parentID }) {
            if selectedID != parent.id {
                select(parent, tagContext: tagContext)
            }
        }
        if interaction.shouldFocusClickedSpectrum {
            focusSingleSpectrum(spectrum)
        }
    }

    public func dragToken(for spectrum: SpectroscopyFile) -> String {
        if !sidebarSelectedSpectrumIDs.contains(spectrum.id) {
            sidebarSelectedSpectrumIDs = [spectrum.id]
        }
        let ids = Array(sidebarSelectedSpectrumIDs)
        let token = UUID().uuidString
        spectrumDragPayloads[token] = ids
        return token
    }

    public func associateSpectra(
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

    public func normalizedMarkerPosition(for spectrum: SpectroscopyFile, on file: SXMMetadata) -> CGPoint? {
        guard let position = spectrum.position,
              let transform = scanCoordinateTransform(
                  for: file
              ),
              let physical = PhysicalScanCoordinate(
                  x: position.x,
                  y: position.y
              ),
              let normalized =
                transform.normalizedCoordinate(
                    for: physical
                ) else {
            return nil
        }
        return CGPoint(x: normalized.u, y: normalized.v)
    }

    public func controlsChanged(resetScale: Bool = false) {
        guard mode == .single else {
            invalidateActiveRender(clearFrame: true)
            return
        }
        refreshSelectedImage(resetScale: resetScale)
    }

    public func channelChanged() {
        guard let channel = selectedFile?.channels.first(where: { $0.name == selectedChannel }) else { return }
        if !channel.directions.contains(selectedDirection) {
            selectedDirection = channel.directions.first ?? .fwd
        }
        selectedPalette = previewPalette(for: selectedChannel)
        selectedProcessing = defaultProcessing(for: selectedChannel)
        if mode == .single {
            refreshSelectedImage(resetScale: true)
        } else {
            invalidateActiveRender(clearFrame: true)
        }
    }

    public func setFullScale() {
        guard let stats = selectedStats else { return }
        scalePreset = .full
        scaleLocked = true
        scaleMin = stats.min
        scaleMax = stats.max
        refreshSelectedImage(resetScale: false)
    }

    public func setPercentileScale() {
        guard let stats = selectedStats else { return }
        scalePreset = .percentile
        scaleLocked = true
        scaleMin = stats.p1
        scaleMax = stats.p99
        refreshSelectedImage(resetScale: false)
    }

    public func setSigmaScale(_ sigma: Double = 2.5) {
        guard let stats = selectedStats else { return }
        scalePreset = .sigma
        scaleLocked = true
        scaleMin = stats.mean - sigma * stats.std
        scaleMax = stats.mean + sigma * stats.std
        refreshSelectedImage(resetScale: false)
    }

    public func applyScalePreset(_ preset: ScalePreset) {
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

    public func updateScale(min: Double, max: Double) {
        guard max > min else { return }
        scalePreset = .manual
        scaleLocked = true
        scaleMin = min
        scaleMax = max
        scheduleCoalescedScaleRender()
    }

    private func scheduleCoalescedScaleRender() {
        if viewer.inFlightCoalescedRequestID != nil {
            viewer.hasPendingScaleRender = true
            return
        }
        dispatchCoalescedScaleRender()
    }

    private func dispatchCoalescedScaleRender() {
        guard let file = selectedFile, !selectedChannel.isEmpty else {
            viewer.cancelCoalescedScaleRender()
            selectedRenderState = .idle
            invalidateActiveRender(clearFrame: true)
            return
        }
        viewer.hasPendingScaleRender = false
        let request = renderCoordinator.render(
            file: file,
            configuration: currentRenderConfiguration
        )
        viewer.inFlightCoalescedRequestID = request.requestID
    }

    public func thumbnail(
        for file: SXMMetadata,
        usingSelection: Bool = false
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let defaultChannel = file.defaultChannel ?? file.channels.first?.name ?? ""
        let channel = usingSelection && !selectedChannel.isEmpty ? selectedChannel : defaultChannel
        let channelInfo = file.channels.first(where: { $0.name == channel }) ?? file.channels.first(where: { $0.name == defaultChannel })
        let direction = usingSelection ? selectedDirection : (channelInfo?.directions.first ?? .fwd)
        let processing = usingSelection ? selectedProcessing : defaultProcessing(for: channel)
        let palette = usingSelection ? selectedPalette : previewPalette(for: channel)
        let invert = usingSelection ? invertPalette : false
        return await thumbnails.thumbnail(
            for: file,
            channel: channel,
            direction: direction,
            processing: processing,
            palette: palette,
            invert: invert
        )
    }


    public func refreshSelectedImage(resetScale: Bool) {
        guard let file = selectedFile, !selectedChannel.isEmpty else {
            selectedRenderState = .idle
            invalidateActiveRender(clearFrame: true)
            return
        }
        if resetScale {
            scalePreset = .full
            scaleLocked = false
            scaleMin = nil
            scaleMax = nil
        }

        viewer.cancelCoalescedScaleRender()
        renderCoordinator.render(
            file: file,
            configuration: currentRenderConfiguration
        )
    }

    public func exportPNG() {
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
                presentToast(
                    title: "PNG exported",
                    message: destination.lastPathComponent
                )
            } catch {
                status = error.localizedDescription
                _ = presentBanner(
                    title: "PNG export failed",
                    message: error.localizedDescription,
                    severity: .error
                )
            }
        }
    }

    internal func updateSelection(
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

    internal func commitSelection(
        _ updatedSelection: SelectionState<SXMMetadata.ID>,
        resetScale: Bool
    ) {
        let previousPrimaryID = selection.primaryID
        guard selection != updatedSelection else { return }
        selection = updatedSelection
        guard previousPrimaryID != selection.primaryID else { return }

        viewerTransform = ViewerTransform()
        clearSelectedRender()
        reconcileSingleSpectroscopyState()
        guard selectedID != nil else {
            status = "No file selected."
            return
        }

        applyDefaultsFromSelection()
        if mode == .single {
            refreshSelectedImage(resetScale: resetScale)
        }
    }

    internal var currentRenderConfiguration: SelectedRenderConfiguration {
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

    internal func histogramBinsChanged() {
        guard mode == .single, let file = selectedFile else {
            return
        }
        renderCoordinator.updateHistogram(
            fileID: file.id,
            configuration: currentRenderConfiguration
        )
    }

    internal func handleRenderCoordinatorEvent(
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
            clearRenderFailureNotice()
            if renderedFrame?.request.processedKey == request.processedKey {
                selectedRenderState = .ready(fileID: request.fileID)
            } else {
                renderedFrame = nil
                selectedRenderState = .loading(fileID: request.fileID)
                let filename = files.first {
                    $0.id == request.fileID
                }?.filename ?? "image"
                status = "Rendering \(filename)..."
            }

        case .imageReady(let frame):
            guard acceptsCoordinatorFrame(frame) else { return }
            clearRenderFailureNotice()
            let finishedCoalescedRequest =
                viewer.inFlightCoalescedRequestID == frame.request.requestID
            if finishedCoalescedRequest {
                viewer.inFlightCoalescedRequestID = nil
            }
            renderedFrame = frame
            selectedRenderState = .ready(
                fileID: frame.request.fileID
            )
            if case .automatic = frame.configuration.scale {
                scaleMin = frame.automaticScaleMin
                scaleMax = frame.automaticScaleMax
            }
            status = files.first {
                $0.id == frame.request.fileID
            }?.filename ?? "Image rendered."
            if finishedCoalescedRequest && viewer.hasPendingScaleRender {
                dispatchCoalescedScaleRender()
            }

        case .histogramReady(let frame):
            guard acceptsCoordinatorFrame(frame) else { return }
            renderedFrame = frame
            selectedRenderState = .ready(
                fileID: frame.request.fileID
            )

        case .failed(let failure):
            let wasInFlightCoalesced =
                viewer.inFlightCoalescedRequestID == failure.request.requestID
            guard (mode == .single
                && selectedID == failure.request.fileID
                && failure.request.configuration
                    == currentRenderConfiguration.imageConfiguration)
                || wasInFlightCoalesced else {
                return
            }
            if wasInFlightCoalesced, viewer.hasPendingScaleRender {
                viewer.inFlightCoalescedRequestID = nil
                dispatchCoalescedScaleRender()
                return
            }
            viewer.cancelCoalescedScaleRender()
            renderedFrame = nil
            selectedRenderState = .failed(
                fileID: failure.request.fileID,
                message: failure.message
            )
            status = failure.message
            renderFailureNoticeID = presentBanner(
                title: "Image could not be rendered",
                message: failure.message,
                severity: .error,
                actions: [.retryRender, .showInFinder]
            )

        case .cleared:
            viewer.cancelCoalescedScaleRender()
            clearRenderFailureNotice()
            renderedFrame = nil
            selectedRenderState = .idle
        }
    }

    internal func acceptsCoordinatorRequest(
        _ request: RenderRequestIdentity<SXMMetadata.ID>,
        configuration: SelectedRenderConfiguration
    ) -> Bool {
        viewer.acceptsCoordinatorRequest(
            request,
            configuration: configuration,
            selectedID: selectedID
        )
    }

    internal func acceptsCoordinatorFrame(
        _ frame: CoordinatorRenderedFrame
    ) -> Bool {
        viewer.acceptsCoordinatorFrame(frame, selectedID: selectedID)
    }

    internal func invalidateActiveRender(clearFrame: Bool) {
        viewer.invalidateActiveRender(clearFrame: clearFrame)
    }

    internal func clearSelectedRender() {
        invalidateActiveRender(clearFrame: true)
    }

    internal func scanCoordinateTransform(
        for file: SXMMetadata
    ) -> ScanCoordinateTransform? {
        spectroscopy.scanCoordinateTransform(for: file)
    }

    internal func nextViewerScale(
        increasing: Bool
    ) -> Double? {
        viewer.nextViewerScale(increasing: increasing)
    }

    internal func activateTagContextIfNeeded(_ tagID: UUID?) {
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

    internal func removeCachedData(for url: URL, clearThumbnails: Bool = true) {
        let path = url.standardizedFileURL.path
        renderCoordinator.removeMatrixEntries(
            forStandardizedPath: path
        )
        if selectedFile?.path.standardizedFileURL.path == path {
            renderCoordinator.discardProcessedData()
        }
        if clearThumbnails {
            thumbnails.invalidateAll()
        }
    }

    internal func ensureSelectionIsVisible() {
        updateSelection { state, visibleIDs in
            state.reconcile(with: visibleIDs, fallbackToFirst: true)
        }
    }


    internal func restoreManualSpectrumAssociations() {
        guard let session = activeDatasetSession else {
            manualAssociationProjection = nil
            return
        }
        manualAssociationProjection = ManualSpectrumAssociationProjection(
            associations: session.verifiedRecord.manualAssociations,
            pathIndex: session.pathIndex,
            availableSXMIDs: Set(files.map(\.id))
        )
    }

    internal func restoreHiddenSpectrumVisibility() {
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

    internal func rebuildSpectrumGroups() {
        let associated = associateSpectra(spectra, with: files)
        spectrumParentIDBySpectrumID = associated.parents
        spectrumGroupsByFileID = associated.groups
        unassociatedSpectrumIDs = associated.unassociated
        spectroscopy.bumpAssociationRevision()
        restoreSpectrumAxisPreferences()
        reconcileSingleSpectroscopyState()
    }

    internal func reconcileSingleSpectroscopyState() {
        let groups = selectedFile.map {
            presentedSpectrumGroups(for: $0)
        } ?? []
        singleSpectroscopyState.reconcile(with: groups)
    }

    internal func restoreSpectrumAxisPreferences() {
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

    internal func associateSpectra(
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
            buckets[parent.id, default: []].append(spectrum)
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

    internal func automaticSpectrumParent(
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

    internal func sxmMatchingFilename(for spectrum: SpectroscopyFile, in sxmFilesByDescendingBasenameLength: [SXMMetadata]) -> SXMMetadata? {
        let spectrumBase = spectrum.path.deletingPathExtension().lastPathComponent.lowercased()
        return sxmFilesByDescendingBasenameLength.first { file in
            spectrumBase.hasPrefix(sxmBasename(file).lowercased())
        }
    }

    internal func sxmBasename(_ file: SXMMetadata) -> String {
        file.path.deletingPathExtension().lastPathComponent
    }

    internal func nearestSXM(to spectrum: SpectroscopyFile, in sxmFiles: [SXMMetadata]) -> SXMMetadata? {
        sxmFiles.min { lhs, rhs in
            abs(lhs.modifiedTime.timeIntervalSince(spectrum.modifiedTime)) < abs(rhs.modifiedTime.timeIntervalSince(spectrum.modifiedTime))
        }
    }

    internal func normalizedTagName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    internal func exportFilename(for file: SXMMetadata) -> String {
        let base = file.filename.replacingOccurrences(of: ".sxm", with: "", options: [.caseInsensitive, .anchored], range: nil)
        let channel = selectedChannel.replacingOccurrences(of: "/", with: "-")
        return "\(base)__\(channel)__\(selectedDirection.rawValue)__\(selectedProcessing.rawValue).png"
    }

}
