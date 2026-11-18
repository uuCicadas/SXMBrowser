import AppKit
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private let scaleBarTolerance = 0.000_000_001

private func scaleBarClose(
    _ actual: Double,
    _ expected: Double
) -> Bool {
    abs(actual - expected) <= scaleBarTolerance
}

private func scaleBarTransform(
    pixelWidth: Int = 1_000,
    viewportWidth: Double = 400
) -> ViewerTransform {
    ViewerTransform(
        imageSize: ViewerSize(
            width: Double(pixelWidth),
            height: 500
        ),
        viewportSize: ViewerSize(
            width: viewportWidth,
            height: 400
        )
    )
}

@Test
func scaleBarSelectsNiceLengthNearQuarterOfVisibleImage() {
    var transform = scaleBarTransform()
    transform.showActualSize()

    let bar = ScaleBar.resolve(
        scanRangeX: 1e-6,
        sourcePixelWidth: 1_000,
        viewerTransform: transform,
        availableWidth: 400
    )

    #expect(bar != nil)
    #expect(
        bar.map {
            scaleBarClose(
                $0.physicalLengthMeters,
                100e-9
            )
        } == true
    )
    #expect(
        bar.map {
            scaleBarClose($0.screenLengthPoints, 100)
        } == true
    )
    #expect(bar?.label == "100 nm")
}

@Test
func scaleBarHonorsPreferredAndMaximumScreenBounds() {
    var narrowTransform = scaleBarTransform(
        viewportWidth: 100
    )
    narrowTransform.showActualSize()
    let narrowBar = ScaleBar.resolve(
        scanRangeX: 1e-6,
        sourcePixelWidth: 1_000,
        viewerTransform: narrowTransform,
        availableWidth: 100
    )
    #expect(
        narrowBar.map {
            $0.screenLengthPoints >= 48
                && $0.screenLengthPoints <= 100
        } == true
    )

    var wideTransform = scaleBarTransform(
        viewportWidth: 1_000
    )
    wideTransform.showActualSize()
    let wideBar = ScaleBar.resolve(
        scanRangeX: 1e-6,
        sourcePixelWidth: 1_000,
        viewerTransform: wideTransform,
        availableWidth: 1_000
    )
    #expect(
        wideBar.map {
            $0.screenLengthPoints >= 48
                && $0.screenLengthPoints <= 180
        } == true
    )
}

@Test
func tinyVisibleImagesAllowShorterBarsWithoutOverflowing() {
    var transform = scaleBarTransform(
        viewportWidth: 40
    )
    transform.showActualSize()

    let bar = ScaleBar.resolve(
        scanRangeX: 1e-6,
        sourcePixelWidth: 1_000,
        viewerTransform: transform,
        availableWidth: 40
    )

    #expect(bar != nil)
    #expect(
        bar.map {
            $0.screenLengthPoints > 0
                && $0.screenLengthPoints <= 40
                && $0.screenLengthPoints < 48
        } == true
    )
}

@Test
func fitActualAndMaximumZoomKeepPhysicalPointMapping() {
    var fitTransform = scaleBarTransform()
    let fitBar = ScaleBar.resolve(
        scanRangeX: 1e-6,
        sourcePixelWidth: 1_000,
        viewerTransform: fitTransform,
        availableWidth: 400
    )

    fitTransform.showActualSize()
    let actualBar = ScaleBar.resolve(
        scanRangeX: 1e-6,
        sourcePixelWidth: 1_000,
        viewerTransform: fitTransform,
        availableWidth: 400
    )

    fitTransform.setCustomScale(16)
    let maximumZoomBar = ScaleBar.resolve(
        scanRangeX: 1e-6,
        sourcePixelWidth: 1_000,
        viewerTransform: fitTransform,
        availableWidth: 400
    )

    for (bar, scale) in [
        (fitBar, 0.4),
        (actualBar, 1.0),
        (maximumZoomBar, 16.0),
    ] {
        #expect(
            bar.map {
                scaleBarClose(
                    $0.screenLengthPoints,
                    $0.physicalLengthMeters
                        / 1e-6
                        * 1_000
                        * scale
                )
            } == true
        )
    }
}

@Test
func panningDoesNotChangeScaleBarSelection() {
    var transform = scaleBarTransform()
    transform.setCustomScale(2)
    let before = ScaleBar.resolve(
        scanRangeX: 2e-6,
        sourcePixelWidth: 1_000,
        viewerTransform: transform,
        availableWidth: 400
    )

    transform.pan(by: ViewerPoint(x: -275, y: -125))
    let after = ScaleBar.resolve(
        scanRangeX: 2e-6,
        sourcePixelWidth: 1_000,
        viewerTransform: transform,
        availableWidth: 400
    )

    #expect(after == before)
}

@Test(
    arguments: [
        (scanRange: 50e-12, expected: "5 pm"),
        (scanRange: 50e-9, expected: "5 nm"),
        (scanRange: 50e-6, expected: "5 µm"),
        (scanRange: 50e-3, expected: "5 mm"),
        (scanRange: 50.0, expected: "5 m"),
    ]
)
func scaleBarFormatsEngineeringSILabels(
    scanRange: Double,
    expected: String
) {
    var transform = scaleBarTransform(
        viewportWidth: 100
    )
    transform.showActualSize()

    let bar = ScaleBar.resolve(
        scanRangeX: scanRange,
        sourcePixelWidth: 1_000,
        viewerTransform: transform,
        availableWidth: 100
    )

    #expect(bar?.label == expected)
}

@Test
func invalidOrNonFiniteInputsReturnNil() {
    let validTransform = scaleBarTransform()
    for scanRange in [
        0,
        -1,
        Double.nan,
        Double.infinity,
        -Double.infinity,
    ] {
        #expect(
            ScaleBar.resolve(
                scanRangeX: scanRange,
                sourcePixelWidth: 1_000,
                viewerTransform: validTransform,
                availableWidth: 400
            ) == nil
        )
    }
    for pixelWidth in [0, -1] {
        #expect(
            ScaleBar.resolve(
                scanRangeX: 1e-6,
                sourcePixelWidth: pixelWidth,
                viewerTransform: validTransform,
                availableWidth: 400
            ) == nil
        )
    }
    for availableWidth in [
        0,
        -1,
        Double.nan,
        Double.infinity,
        -Double.infinity,
    ] {
        #expect(
            ScaleBar.resolve(
                scanRangeX: 1e-6,
                sourcePixelWidth: 1_000,
                viewerTransform: validTransform,
                availableWidth: availableWidth
            ) == nil
        )
    }

    #expect(
        ScaleBar.resolve(
            scanRangeX: 1e-6,
            sourcePixelWidth: 1_000,
            viewerTransform: ViewerTransform(),
            availableWidth: 400
        ) == nil
    )
    #expect(
        ScaleBar.resolve(
            scanRangeX: Double.leastNonzeroMagnitude,
            sourcePixelWidth: Int.max,
            viewerTransform: validTransform,
            availableWidth: 400
        ) == nil
    )
}

@Test
func scaleBarStateDoesNotAlterPurePNGExport() throws {
    let matrix = Matrix(
        width: 3,
        height: 2,
        values: [0, 1, 2, 3, 4, 5]
    )
    let options = RenderOptions(
        channel: "Z",
        direction: .fwd,
        processing: .raw,
        palette: .gray,
        vmin: 0,
        vmax: 5
    )
    let before = try SXMRenderer.pngData(
        matrix: matrix,
        options: options
    )

    var transform = ViewerTransform(
        imageSize: ViewerSize(width: 3, height: 2),
        viewportSize: ViewerSize(width: 600, height: 400)
    )
    _ = ScaleBar.resolve(
        scanRangeX: 300e-9,
        sourcePixelWidth: 3,
        viewerTransform: transform,
        availableWidth: 400
    )
    transform.setCustomScale(16)
    transform.pan(by: ViewerPoint(x: -20, y: -10))
    _ = ScaleBar.resolve(
        scanRangeX: 300e-9,
        sourcePixelWidth: 3,
        viewerTransform: transform,
        availableWidth: 400
    )

    let after = try SXMRenderer.pngData(
        matrix: matrix,
        options: options
    )
    let representation = try #require(
        NSBitmapImageRep(data: after)
    )
    #expect(before == after)
    #expect(representation.pixelsWide == 3)
    #expect(representation.pixelsHigh == 2)
}
