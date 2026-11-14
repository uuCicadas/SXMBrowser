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
