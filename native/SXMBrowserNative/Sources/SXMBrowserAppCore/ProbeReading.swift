import Foundation
import SXMBrowserCore

public struct NormalizedScanCoordinate:
    Equatable,
    Sendable
{
    public let u: Double
    public let v: Double

    public init?(u: Double, v: Double) {
        guard u.isFinite, v.isFinite else { return nil }
        self.u = u
        self.v = v
    }
}

public struct PhysicalScanCoordinate:
    Equatable,
    Sendable
{
    public let x: Double
    public let y: Double

    public init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return nil }
        self.x = x
        self.y = y
    }
}

public enum ScanVerticalDirection:
    Equatable,
    Sendable
{
    case up
    case down

    public static func resolve(
        scanDirection: String?
    ) -> ScanVerticalDirection {
        isUpwardScanDirection(scanDirection) ? .up : .down
    }
}

public struct ScanCoordinateTransform:
    Equatable,
    Sendable
{
    public let rangeX: Double
    public let rangeY: Double
    public let offset: PhysicalScanCoordinate
    public let angleDegrees: Double
    public let verticalDirection: ScanVerticalDirection

    private let cosine: Double
    private let sine: Double

    public init?(
        rangeX: Double,
        rangeY: Double,
        offsetX: Double,
        offsetY: Double,
        angleDegrees: Double = 0,
        scanDirection: String? = nil
    ) {
        guard rangeX.isFinite,
              rangeY.isFinite,
              rangeX > 0,
              rangeY > 0,
              let offset = PhysicalScanCoordinate(
                  x: offsetX,
                  y: offsetY
              ),
              angleDegrees.isFinite else {
            return nil
        }
        let radians = angleDegrees * .pi / 180
        guard radians.isFinite else { return nil }
        let cosine = cos(radians)
        let sine = sin(radians)
        guard cosine.isFinite, sine.isFinite else {
            return nil
        }

        self.rangeX = rangeX
        self.rangeY = rangeY
        self.offset = offset
        self.angleDegrees = angleDegrees
        verticalDirection = .resolve(
            scanDirection: scanDirection
        )
        self.cosine = cosine
        self.sine = sine
    }

    public func normalizedCoordinate(
        for physical: PhysicalScanCoordinate
    ) -> NormalizedScanCoordinate? {
        let dx = physical.x - offset.x
        let dy = physical.y - offset.y
        let scanX = cosine * dx - sine * dy
        let scanY = sine * dx + cosine * dy
        let u = 0.5 + scanX / rangeX
        // SXMParser normalizes both downward and upward scans so row 0 (v = 0)
        // always sits at physical +scanY.
        let v = 0.5 - scanY / rangeY
        return NormalizedScanCoordinate(u: u, v: v)
    }

    public func physicalCoordinate(
        for normalized: NormalizedScanCoordinate
    ) -> PhysicalScanCoordinate? {
        let scanX = (normalized.u - 0.5) * rangeX
        let scanY = (0.5 - normalized.v) * rangeY
        let dx = cosine * scanX + sine * scanY
        let dy = -sine * scanX + cosine * scanY
        return PhysicalScanCoordinate(
            x: offset.x + dx,
            y: offset.y + dy
        )
    }
}

public struct PixelCoordinate:
    Equatable,
    Hashable,
    Sendable
{
    public let x: Int
    public let y: Int

    public init?(x: Int, y: Int) {
        guard x >= 0, y >= 0 else { return nil }
        self.x = x
        self.y = y
    }

    public static func resolve(
        viewportPoint: ViewerPoint,
        viewerTransform: ViewerTransform,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> PixelCoordinate? {
        resolve(
            viewportX: viewportPoint.x,
            viewportY: viewportPoint.y,
            viewerTransform: viewerTransform,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    public static func resolve(
        viewportX: Double,
        viewportY: Double,
        viewerTransform: ViewerTransform,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> PixelCoordinate? {
        guard viewportX.isFinite,
              viewportY.isFinite,
              pixelWidth > 0,
              pixelHeight > 0,
              viewerTransform.imageSize.isUsable,
              viewerTransform.viewportSize.isUsable,
              viewportX >= 0,
              viewportY >= 0,
              viewportX < viewerTransform.viewportSize.width,
              viewportY < viewerTransform.viewportSize.height,
              let imagePoint = viewerTransform.imagePoint(
                  at: ViewerPoint(
                      x: viewportX,
                      y: viewportY
                  )
              ),
              imagePoint.x >= 0,
              imagePoint.y >= 0,
              imagePoint.x
                < viewerTransform.imageSize.width,
              imagePoint.y
                < viewerTransform.imageSize.height else {
            return nil
        }

        let normalizedX =
            imagePoint.x / viewerTransform.imageSize.width
        let normalizedY =
            imagePoint.y / viewerTransform.imageSize.height
        let projectedX = normalizedX * Double(pixelWidth)
        let projectedY = normalizedY * Double(pixelHeight)
        guard projectedX.isFinite,
              projectedY.isFinite,
              projectedX >= 0,
              projectedY >= 0,
              projectedX < Double(Int.max),
              projectedY < Double(Int.max) else {
            return nil
        }
        let x = min(
            pixelWidth - 1,
            Int(projectedX.rounded(.down))
        )
        let y = min(
            pixelHeight - 1,
            Int(projectedY.rounded(.down))
        )
        return PixelCoordinate(x: x, y: y)
    }

    public func normalizedCenter(
        pixelWidth: Int,
        pixelHeight: Int
    ) -> NormalizedScanCoordinate? {
        guard isValid(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ) else {
            return nil
        }
        return NormalizedScanCoordinate(
            u: (Double(x) + 0.5) / Double(pixelWidth),
            v: (Double(y) + 0.5) / Double(pixelHeight)
        )
    }

    public func viewportCenter(
        viewerTransform: ViewerTransform,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> ViewerPoint? {
        guard let normalized = normalizedCenter(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ) else {
            return nil
        }
        return viewerTransform.viewportPoint(
            for: ViewerPoint(
                x:
                    normalized.u
                    * viewerTransform.imageSize.width,
                y:
                    normalized.v
                    * viewerTransform.imageSize.height
            )
        )
    }

    public func linearIndex(
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Int? {
        guard isValid(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ),
              y <= (Int.max - x) / pixelWidth else {
            return nil
        }
        return y * pixelWidth + x
    }

    private func isValid(
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Bool {
        pixelWidth > 0
            && pixelHeight > 0
            && x < pixelWidth
            && y < pixelHeight
    }
}

public struct ProbeReading:
    Equatable,
    Sendable
{
    public let pixelCoordinate: PixelCoordinate
    public let normalizedCoordinate: NormalizedScanCoordinate
    public let physicalCoordinate: PhysicalScanCoordinate?
    public let rawValue: Double?
    public let processedValue: Double?
    public let channelName: String
    public let unit: String

    public init?(
        pixelCoordinate: PixelCoordinate,
        pixelWidth: Int,
        pixelHeight: Int,
        rawValue: Double?,
        processedValue: Double?,
        channelName: String,
        unit: String,
        scanTransform: ScanCoordinateTransform? = nil
    ) {
        guard let normalizedCoordinate =
            pixelCoordinate.normalizedCenter(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            ) else {
            return nil
        }
        self.pixelCoordinate = pixelCoordinate
        self.normalizedCoordinate = normalizedCoordinate
        physicalCoordinate = scanTransform?
            .physicalCoordinate(for: normalizedCoordinate)
        self.rawValue = Self.finite(rawValue)
        self.processedValue = Self.finite(processedValue)
        self.channelName = channelName
        self.unit = unit
    }

    private static func finite(
        _ value: Double?
    ) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
