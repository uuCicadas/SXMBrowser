import CoreGraphics
import Foundation
import Observation
import SXMBrowserAppCore
import SXMBrowserCore

@Observable
@MainActor
public final class SpectroscopyController {
    public var spectrumGroupsByFileID: [SXMMetadata.ID: [SpectroscopyGroup]] = [:]
    public var spectrumParentIDBySpectrumID: [SpectroscopyFile.ID: SXMMetadata.ID] = [:]
    public var hiddenSpectrumIDs: Set<SpectroscopyFile.ID> = [] {
        didSet {
            presentationRevision &+= 1
        }
    }
    public var sidebarSelectedSpectrumIDs: Set<SpectroscopyFile.ID> = []
    public var unassociatedSpectrumIDs: Set<SpectroscopyFile.ID> = []
    public var showsGridSpectroscopyCards: Bool = BrowserDefaults.loadBool(
        BrowserDefaults.showsGridSpectroscopyCards,
        fallback: true
    ) {
        didSet {
            UserDefaults.standard.set(
                showsGridSpectroscopyCards,
                forKey: BrowserDefaults.showsGridSpectroscopyCards
            )
        }
    }
    public var singleSpectroscopyState = SingleSpectroscopyState(
        isExpanded: BrowserDefaults.loadBool(
            BrowserDefaults.singleSpectroscopyDrawerExpanded,
            fallback: true
        ),
        height: Double(
            BrowserDefaults.loadCGFloat(
                BrowserDefaults.singleSpectroscopyDrawerHeight,
                fallback: CGFloat(SingleSpectroscopyState.defaultHeight),
                range: CGFloat(
                    SingleSpectroscopyState.heightRange.lowerBound
                )...CGFloat(
                    SingleSpectroscopyState.heightRange.upperBound
                )
            )
        )
    )
    public var spectrumAxisState = SpectroscopyAxisState()
    public var spectrumAxisRestoreIssues: [SpectrumAxisPreferenceRestoreIssue] = []

    public internal(set) var associationRevision: UInt64 = 0
    public internal(set) var presentationRevision: UInt64 = 0

    @ObservationIgnored internal var manualAssociationProjection: ManualSpectrumAssociationProjection?
    @ObservationIgnored internal var spectrumDragPayloads: [String: [SpectroscopyFile.ID]] = [:]

    public init() {}

    public var presentedSpectrumAxisRestoreIssues: [SpectrumAxisPreferenceRestoreIssue] {
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

    public func visibleUnassociatedSpectra(
        in spectra: [SpectroscopyFile],
        search queryText: String
    ) -> [SpectroscopyFile] {
        let query = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return spectra
            .filter { unassociatedSpectrumIDs.contains($0.id) }
            .filter {
                query.isEmpty
                    || $0.filename.localizedCaseInsensitiveContains(query)
            }
            .sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
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

    public func spectra(
        for file: SXMMetadata,
        in spectra: [SpectroscopyFile]
    ) -> [SpectroscopyFile] {
        spectra
            .filter { spectrumParentIDBySpectrumID[$0.id] == file.id }
            .sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
    }

    public func spectraForMarkers(
        on file: SXMMetadata,
        in spectra: [SpectroscopyFile]
    ) -> [SpectroscopyFile] {
        self.spectra(for: file, in: spectra).filter(isSpectrumVisible)
    }

    public func isSpectrumVisible(_ spectrum: SpectroscopyFile) -> Bool {
        !hiddenSpectrumIDs.contains(spectrum.id)
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

    public func normalizedMarkerPosition(
        for spectrum: SpectroscopyFile,
        on file: SXMMetadata
    ) -> CGPoint? {
        guard let position = spectrum.position,
              let transform = scanCoordinateTransform(for: file),
              let physical = PhysicalScanCoordinate(x: position.x, y: position.y),
              let normalized = transform.normalizedCoordinate(for: physical) else {
            return nil
        }
        return CGPoint(x: normalized.u, y: normalized.v)
    }

    public func scanCoordinateTransform(for file: SXMMetadata) -> ScanCoordinateTransform? {
        guard let range = file.scanRange,
              let offset = file.scanOffset else {
            return nil
        }
        return ScanCoordinateTransform(
            rangeX: range.x,
            rangeY: range.y,
            offsetX: offset.x,
            offsetY: offset.y,
            angleDegrees: file.scanAngle ?? 0,
            scanDirection: file.scanDir
        )
    }

    public func resetForNewFolder() {
        spectrumGroupsByFileID.removeAll()
        spectrumParentIDBySpectrumID.removeAll()
        hiddenSpectrumIDs.removeAll()
        sidebarSelectedSpectrumIDs.removeAll()
        unassociatedSpectrumIDs.removeAll()
        manualAssociationProjection = nil
        spectrumDragPayloads.removeAll()
        spectrumAxisState.clear()
        spectrumAxisRestoreIssues.removeAll()
        associationRevision &+= 1
        presentationRevision &+= 1
    }

    internal func bumpAssociationRevision() {
        associationRevision &+= 1
        presentationRevision &+= 1
    }
}
