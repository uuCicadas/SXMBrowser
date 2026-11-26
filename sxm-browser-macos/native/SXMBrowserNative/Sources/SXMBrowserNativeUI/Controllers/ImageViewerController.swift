import AppKit
import CoreGraphics
import Foundation
import Observation
import SXMBrowserAppCore
import SXMBrowserCore

@Observable
@MainActor
public final class ImageViewerController {
    internal enum CachedFrequencyShiftBounds: Equatable, Sendable {
        case available(FrequencyShiftBounds)
        case unavailable
    }

    private static let viewerZoomPresets: [Double] = [
        0.25,
        0.5,
        1,
        2,
        4,
        8,
        16,
    ]

    private static let viewerZoomFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    public var mode: BrowserMode = .grid
    public var selectedChannel = ""
    public var selectedDirection: ScanDirection = .fwd
    public var selectedProcessing: ProcessingMode = .planeLinear
    public var selectedPalette: PaletteName = .duskViolet
    public var stmPreviewPalette: PaletteName = BrowserDefaults.loadPalette(
        BrowserDefaults.stmPreviewPalette,
        fallback: .duskViolet
    ) {
        didSet {
            UserDefaults.standard.set(
                stmPreviewPalette.rawValue,
                forKey: BrowserDefaults.stmPreviewPalette
            )
            if stmPreviewPalette != oldValue {
                onSTMPreviewPaletteChanged?()
            }
        }
    }
    public var invertPalette = false
    public var scalePreset: ScalePreset = .full
    public var histogramBins: Int = BrowserDefaults.loadInt(
        BrowserDefaults.histogramBins,
        fallback: 256,
        range: 64...1024
    ) {
        didSet {
            UserDefaults.standard.set(
                histogramBins,
                forKey: BrowserDefaults.histogramBins
            )
            if histogramBins != oldValue {
                onHistogramBinsChanged?()
            }
        }
    }
    public var scaleLocked = false
    public var scaleMin: Double?
    public var scaleMax: Double?
    public internal(set) var renderedFrame: CoordinatorRenderedFrame?
    public internal(set) var selectedRenderState: SelectedRenderState<SXMMetadata.ID> = .idle
    public internal(set) var viewerTransform = ViewerTransform()

    @ObservationIgnored public let renderCoordinator: RenderCoordinator
    @ObservationIgnored internal var inFlightCoalescedRequestID: UUID?
    @ObservationIgnored internal var hasPendingScaleRender = false
    @ObservationIgnored internal var pendingViewerGeometry: (
        imageSize: CGSize,
        viewportSize: CGSize
    )?
    @ObservationIgnored internal var onSTMPreviewPaletteChanged: (() -> Void)?
    @ObservationIgnored internal var onHistogramBinsChanged: (() -> Void)?
    @ObservationIgnored internal var frequencyShiftBoundsCache: [FrequencyShiftBoundsKey: CachedFrequencyShiftBounds] = [:]

    public init(renderCoordinator: RenderCoordinator = RenderCoordinator()) {
        self.renderCoordinator = renderCoordinator
    }

    public var currentRenderConfiguration: SelectedRenderConfiguration {
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

    public func previewPalette(for channelName: String) -> PaletteName {
        classifyChannel(channelName).usesSTMPalette ? stmPreviewPalette : .gray
    }

    public func renderedImage(for selectedID: SXMMetadata.ID?) -> NSImage? {
        guard let selectedID, renderedFrame?.request.fileID == selectedID else {
            return nil
        }
        return renderedFrame?.image
    }

    public func renderedStats(for selectedID: SXMMetadata.ID?) -> HistogramStats? {
        guard let selectedID,
              renderedFrame?.request.fileID == selectedID,
              renderedFrame?.stats?.bins == histogramBins else {
            return nil
        }
        return renderedFrame?.stats
    }

    public func canAdjustViewerTransform(selectedID: SXMMetadata.ID?) -> Bool {
        mode == .single
            && renderedImage(for: selectedID) != nil
            && viewerTransform.imageSize.isUsable
            && viewerTransform.viewportSize.isUsable
    }

    public func canZoomViewerIn(selectedID: SXMMetadata.ID?) -> Bool {
        canAdjustViewerTransform(selectedID: selectedID)
            && nextViewerScale(increasing: true) != nil
    }

    public func canZoomViewerOut(selectedID: SXMMetadata.ID?) -> Bool {
        canAdjustViewerTransform(selectedID: selectedID)
            && nextViewerScale(increasing: false) != nil
    }

    public var viewerZoomLabel: String {
        let percentage = viewerTransform.zoomPercentage
        let formatted = Self.viewerZoomFormatter.string(
            from: NSNumber(value: percentage)
        ) ?? "\(Int(percentage.rounded()))"
        switch viewerTransform.mode {
        case .fit:
            return "Fit · \(formatted)%"
        case .custom:
            return "\(formatted)%"
        }
    }

    public func nextViewerScale(increasing: Bool) -> Double? {
        let current = viewerTransform.scale
        let tolerance = 0.000_001
        if increasing {
            return Self.viewerZoomPresets.first { $0 > current + tolerance }
        }
        return Self.viewerZoomPresets.last { $0 < current - tolerance }
    }

    public func acceptsCoordinatorRequest(
        _ request: RenderRequestIdentity<SXMMetadata.ID>,
        configuration: SelectedRenderConfiguration,
        selectedID: SXMMetadata.ID?
    ) -> Bool {
        mode == .single
            && selectedID == request.fileID
            && configuration == currentRenderConfiguration
            && request.configuration == configuration.imageConfiguration
    }

    public func acceptsCoordinatorFrame(
        _ frame: CoordinatorRenderedFrame,
        selectedID: SXMMetadata.ID?
    ) -> Bool {
        if acceptsCoordinatorRequest(
            frame.request,
            configuration: frame.configuration,
            selectedID: selectedID
        ) {
            return true
        }
        guard inFlightCoalescedRequestID == frame.request.requestID,
              mode == .single,
              selectedID == frame.request.fileID,
              frame.request.configuration == frame.configuration.imageConfiguration else {
            return false
        }
        let current = currentRenderConfiguration
        return frame.configuration.processedConfiguration == current.processedConfiguration
            && frame.configuration.palette == current.palette
            && frame.configuration.invert == current.invert
            && frame.configuration.histogramBins == current.histogramBins
    }

    internal func cancelCoalescedScaleRender() {
        inFlightCoalescedRequestID = nil
        hasPendingScaleRender = false
    }

    public func invalidateActiveRender(clearFrame: Bool) {
        cancelCoalescedScaleRender()
        renderCoordinator.invalidate(clearFrame: clearFrame)
    }

    internal func clearFrequencyShiftBoundsCache() {
        frequencyShiftBoundsCache.removeAll()
    }

    internal func removeFrequencyShiftBoundsEntries(forStandardizedPath path: String) {
        frequencyShiftBoundsCache = frequencyShiftBoundsCache.filter {
            $0.key.standardizedPath != path
        }
    }
}
