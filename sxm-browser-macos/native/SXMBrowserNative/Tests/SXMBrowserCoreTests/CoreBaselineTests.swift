import Testing
@testable import SXMBrowserCore

@Test
func headerParserStopsAtScanEnd() {
    let header = parseHeader(
        """
        :SCAN_PIXELS:
        4 3
        :COMMENT:
        first
        second
        :SCANIT_END:
        ignored
        """
    )

    #expect(header["SCAN_PIXELS"] == "4 3")
    #expect(header["COMMENT"] == "first\nsecond")
    #expect(header["SCANIT_END"] == nil)
}

@Test
func defaultDisplayRulesUseSTMPlaneFitAndAFMRawWithChannelPalette() {
    for channel in ["Z", "Z (m)", "Height", "Topography"] {
        #expect(classifyChannel(channel) == .topography)
        #expect(defaultProcessing(for: channel) == .planeLinear)
        #expect(defaultPalette(for: channel) == .duskViolet)
    }

    for channel in ["Current", "Current (A)", "LI Demod 1 X", "dI/dV"] {
        #expect(classifyChannel(channel) == .conductanceOrCurrent)
        #expect(defaultProcessing(for: channel) == .raw)
        #expect(defaultPalette(for: channel) == .duskViolet)
    }

    for channel in ["OC_M1_Freq._Shift", "Frequency Shift", "Amplitude", "Excitation", "PLL", "Δf"] {
        #expect(classifyChannel(channel) == .afm)
        #expect(defaultProcessing(for: channel) == .raw)
        #expect(defaultPalette(for: channel) == .gray)
    }
}

@Test
func engineeringDoubleParsesSISuffixesScientificAndNegatives() {
    func expectClose(_ raw: String, _ expected: Double) {
        let parsed = parseEngineeringDouble(raw)
        #expect(parsed != nil)
        if let parsed {
            #expect(abs(parsed - expected) <= abs(expected) * 1e-12 + 1e-30)
        }
    }

    expectClose("200p", 200e-12)
    expectClose("-1.5n", -1.5e-9)
    expectClose("500u", 500e-6)
    expectClose("10µ", 10e-6)
    expectClose("-0.5", -0.5)
    expectClose("1.5e-9", 1.5e-9)
    expectClose("1.2k", 1200)
    #expect(parseEngineeringDouble("1.5e") == nil)
    #expect(parseEngineeringDouble("NaN") == nil)
}

@Test
func lineMeanProcessingCentersEachFiniteRow() {
    let matrix = Matrix(
        width: 3,
        height: 2,
        values: [1, 2, 3, 10, 11, 12]
    )

    let processed = SXMRenderer.processedMatrix(matrix, processing: .lineMean)

    #expect(processed.values == [-1, 0, 1, -1, 0, 1])
}

@Test
func lineSlopeProcessingPreservesEachRowAverage() {
    let matrix = Matrix(
        width: 4,
        height: 2,
        values: [10, 12, 14, 16, 30, 29, 28, 27]
    )

    let processed = SXMRenderer.processedMatrix(matrix, processing: .lineSlope)

    #expect(processed.values == [13, 13, 13, 13, 28.5, 28.5, 28.5, 28.5])
}

@Test
func lineAverageAndSlopeProcessingCentersEachRow() {
    let matrix = Matrix(
        width: 4,
        height: 2,
        values: [10, 12, 14, 16, 30, 29, 28, 27]
    )

    let processed = SXMRenderer.processedMatrix(matrix, processing: .lineLinear)

    #expect(processed.values.allSatisfy { abs($0) < 0.000_01 })
}

@Test
func lineDifferentiateUsesCenteredInteriorDifferences() {
    let matrix = Matrix(
        width: 4,
        height: 1,
        values: [0, 1, 4, 9]
    )

    let processed = SXMRenderer.processedMatrix(matrix, processing: .lineDerivative)

    #expect(processed.values == [1, 2, 4, 5])
}

@Test
func histogramIgnoresNonFiniteValues() throws {
    let matrix = Matrix(
        width: 2,
        height: 2,
        values: [1, .nan, 3, .infinity]
    )

    let stats = try #require(SXMRenderer.histogram(matrix, bins: 64))

    #expect(stats.count == 2)
    #expect(stats.min == 1)
    #expect(stats.max == 3)
    #expect(stats.hist.reduce(0, +) == 2)
}
