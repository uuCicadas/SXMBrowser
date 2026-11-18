import Testing
@testable import SXMBrowserAppCore

@Test
func spectrumPaletteUsesExactStableOkabeItoRGBValuesWithoutYellow() {
    let expected = [
        SpectrumRGBColor(red: 0x00, green: 0x72, blue: 0xB2),
        SpectrumRGBColor(red: 0xD5, green: 0x5E, blue: 0x00),
        SpectrumRGBColor(red: 0x00, green: 0x9E, blue: 0x73),
        SpectrumRGBColor(red: 0xCC, green: 0x79, blue: 0xA7),
        SpectrumRGBColor(red: 0xE6, green: 0x9F, blue: 0x00),
        SpectrumRGBColor(red: 0x56, green: 0xB4, blue: 0xE9),
        SpectrumRGBColor(red: 0x00, green: 0x00, blue: 0x00),
    ]

    #expect(SpectrumVisualStyle.palette == expected)
    #expect(
        !SpectrumVisualStyle.palette.contains(
            SpectrumRGBColor(
                red: 0xF0,
                green: 0xE4,
                blue: 0x42
            )
        )
    )
}

@Test
func spectrumRGBColorPublishesExactNormalizedComponents() {
    let color = SpectrumVisualStyle.palette[0]

    #expect(color.normalizedRed == 0.0 / 255.0)
    #expect(color.normalizedGreen == 114.0 / 255.0)
    #expect(color.normalizedBlue == 178.0 / 255.0)
}

@Test
func spectrumLinePatternsUseFourStableDistinctDashDefinitions() {
    #expect(
        SpectrumVisualStyle.patterns
            == [.solid, .dashed, .dotted, .dashDot]
    )
    #expect(SpectrumLinePattern.solid.dashPattern == [])
    #expect(
        SpectrumLinePattern.dashed.dashPattern == [8, 4]
    )
    #expect(
        SpectrumLinePattern.dotted.dashPattern == [1, 3]
    )
    #expect(
        SpectrumLinePattern.dashDot.dashPattern
            == [8, 3, 1, 3]
    )
    #expect(
        Set(
            SpectrumLinePattern.allCases.map(\.dashPattern)
        ).count == 4
    )
    #expect(
        (0..<4).map {
            SpectrumVisualStyle(index: $0).pattern
        } == [.solid, .dashed, .dotted, .dashDot]
    )
}

@Test
func firstTwentyEightSpectrumStylesAreUniqueAndExposeSlots() {
    let styles = (0..<28).map(
        SpectrumVisualStyle.resolve(index:)
    )

    #expect(SpectrumVisualStyle.cycleLength == 28)
    #expect(Set(styles).count == 28)
    for (index, style) in styles.enumerated() {
        #expect(style.cycleIndex == index)
        #expect(style.paletteIndex == index % 7)
        #expect(style.patternIndex == index % 4)
        #expect(
            style.color
                == SpectrumVisualStyle.palette[index % 7]
        )
        #expect(
            style.pattern
                == SpectrumVisualStyle.patterns[index % 4]
        )
    }
}

@Test
func spectrumStyleResolutionIsStableAndPeriodicForSignedIndices() {
    for index in -112...112 {
        let style = SpectrumVisualStyle.resolve(index: index)

        #expect(
            style
                == SpectrumVisualStyle.resolve(index: index)
        )
        #expect(
            style
                == SpectrumVisualStyle.resolve(
                    index: index + 28
                )
        )
        #expect(
            style
                == SpectrumVisualStyle.resolve(
                    index: index - 28
                )
        )
    }
}

@Test
func euclideanModuloMapsNegativeAndIntegerBoundaryIndicesSafely() {
    #expect(
        SpectrumVisualStyle.euclideanModulo(
            -1,
            modulus: 28
        ) == 27
    )
    #expect(
        SpectrumVisualStyle.euclideanModulo(
            -28,
            modulus: 28
        ) == 0
    )
    #expect(
        SpectrumVisualStyle.euclideanModulo(
            -29,
            modulus: 28
        ) == 27
    )
    #expect(
        SpectrumVisualStyle(index: -1).paletteIndex == 6
    )
    #expect(
        SpectrumVisualStyle(index: -1).patternIndex == 3
    )

    let expectedMinimumIndex =
        Int.bitWidth == 64 ? 20 : 12
    let expectedMaximumIndex =
        Int.bitWidth == 64 ? 7 : 15
    let expectedMinimumPaletteIndex =
        Int.bitWidth == 64 ? 6 : 5
    let expectedMaximumPaletteIndex =
        Int.bitWidth == 64 ? 0 : 1
    let minimumStyle = SpectrumVisualStyle.resolve(
        index: .min
    )
    let maximumStyle = SpectrumVisualStyle.resolve(
        index: .max
    )

    #expect(minimumStyle.cycleIndex == expectedMinimumIndex)
    #expect(maximumStyle.cycleIndex == expectedMaximumIndex)
    #expect(
        minimumStyle.paletteIndex
            == expectedMinimumPaletteIndex
    )
    #expect(minimumStyle.patternIndex == 0)
    #expect(
        maximumStyle.paletteIndex
            == expectedMaximumPaletteIndex
    )
    #expect(maximumStyle.patternIndex == 3)
    #expect(
        minimumStyle
            == SpectrumVisualStyle(
                index: expectedMinimumIndex
            )
    )
    #expect(
        maximumStyle
            == SpectrumVisualStyle(
                index: expectedMaximumIndex
            )
    )
}
