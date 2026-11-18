import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct SingleImageView: View {
    let model: AppModel
    @State private var liveDrawerHeight: CGFloat
    @State private var isResizingDrawer = false

    init(model: AppModel) {
        self.model = model
        _liveDrawerHeight = State(
            initialValue: CGFloat(
                model.singleSpectroscopyState.height
            )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                SingleImageCanvas(model: model)
                    // Keep new data, probes and continuous gestures out of layout transitions.
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                SingleSpectroscopyDrawer(
                    model: model,
                    liveHeight: $liveDrawerHeight,
                    isResizing: $isResizingDrawer,
                    maximumHeight: max(42, proxy.size.height / 2)
                )
            }
        }
        .onChange(
            of: model.singleSpectroscopyState.height
        ) { _, height in
            if !isResizingDrawer {
                liveDrawerHeight = CGFloat(height)
            }
        }
        .onChange(of: isResizingDrawer) { _, resizing in
            model.setViewportResizing(resizing)
        }
        .onDisappear {
            if isResizingDrawer {
                model.setViewportResizing(false)
            }
        }
        .transaction { transaction in
            if isResizingDrawer {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

private struct SingleImageCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: AppModel
    @State private var dragStartTransform:
        ViewerTransform?
    @State private var magnifyStartTransform:
        ViewerTransform?
    @State private var gestureTransform:
        ViewerTransform?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.gridStage(for: colorScheme)
                switch model.browserContentState {
                case .renderReady:
                    if let frame = model.renderedFrame,
                       frame.request.fileID == model.selectedID,
                       let file = model.files.first(where: {
                           $0.id == frame.request.fileID
                       }) {
                        readyCanvas(
                            frame: frame,
                            file: file,
                            availableSize: proxy.size
                        )
                    } else {
                        ProgressView()
                    }
                case .renderLoading:
                    BrowserStateView(
                        icon: "photo",
                        title: "Rendering Image",
                        message:
                            "Preparing the selected channel "
                            + "and statistics.",
                        showsProgress: true
                    )
                case .renderFailed(_, let message):
                    BrowserStateView(
                        icon: "exclamationmark.octagon",
                        title: "Image Could Not Be Rendered",
                        message: message
                    ) {
                        Button("Retry") {
                            model.retrySelectedRender()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Show in Finder") {
                            model.revealSelectedFileInFinder()
                        }
                        .buttonStyle(.bordered)
                    }
                default:
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            .onChange(of: model.selectedID) { _, _ in
                clearGesturePreview()
            }
        }
    }

    @ViewBuilder
    private func readyCanvas(
        frame: CoordinatorRenderedFrame,
        file: SXMMetadata,
        availableSize: CGSize
    ) -> some View {
        let viewportSize = CGSize(
            width: max(1, availableSize.width - 36),
            height: max(1, availableSize.height - 36)
        )
        let imageSize = CGSize(
            width: max(1, CGFloat(file.pixels.width)),
            height: max(1, CGFloat(file.pixels.height))
        )
        let geometry = ViewerCanvasGeometry(
            imageSize: imageSize,
            viewportSize: viewportSize
        )
        let displayedTransform = reconciledTransform(
            gestureTransform ?? model.viewerTransform,
            geometry: geometry
        )
        let scaledImageSize = CGSize(
            width:
                imageSize.width
                * displayedTransform.scale,
            height:
                imageSize.height
                * displayedTransform.scale
        )
        let visibleImageRect = CGRect(
            x: displayedTransform.translation.x,
            y: displayedTransform.translation.y,
            width: scaledImageSize.width,
            height: scaledImageSize.height
        ).intersection(
            CGRect(
                origin: .zero,
                size: viewportSize
            )
        )
        let scaleBar = resolvedScaleBar(
            for: file,
            transform: displayedTransform,
            visibleImageRect: visibleImageRect
        )

        let imageRect = CGRect(
            x: displayedTransform.translation.x,
            y: displayedTransform.translation.y,
            width: scaledImageSize.width,
            height: scaledImageSize.height
        )

        ZStack(alignment: .topLeading) {
            MissingDataBackdrop(tileSize: 10)
                .frame(
                    width: max(1, scaledImageSize.width),
                    height: max(1, scaledImageSize.height)
                )
                .overlay(
                    Rectangle()
                        .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
                )
                .position(x: imageRect.midX, y: imageRect.midY)

            LayerImageView(
                image: frame.image,
                scaling: .transform(
                    scale: CGFloat(displayedTransform.scale),
                    translation: CGPoint(
                        x: displayedTransform.translation.x,
                        y: displayedTransform.translation.y
                    )
                ),
                filter: .nearest
            )
            .frame(
                width: viewportSize.width,
                height: viewportSize.height
            )

            SpectroscopyMarkerLayer(
                model: model,
                file: file,
                isInteractive: true,
                rectOverride: imageRect
            )
            .frame(
                width: viewportSize.width,
                height: viewportSize.height
            )
            .zIndex(1)

            if let scaleBar {
                let overlayWidth =
                    CGFloat(scaleBar.screenLengthPoints)
                ScreenScaleBar(scaleBar: scaleBar)
                    .position(
                        x:
                            visibleImageRect.maxX
                            - ScreenScaleBar.edgeInset
                            - overlayWidth / 2,
                        y:
                            visibleImageRect.maxY
                            - ScreenScaleBar.edgeInset
                            - ScreenScaleBar.height / 2
                    )
                    .zIndex(2)
            }
        }
        .frame(
            width: viewportSize.width,
            height: viewportSize.height,
            alignment: .topLeading
        )
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            panGesture(
                startingFrom: displayedTransform
            )
        )
        .simultaneousGesture(
            magnifyGesture(
                startingFrom: displayedTransform
            )
        )
        .onAppear {
            model.reconcileViewerGeometry(
                imageSize: imageSize,
                viewportSize: viewportSize
            )
        }
        .onChange(of: geometry) { _, updated in
            clearGesturePreview()
            model.reconcileViewerGeometry(
                imageSize: updated.imageSize,
                viewportSize: updated.viewportSize
            )
        }
        .onChange(of: frame.request.requestID) { _, _ in
            clearGesturePreview()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image viewer")
        .accessibilityValue(model.viewerZoomLabel)
    }

    private func panGesture(
        startingFrom displayedTransform: ViewerTransform
    ) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartTransform == nil {
                    dragStartTransform =
                        displayedTransform
                }
                guard var preview =
                    dragStartTransform else {
                    return
                }
                preview.pan(
                    by: ViewerPoint(
                        x: value.translation.width,
                        y: value.translation.height
                    )
                )
                gestureTransform = preview
            }
            .onEnded { _ in
                commitGesturePreview()
            }
    }

    private func magnifyGesture(
        startingFrom displayedTransform: ViewerTransform
    ) -> some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if magnifyStartTransform == nil {
                    magnifyStartTransform =
                        displayedTransform
                }
                guard var preview =
                    magnifyStartTransform else {
                    return
                }
                preview.setCustomScale(
                    preview.scale * Double(value),
                    around: preview.viewportSize.center
                )
                gestureTransform = preview
            }
            .onEnded { _ in
                commitGesturePreview()
            }
    }

    private func reconciledTransform(
        _ transform: ViewerTransform,
        geometry: ViewerCanvasGeometry
    ) -> ViewerTransform {
        var resolved = transform
        resolved.reconcile(
            imageSize: ViewerSize(
                width: geometry.imageSize.width,
                height: geometry.imageSize.height
            ),
            viewportSize: ViewerSize(
                width: geometry.viewportSize.width,
                height: geometry.viewportSize.height
            )
        )
        return resolved
    }

    private func commitGesturePreview() {
        if let gestureTransform {
            model.commitViewerTransform(
                gestureTransform
            )
        }
        clearGesturePreview()
    }

    private func clearGesturePreview() {
        dragStartTransform = nil
        magnifyStartTransform = nil
        gestureTransform = nil
    }

    private func resolvedScaleBar(
        for file: SXMMetadata,
        transform: ViewerTransform,
        visibleImageRect: CGRect
    ) -> ScaleBar? {
        guard let scanRangeX = file.scanRange?.x,
              !visibleImageRect.isNull,
              visibleImageRect.width
                >= CGFloat(ScaleBar.preferredMinimumScreenLengthPoints)
                    + 2 * ScreenScaleBar.edgeInset,
              visibleImageRect.height
                >= ScreenScaleBar.height + 2 * ScreenScaleBar.edgeInset else {
            return nil
        }
        guard let scaleBar = ScaleBar.resolve(
            scanRangeX: scanRangeX,
            sourcePixelWidth: file.pixels.width,
            viewerTransform: transform,
            availableWidth:
                visibleImageRect.width - 2 * ScreenScaleBar.edgeInset
        ), scaleBar.screenLengthPoints
            >= ScaleBar.preferredMinimumScreenLengthPoints else {
            return nil
        }
        return scaleBar
    }
}

private struct ViewerCanvasGeometry: Equatable {
    let imageSize: CGSize
    let viewportSize: CGSize
}

