import Testing
@testable import SXMBrowserAppCore

private let probeTolerance = 0.000_000_1

private func probeClose(
    _ actual: Double,
    _ expected: Double
) -> Bool {
    abs(actual - expected) <= probeTolerance
}

@Test
func viewportMappingRejectsLetterboxAndOutsidePoints() {
    let transform = ViewerTransform(
        imageSize: ViewerSize(width: 100, height: 50),
        viewportSize: ViewerSize(width: 200, height: 200)
    )

    #expect(
        PixelCoordinate.resolve(
            viewportX: 0,
            viewportY: 49.999,
            viewerTransform: transform,
            pixelWidth: 100,
            pixelHeight: 50
        ) == nil
    )
    #expect(
        PixelCoordinate.resolve(
            viewportX: 0,
            viewportY: 50,
            viewerTransform: transform,
            pixelWidth: 100,
            pixelHeight: 50
        ) == PixelCoordinate(x: 0, y: 0)
    )
    #expect(
        PixelCoordinate.resolve(
            viewportX: 199.999,
            viewportY: 149.999,
            viewerTransform: transform,
            pixelWidth: 100,
            pixelHeight: 50
        ) == PixelCoordinate(x: 99, y: 49)
    )
    for point in [
        ViewerPoint(x: -0.001, y: 100),
        ViewerPoint(x: 200, y: 100),
        ViewerPoint(x: 100, y: -0.001),
        ViewerPoint(x: 100, y: 150),
    ] {
        #expect(
            PixelCoordinate.resolve(
                viewportPoint: point,
                viewerTransform: transform,
                pixelWidth: 100,
                pixelHeight: 50
            ) == nil
        )
    }
}

@Test
func pixelCentersRoundTripThroughZoomedAndPannedViewer() {
    var transform = ViewerTransform(
        imageSize: ViewerSize(width: 100, height: 50),
        viewportSize: ViewerSize(width: 100, height: 100)
    )
    transform.setCustomScale(
        2,
        around: transform.viewportSize.center
    )
    transform.pan(by: ViewerPoint(x: -10, y: 0))
    let pixel = PixelCoordinate(x: 37, y: 12)!
    let center = pixel.viewportCenter(
        viewerTransform: transform,
        pixelWidth: 100,
        pixelHeight: 50
    )

    #expect(center != nil)
    #expect(
        center.flatMap {
            PixelCoordinate.resolve(
                viewportPoint: $0,
                viewerTransform: transform,
                pixelWidth: 100,
                pixelHeight: 50
            )
        } == pixel
    )
    let normalized = pixel.normalizedCenter(
        pixelWidth: 100,
        pixelHeight: 50
    )
    #expect(
        normalized.map {
            probeClose($0.u, 0.375)
                && probeClose($0.v, 0.25)
        } == true
    )
}

@Test
func viewportMappingRejectsNonFiniteInputsAndInvalidGrids() {
    let transform = ViewerTransform(
        imageSize: ViewerSize(width: 100, height: 50),
        viewportSize: ViewerSize(width: 200, height: 200)
    )
    for value in [
        Double.nan,
        Double.infinity,
        -Double.infinity,
    ] {
        #expect(
            PixelCoordinate.resolve(
                viewportX: value,
                viewportY: 100,
                viewerTransform: transform,
                pixelWidth: 100,
                pixelHeight: 50
            ) == nil
        )
        #expect(
            PixelCoordinate.resolve(
                viewportX: 100,
                viewportY: value,
                viewerTransform: transform,
                pixelWidth: 100,
                pixelHeight: 50
            ) == nil
        )
    }
    for dimensions in [
        (width: 0, height: 50),
        (width: 100, height: 0),
        (width: -1, height: 50),
        (width: 100, height: -1),
    ] {
        #expect(
            PixelCoordinate.resolve(
                viewportX: 100,
                viewportY: 100,
                viewerTransform: transform,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height
            ) == nil
        )
    }
}

@Test
func pixelCoordinatesValidateCentersBoundsAndLinearIndices() {
    #expect(PixelCoordinate(x: -1, y: 0) == nil)
    #expect(PixelCoordinate(x: 0, y: -1) == nil)
    let pixel = PixelCoordinate(x: 3, y: 1)!

    #expect(
        pixel.normalizedCenter(
            pixelWidth: 4,
            pixelHeight: 2
        ) == NormalizedScanCoordinate(u: 0.875, v: 0.75)
    )
    #expect(
        pixel.linearIndex(
            pixelWidth: 4,
            pixelHeight: 2
        ) == 7
    )
    #expect(
        pixel.normalizedCenter(
            pixelWidth: 3,
            pixelHeight: 2
        ) == nil
    )
    #expect(
        pixel.linearIndex(
            pixelWidth: 3,
            pixelHeight: 2
        ) == nil
    )
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
            probeClose($0.u, 0.5)
                && probeClose($0.v, 0.25)
        } == true
    )
    let physical = normalized.flatMap {
        transform.physicalCoordinate(for: $0)
    }
    #expect(
        physical.map {
            probeClose($0.x, 15)
                && probeClose($0.y, -7)
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
                probeClose($0.u, coordinate.u)
                    && probeClose($0.v, coordinate.v)
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

@Test
func probeReadingUsesPixelCenterAndDropsNonFiniteValues() {
    let transform = ScanCoordinateTransform(
        rangeX: 80,
        rangeY: 20,
        offsetX: 0,
        offsetY: 0,
        scanDirection: "down"
    )!
    let reading = ProbeReading(
        pixelCoordinate: PixelCoordinate(x: 0, y: 0)!,
        pixelWidth: 4,
        pixelHeight: 2,
        rawValue: .nan,
        processedValue: 12.5,
        channelName: "Current",
        unit: "A",
        scanTransform: transform
    )

    #expect(reading != nil)
    #expect(reading?.rawValue == nil)
    #expect(reading?.processedValue == 12.5)
    #expect(reading?.channelName == "Current")
    #expect(reading?.unit == "A")
    #expect(
        reading?.normalizedCoordinate
            == NormalizedScanCoordinate(u: 0.125, v: 0.25)
    )
    #expect(
        reading?.physicalCoordinate
            == PhysicalScanCoordinate(x: -30, y: 5)
    )

    for value in [
        Double.nan,
        Double.infinity,
        -Double.infinity,
    ] {
        let nonFiniteReading = ProbeReading(
            pixelCoordinate: PixelCoordinate(x: 0, y: 0)!,
            pixelWidth: 4,
            pixelHeight: 2,
            rawValue: value,
            processedValue: value,
            channelName: "Current",
            unit: "A"
        )
        #expect(nonFiniteReading?.rawValue == nil)
        #expect(nonFiniteReading?.processedValue == nil)
    }

    let invalid = ProbeReading(
        pixelCoordinate: PixelCoordinate(x: 4, y: 0)!,
        pixelWidth: 4,
        pixelHeight: 2,
        rawValue: 1,
        processedValue: .infinity,
        channelName: "Current",
        unit: "A"
    )
    #expect(invalid == nil)
}
