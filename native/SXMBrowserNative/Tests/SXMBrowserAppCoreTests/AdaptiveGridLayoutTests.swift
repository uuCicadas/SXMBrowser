import Testing
@testable import SXMBrowserAppCore

@Test
func gridDensityUsesRequiredMinimumCardWidthsAndMigration() {
    #expect(GridDensity.compact.minimumCardWidth == 120)
    #expect(GridDensity.comfortable.minimumCardWidth == 160)
    #expect(GridDensity.large.minimumCardWidth == 220)

    #expect(GridDensity.migrating(legacyColumnCount: 2) == .large)
    #expect(GridDensity.migrating(legacyColumnCount: 3) == .comfortable)
    #expect(GridDensity.migrating(legacyColumnCount: 4) == .comfortable)
    #expect(GridDensity.migrating(legacyColumnCount: 5) == .compact)
    #expect(GridDensity.migrating(legacyColumnCount: 8) == .compact)
    #expect(GridDensity.migrating(legacyColumnCount: 0) == .comfortable)
}

@Test
func adaptiveGridColumnCountUsesTheSamePaddingAndSpacingAsTheView() {
    let oneColumnWidth = 2 * 18.0 + 120
    let twoColumnWidth = 2 * 18.0 + 2 * 120 + 14

    #expect(
        AdaptiveGridMetrics(
            containerWidth: oneColumnWidth,
            density: .compact
        ).columnCount == 1
    )
    #expect(
        AdaptiveGridMetrics(
            containerWidth: twoColumnWidth.nextDown,
            density: .compact
        ).columnCount == 1
    )
    #expect(
        AdaptiveGridMetrics(
            containerWidth: twoColumnWidth,
            density: .compact
        ).columnCount == 2
    )

    #expect(
        AdaptiveGridMetrics(
            containerWidth: 2 * 18.0 + 3 * 160 + 2 * 14,
            density: .comfortable
        ).columnCount == 3
    )
    #expect(
        AdaptiveGridMetrics(
            containerWidth: 2 * 18.0 + 2 * 220 + 14,
            density: .large
        ).columnCount == 2
    )
}

@Test
func adaptiveGridInvalidAndNarrowWidthsAlwaysProduceOneColumn() {
    for width in [
        -Double.infinity,
        -1,
        0,
        40,
        Double.nan,
    ] {
        #expect(
            AdaptiveGridMetrics(
                containerWidth: width,
                density: .large
            ).columnCount == 1
        )
    }
}

@Test
func adaptiveGridNavigationUsesTheResolvedVisualColumnCount() {
    #expect(
        AdaptiveGridNavigation.selectionDelta(
            for: .left,
            columnCount: 4
        ) == -1
    )
    #expect(
        AdaptiveGridNavigation.selectionDelta(
            for: .right,
            columnCount: 4
        ) == 1
    )
    #expect(
        AdaptiveGridNavigation.selectionDelta(
            for: .up,
            columnCount: 4
        ) == -4
    )
    #expect(
        AdaptiveGridNavigation.selectionDelta(
            for: .down,
            columnCount: 4
        ) == 4
    )
    #expect(
        AdaptiveGridNavigation.selectionDelta(
            for: .down,
            columnCount: 0
        ) == 1
    )
}
