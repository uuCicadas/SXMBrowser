import Testing
@testable import SXMBrowserAppCore

private let transformTolerance = 0.000_000_1

private func isClose(
    _ actual: Double,
    _ expected: Double
) -> Bool {
    abs(actual - expected) <= transformTolerance
}

private func isClose(
    _ actual: ViewerPoint?,
    _ expected: ViewerPoint
) -> Bool {
    guard let actual else { return false }
    return isClose(actual.x, expected.x)
        && isClose(actual.y, expected.y)
}

@Test
func fitCentersImagesAndMayGoBelowManualMinimum() {
    var transform = ViewerTransform(
        imageSize: ViewerSize(width: 4_000, height: 2_000),
        viewportSize: ViewerSize(width: 800, height: 600)
    )

    #expect(transform.mode == .fit)
    #expect(isClose(transform.scale, 0.2))
    #expect(isClose(transform.translation.x, 0))
    #expect(isClose(transform.translation.y, 100))

    transform.reconcile(
        imageSize: ViewerSize(width: 20, height: 10),
        viewportSize: ViewerSize(width: 800, height: 600)
    )
    #expect(isClose(transform.scale, 16))
    #expect(isClose(transform.translation.x, 240))
    #expect(isClose(transform.translation.y, 220))
}

@Test
func actualSizeAndCustomScaleClampToTwentyFiveThroughSixteenHundredPercent() {
    var transform = ViewerTransform(
        imageSize: ViewerSize(width: 1_000, height: 800),
        viewportSize: ViewerSize(width: 500, height: 400)
    )

    transform.showActualSize()
    #expect(transform.mode == .custom)
    #expect(isClose(transform.scale, 1))
    #expect(isClose(transform.zoomPercentage, 100))

    transform.setCustomScale(0.01)
    #expect(isClose(transform.scale, 0.25))
    transform.setCustomScale(100)
    #expect(isClose(transform.scale, 16))
    transform.setCustomScale(-.infinity)
    #expect(isClose(transform.scale, 0.25))
    transform.setCustomScale(.infinity)
    #expect(isClose(transform.scale, 16))

    let beforeNaN = transform
    transform.setCustomScale(.nan)
    #expect(transform == beforeNaN)
}

@Test
func zoomAroundAnchorPreservesTheImagePointUnderThatAnchor() {
    var transform = ViewerTransform(
        imageSize: ViewerSize(width: 1_000, height: 1_000),
        viewportSize: ViewerSize(width: 500, height: 500)
    )
    transform.showActualSize()
    transform.pan(by: ViewerPoint(x: -100, y: -150))
    let anchor = ViewerPoint(x: 125, y: 300)
    let before = transform.imagePoint(at: anchor)

    transform.zoom(by: 2, around: anchor)

    #expect(transform.mode == .custom)
    #expect(isClose(transform.scale, 2))
    #expect(
        before.map {
            isClose(transform.imagePoint(at: anchor), $0)
        } == true
    )
}

@Test
func panningClampsLargeImagesAndCentersSmallerAxes() {
    var transform = ViewerTransform(
        imageSize: ViewerSize(width: 1_000, height: 200),
        viewportSize: ViewerSize(width: 500, height: 500)
    )
    transform.showActualSize()

    transform.pan(by: ViewerPoint(x: 1_000, y: 100))
    #expect(isClose(transform.translation.x, 0))
    #expect(isClose(transform.translation.y, 150))

    transform.pan(by: ViewerPoint(x: -2_000, y: -100))
    #expect(isClose(transform.translation.x, -500))
    #expect(isClose(transform.translation.y, 150))
}

@Test
func viewportChangesPreserveTheCustomImagePointAtTheCenter() {
    var transform = ViewerTransform(
        imageSize: ViewerSize(width: 2_000, height: 1_600),
        viewportSize: ViewerSize(width: 800, height: 600)
    )
    transform.showActualSize()
    transform.pan(by: ViewerPoint(x: -350, y: -275))
    let oldCenterPoint = transform.imagePoint(
        at: transform.viewportSize.center
    )

    transform.reconcile(
        imageSize: transform.imageSize,
        viewportSize: ViewerSize(width: 1_000, height: 700)
    )

    #expect(
        oldCenterPoint.map {
            isClose(
                transform.imagePoint(
                    at: transform.viewportSize.center
                ),
                $0
            )
        } == true
    )
}

@Test
func imageSizeChangesPreserveAndClampTheCustomCenterPoint() {
    var transform = ViewerTransform(
        imageSize: ViewerSize(width: 2_000, height: 1_600),
        viewportSize: ViewerSize(width: 800, height: 600)
    )
    transform.showActualSize()
    transform.pan(by: ViewerPoint(x: -900, y: -700))
    let preserved = transform.imagePoint(
        at: transform.viewportSize.center
    )

    transform.reconcile(
        imageSize: ViewerSize(width: 1_500, height: 1_200),
        viewportSize: transform.viewportSize
    )
    #expect(preserved != nil)
    #expect(
        isClose(
            transform.imagePoint(
                at: transform.viewportSize.center
            ),
            ViewerPoint(x: 1_100, y: 900)
        )
    )
}

@Test
func fitModeRecomputesAndRecentersAfterGeometryChanges() {
    var transform = ViewerTransform(
        imageSize: ViewerSize(width: 1_000, height: 500),
        viewportSize: ViewerSize(width: 500, height: 500)
    )
    #expect(isClose(transform.scale, 0.5))
    #expect(isClose(transform.translation.y, 125))

    transform.reconcile(
        imageSize: ViewerSize(width: 600, height: 1_200),
        viewportSize: ViewerSize(width: 900, height: 600)
    )

    #expect(transform.mode == .fit)
    #expect(isClose(transform.scale, 0.5))
    #expect(isClose(transform.translation.x, 300))
    #expect(isClose(transform.translation.y, 0))
}

@Test
func invalidGeometryAndInvalidGesturesConvergeToFiniteState() {
    var transform = ViewerTransform(
        imageSize: ViewerSize(width: .nan, height: -.infinity),
        viewportSize: ViewerSize(width: -1, height: 0)
    )

    #expect(transform.imageSize == .zero)
    #expect(transform.viewportSize == .zero)
    #expect(isClose(transform.scale, 1))
    #expect(transform.translation == .zero)
    #expect(transform.imagePoint(at: .zero) == nil)

    transform.zoom(
        by: .nan,
        around: ViewerPoint(x: .infinity, y: .nan)
    )
    transform.pan(
        by: ViewerPoint(x: .infinity, y: -.infinity)
    )
    transform.reconcile(
        imageSize: ViewerSize(width: 800, height: 600),
        viewportSize: ViewerSize(width: 400, height: 300)
    )

    #expect(transform.mode == .fit)
    #expect(isClose(transform.scale, 0.5))
    #expect(transform.translation == .zero)
}
