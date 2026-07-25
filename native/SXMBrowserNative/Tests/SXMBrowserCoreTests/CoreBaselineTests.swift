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
func defaultDisplayRulesDistinguishSTMAndAFMChannels() {
    #expect(classifyChannel("Z") == .stm)
    #expect(defaultProcessing(for: "Z") == .lineLinear)
    #expect(defaultPalette(for: "Z") == .flame)

    #expect(classifyChannel("OC_M1_Freq._Shift") == .afm)
    #expect(defaultProcessing(for: "OC_M1_Freq._Shift") == .raw)
    #expect(defaultPalette(for: "OC_M1_Freq._Shift") == .gray)
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
