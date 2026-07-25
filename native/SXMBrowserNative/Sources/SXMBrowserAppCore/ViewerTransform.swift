public struct ViewerPoint:
    Equatable,
    Sendable
{
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
    }

    public static let zero = ViewerPoint(x: 0, y: 0)
}

public struct ViewerSize:
    Equatable,
    Sendable
{
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width =
            width.isFinite && width > 0 ? width : 0
        self.height =
            height.isFinite && height > 0 ? height : 0
    }

    public static let zero = ViewerSize(width: 0, height: 0)

    public var isUsable: Bool {
        width > 0 && height > 0
    }

    public var center: ViewerPoint {
        ViewerPoint(x: width / 2, y: height / 2)
    }
}

public enum ViewerScaleMode:
    Equatable,
    Sendable
{
    case fit
    case custom
}

public struct ViewerTransform:
    Equatable,
    Sendable
{
    public static let minimumCustomScale = 0.25
    public static let maximumCustomScale = 16.0

    public private(set) var imageSize: ViewerSize
    public private(set) var viewportSize: ViewerSize
    public private(set) var mode: ViewerScaleMode
    public private(set) var scale: Double
    public private(set) var translation: ViewerPoint

    public init(
        imageSize: ViewerSize = .zero,
        viewportSize: ViewerSize = .zero
    ) {
        self.imageSize = imageSize
        self.viewportSize = viewportSize
        mode = .fit
        scale = 1
        translation = .zero
        applyFit()
    }

    public var zoomPercentage: Double {
        scale * 100
    }

    public static func fitScale(
        imageSize: ViewerSize,
        viewportSize: ViewerSize
    ) -> Double? {
        guard imageSize.isUsable,
              viewportSize.isUsable else {
            return nil
        }
        let requiredScale = min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
        guard requiredScale.isFinite,
              requiredScale > 0 else {
            return nil
        }
        return min(requiredScale, maximumCustomScale)
    }

    public mutating func fit() {
        mode = .fit
        applyFit()
    }

    public mutating func showActualSize(
        around anchor: ViewerPoint? = nil
    ) {
        setCustomScale(1, around: anchor)
    }

    public mutating func setCustomScale(
        _ requestedScale: Double,
        around anchor: ViewerPoint? = nil
    ) {
        guard !requestedScale.isNaN else { return }
        let nextScale = min(
            Self.maximumCustomScale,
            max(Self.minimumCustomScale, requestedScale)
        )
        let resolvedAnchor = constrainedViewportPoint(
            anchor ?? viewportSize.center
        )
        let anchoredImagePoint = imagePoint(
            at: resolvedAnchor
        )

        mode = .custom
        scale = nextScale
        if let anchoredImagePoint {
            translation = ViewerPoint(
                x:
                    resolvedAnchor.x
                    - anchoredImagePoint.x * scale,
                y:
                    resolvedAnchor.y
                    - anchoredImagePoint.y * scale
            )
        } else {
            translation = centeredTranslation()
        }
        constrainTranslation()
    }

    public mutating func zoom(
        by factor: Double,
        around anchor: ViewerPoint
    ) {
        guard factor.isFinite,
              factor > 0 else {
            return
        }
        setCustomScale(
            scale * factor,
            around: anchor
        )
    }

    public mutating func pan(by delta: ViewerPoint) {
        guard imageSize.isUsable,
              viewportSize.isUsable else {
            translation = .zero
            return
        }
        translation = ViewerPoint(
            x: finiteSum(
                translation.x,
                delta.x,
                fallback: translation.x
            ),
            y: finiteSum(
                translation.y,
                delta.y,
                fallback: translation.y
            )
        )
        constrainTranslation()
    }

    public mutating func reconcile(
        imageSize newImageSize: ViewerSize,
        viewportSize newViewportSize: ViewerSize
    ) {
        let preservedImagePoint: ViewerPoint?
        if mode == .custom,
           imageSize.isUsable,
           viewportSize.isUsable {
            preservedImagePoint = imagePoint(
                at: viewportSize.center
            )
        } else {
            preservedImagePoint = nil
        }

        imageSize = newImageSize
        viewportSize = newViewportSize

        if mode == .fit {
            applyFit()
            return
        }

        scale = Self.clampedCustomScale(scale)
        guard imageSize.isUsable,
              viewportSize.isUsable else {
            translation = .zero
            return
        }
        let imagePoint = constrainedImagePoint(
            preservedImagePoint ?? imageSize.center
        )
        translation = ViewerPoint(
            x:
                viewportSize.center.x
                - imagePoint.x * scale,
            y:
                viewportSize.center.y
                - imagePoint.y * scale
        )
        constrainTranslation()
    }

    public func imagePoint(
        at viewportPoint: ViewerPoint
    ) -> ViewerPoint? {
        guard imageSize.isUsable,
              viewportSize.isUsable,
              scale.isFinite,
              scale > 0 else {
            return nil
        }
        return ViewerPoint(
            x:
                (viewportPoint.x - translation.x)
                / scale,
            y:
                (viewportPoint.y - translation.y)
                / scale
        )
    }

    public func viewportPoint(
        for imagePoint: ViewerPoint
    ) -> ViewerPoint? {
        guard imageSize.isUsable,
              viewportSize.isUsable,
              scale.isFinite,
              scale > 0 else {
            return nil
        }
        return ViewerPoint(
            x:
                imagePoint.x * scale
                + translation.x,
            y:
                imagePoint.y * scale
                + translation.y
        )
    }

    private static func clampedCustomScale(
        _ value: Double
    ) -> Double {
        guard !value.isNaN else { return 1 }
        return min(
            maximumCustomScale,
            max(minimumCustomScale, value)
        )
    }

    private mutating func applyFit() {
        guard let fittedScale = Self.fitScale(
            imageSize: imageSize,
            viewportSize: viewportSize
        ) else {
            scale = 1
            translation = .zero
            return
        }
        scale = fittedScale
        translation = centeredTranslation()
        constrainTranslation()
    }

    private func centeredTranslation() -> ViewerPoint {
        guard imageSize.isUsable,
              viewportSize.isUsable else {
            return .zero
        }
        return ViewerPoint(
            x:
                (
                    viewportSize.width
                    - imageSize.width * scale
                ) / 2,
            y:
                (
                    viewportSize.height
                    - imageSize.height * scale
                ) / 2
        )
    }

    private mutating func constrainTranslation() {
        guard imageSize.isUsable,
              viewportSize.isUsable,
              scale.isFinite,
              scale > 0 else {
            translation = .zero
            return
        }
        translation = ViewerPoint(
            x: Self.constrainedTranslation(
                translation.x,
                imageLength: imageSize.width,
                viewportLength: viewportSize.width,
                scale: scale
            ),
            y: Self.constrainedTranslation(
                translation.y,
                imageLength: imageSize.height,
                viewportLength: viewportSize.height,
                scale: scale
            )
        )
    }

    private static func constrainedTranslation(
        _ proposed: Double,
        imageLength: Double,
        viewportLength: Double,
        scale: Double
    ) -> Double {
        let scaledImageLength = imageLength * scale
        if scaledImageLength <= viewportLength {
            return (viewportLength - scaledImageLength) / 2
        }
        let minimum = viewportLength - scaledImageLength
        let finiteProposed = proposed.isFinite ? proposed : 0
        return min(0, max(minimum, finiteProposed))
    }

    private func constrainedViewportPoint(
        _ point: ViewerPoint
    ) -> ViewerPoint {
        guard viewportSize.isUsable else { return .zero }
        return ViewerPoint(
            x: min(viewportSize.width, max(0, point.x)),
            y: min(viewportSize.height, max(0, point.y))
        )
    }

    private func constrainedImagePoint(
        _ point: ViewerPoint
    ) -> ViewerPoint {
        guard imageSize.isUsable else { return .zero }
        return ViewerPoint(
            x: min(imageSize.width, max(0, point.x)),
            y: min(imageSize.height, max(0, point.y))
        )
    }

    private func finiteSum(
        _ lhs: Double,
        _ rhs: Double,
        fallback: Double
    ) -> Double {
        let sum = lhs + rhs
        return sum.isFinite ? sum : fallback
    }
}
