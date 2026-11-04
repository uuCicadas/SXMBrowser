import AppKit
import QuartzCore
import SwiftUI

/// Draws an `NSImage` through a Core Animation layer.
///
/// Pane resizing, panning, and zooming only update layer geometry, so the
/// bitmap is composited on the GPU instead of being resampled by SwiftUI on
/// every frame.
struct LayerImageView: NSViewRepresentable {
    enum Scaling {
        /// Explicit image-point scale with a top-left translation.
        case transform(scale: CGFloat, translation: CGPoint)
        /// Aspect-fit the image inside the view, used by thumbnails.
        case aspectFit
    }

    var image: NSImage
    var scaling: Scaling
    var filter: CALayerContentsFilter

    func makeNSView(context: Context) -> LayerImageNSView {
        LayerImageNSView()
    }

    func updateNSView(_ nsView: LayerImageNSView, context: Context) {
        nsView.apply(image: image, scaling: scaling, filter: filter)
    }
}

@MainActor
final class LayerImageNSView: NSView {
    private let imageLayer = CALayer()
    private var loadedImage: NSImage?
    private var loadedContents: CGImage?
    private var scaling: LayerImageView.Scaling = .aspectFit

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.anchorPoint = .zero
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// Let SwiftUI gestures and buttons above the image receive the events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        applyScaling()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScaling()
    }

    func apply(
        image: NSImage,
        scaling: LayerImageView.Scaling,
        filter: CALayerContentsFilter
    ) {
        if loadedImage !== image {
            loadedImage = image
            if let contents = Self.contents(of: image) {
                loadedContents = contents
                imageLayer.contents = contents
                imageLayer.bounds = CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: contents.width,
                        height: contents.height
                    )
                )
            } else {
                loadedContents = nil
                imageLayer.contents = nil
            }
        }
        imageLayer.magnificationFilter = filter
        imageLayer.minificationFilter = filter
        self.scaling = scaling
        applyScaling()
    }

    private func applyScaling() {
        guard let contents = loadedContents,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        let imageSize = CGSize(
            width: contents.width,
            height: contents.height
        )
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale: CGFloat
        let translation: CGPoint
        switch scaling {
        case .aspectFit:
            scale = min(
                bounds.width / imageSize.width,
                bounds.height / imageSize.height
            )
            translation = CGPoint(
                x: (bounds.width - imageSize.width * scale) / 2,
                y: (bounds.height - imageSize.height * scale) / 2
            )
        case let .transform(requestedScale, requestedTranslation):
            scale = requestedScale
            translation = requestedTranslation
        }
        guard scale.isFinite, scale > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        // AppKit layers use a bottom-left origin; callers pass top-left offsets.
        imageLayer.position = CGPoint(
            x: translation.x,
            y: bounds.height - translation.y - imageSize.height * scale
        )
        CATransaction.commit()
    }

    private static func contents(of image: NSImage) -> CGImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        if let contents = image.cgImage(
            forProposedRect: &proposed,
            context: nil,
            hints: nil
        ) {
            return contents
        }
        for representation in image.representations {
            if let bitmap = representation as? NSBitmapImageRep,
               let contents = bitmap.cgImage {
                return contents
            }
        }
        return nil
    }
}
