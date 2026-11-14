import Testing
@testable import SXMBrowserAppCore

private let coordinateTolerance = 0.000_000_1

private func coordinateClose(
    _ actual: Double,
    _ expected: Double
) -> Bool {
    abs(actual - expected) <= coordinateTolerance
}

@Test
func scanTransformMatchesNormalizedImageFrameForDownAndUp() {
    let offset = PhysicalScanCoordinate(x: 10, y: -20)!
    let center = PhysicalScanCoordinate(x: 10, y: -20)!
    let positiveCorner = PhysicalScanCoordinate(
        x: 60,
        y: 5
    )!
    let down = ScanCoordinateTransform(
        rangeX: 100,
        rangeY: 50,
        offsetX: offset.x,
        offsetY: offset.y,
        scanDirection: "down"
    )!
    let up = ScanCoordinateTransform(
        rangeX: 100,
        rangeY: 50,
        offsetX: offset.x,
        offsetY: offset.y,
        scanDirection: "SCAN UP"
    )!

    #expect(
        down.normalizedCoordinate(for: center)
            == NormalizedScanCoordinate(u: 0.5, v: 0.5)
    )
    #expect(
        down.normalizedCoordinate(for: positiveCorner)
            == NormalizedScanCoordinate(u: 1, v: 0)
    )
    #expect(
        up.normalizedCoordinate(for: positiveCorner)
            == NormalizedScanCoordinate(u: 1, v: 0)
    )
    #expect(
        up.physicalCoordinate(for: NormalizedScanCoordinate(u: 1, v: 0)!)
            == positiveCorner
    )
    #expect(
        ScanVerticalDirection.resolve(
            scanDirection: nil
        ) == .down
    )
    #expect(
        ScanVerticalDirection.resolve(
            scanDirection: "pickup"
        ) == .down
    )
    #expect(
        ScanVerticalDirection.resolve(
            scanDirection: "SCAN UP"
        ) == .up
    )
}

@Test
func angleOffsetAndNonSquareRangeUseTheMarkerRotationConvention() {
    let transform = ScanCoordinateTransform(
        rangeX: 200,
        rangeY: 40,
        offsetX: 5,
        offsetY: -7,
        angleDegrees: 90,
        scanDirection: "up"
    )!
    let normalized = transform.normalizedCoordinate(
        for: PhysicalScanCoordinate(x: 15, y: -7)!
    )

    #expect(
        normalized.map {
            coordinateClose($0.u, 0.5)
                && coordinateClose($0.v, 0.25)
        } == true
    )
    let physical = normalized.flatMap {
        transform.physicalCoordinate(for: $0)
    }
    #expect(
        physical.map {
            coordinateClose($0.x, 15)
                && coordinateClose($0.y, -7)
        } == true
    )
}

@Test(
    arguments: [
        "up",
        "down",
    ]
)
func normalizedAndPhysicalCoordinatesRoundTrip(
    scanDirection: String
) {
    let transform = ScanCoordinateTransform(
        rangeX: 123.5,
        rangeY: 37.25,
        offsetX: -8.5,
        offsetY: 11.75,
        angleDegrees: 37,
        scanDirection: scanDirection
    )!
    let coordinates = [
        NormalizedScanCoordinate(u: 0, v: 0)!,
        NormalizedScanCoordinate(u: 0.5, v: 0.5)!,
        NormalizedScanCoordinate(u: 1, v: 1)!,
        NormalizedScanCoordinate(u: -0.2, v: 1.4)!,
    ]

    for coordinate in coordinates {
        let roundTrip = transform
            .physicalCoordinate(for: coordinate)
            .flatMap {
                transform.normalizedCoordinate(for: $0)
            }
        #expect(
            roundTrip.map {
                coordinateClose($0.u, coordinate.u)
                    && coordinateClose($0.v, coordinate.v)
            } == true
        )
    }
}

@Test
func invalidScanGeometryAndCoordinatesAreRejected() {
    let nonFiniteValues = [
        Double.nan,
        Double.infinity,
        -Double.infinity,
    ]
    for value in nonFiniteValues {
        #expect(
            NormalizedScanCoordinate(u: value, v: 0)
                == nil
        )
        #expect(
            NormalizedScanCoordinate(u: 0, v: value)
                == nil
        )
        #expect(
            PhysicalScanCoordinate(x: value, y: 0)
                == nil
        )
        #expect(
            PhysicalScanCoordinate(x: 0, y: value)
                == nil
        )
        #expect(
            ScanCoordinateTransform(
                rangeX: value,
                rangeY: 10,
                offsetX: 0,
                offsetY: 0
            ) == nil
        )
        #expect(
            ScanCoordinateTransform(
                rangeX: 10,
                rangeY: value,
                offsetX: 0,
                offsetY: 0
            ) == nil
        )
        #expect(
            ScanCoordinateTransform(
                rangeX: 10,
                rangeY: 10,
                offsetX: value,
                offsetY: 0
            ) == nil
        )
        #expect(
            ScanCoordinateTransform(
                rangeX: 10,
                rangeY: 10,
                offsetX: 0,
                offsetY: value
            ) == nil
        )
        #expect(
            ScanCoordinateTransform(
                rangeX: 10,
                rangeY: 10,
                offsetX: 0,
                offsetY: 0,
                angleDegrees: value
            ) == nil
        )
    }
    for range in [
        (x: 0.0, y: 10.0),
        (x: -1.0, y: 10.0),
        (x: 10.0, y: 0.0),
        (x: 10.0, y: -1.0),
    ] {
        #expect(
            ScanCoordinateTransform(
                rangeX: range.x,
                rangeY: range.y,
                offsetX: 0,
                offsetY: 0
            ) == nil
        )
    }
}
