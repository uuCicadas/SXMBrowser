import Testing
@testable import SXMBrowserCore

@Test
func constantMatrixPreservesPhysicalStatistics() throws {
    let matrix = Matrix(
        width: 2,
        height: 2,
        values: [7.25, 7.25, 7.25, 7.25]
    )
    let stats = try #require(SXMRenderer.histogram(matrix, bins: 64))

    #expect(stats.count == 4)
    #expect(stats.min == 7.25)
    #expect(stats.max == 7.25)
    #expect(stats.p1 == 7.25)
    #expect(stats.p99 == 7.25)
    #expect(stats.mean == 7.25)
    #expect(stats.std == 0)
    #expect(stats.hist.reduce(0, +) == 4)
    #expect(stats.hist[32] == 4)
    #expect(stats.edges.allSatisfy { $0 == 7.25 })
}

@Test
func nanoscaleConstantDoesNotGainArtificialRange() throws {
    let constant: Float = 1e-9
    let matrix = Matrix(
        width: 2,
        height: 1,
        values: [constant, constant]
    )
    let stats = try #require(SXMRenderer.histogram(matrix))
    let scale = try #require(SXMRenderer.automaticScale(matrix))

    #expect(stats.min == Double(constant))
    #expect(stats.max == Double(constant))
    #expect(scale.vmin == Double(constant))
    #expect(scale.vmax == Double(constant))
}

@Test
func constantGrayImageUsesPaletteMidpoint() {
    let matrix = Matrix(width: 2, height: 1, values: [3, 3])
    let scale = SXMRenderer.automaticScale(matrix)
    #expect(scale?.vmin == 3)
    #expect(scale?.vmax == 3)

    let automatic = SXMRenderer.colorize(
        matrix: matrix,
        palette: .gray,
        vmin: nil,
        vmax: nil,
        invert: false
    )
    let explicit = SXMRenderer.colorize(
        matrix: matrix,
        palette: .gray,
        vmin: 3,
        vmax: 3,
        invert: false
    )
    let inverted = SXMRenderer.colorize(
        matrix: matrix,
        palette: .gray,
        vmin: nil,
        vmax: nil,
        invert: true
    )
    let expected: [UInt8] = [
        128, 128, 128, 255,
        128, 128, 128, 255,
    ]

    #expect(automatic == expected)
    #expect(explicit == expected)
    #expect(inverted == expected)
}

@Test
func nonconstantGrayImageStillUsesBothEndpoints() {
    let matrix = Matrix(width: 2, height: 1, values: [0, 10])
    let rgba = SXMRenderer.colorize(
        matrix: matrix,
        palette: .gray,
        vmin: 0,
        vmax: 10,
        invert: false
    )

    #expect(
        rgba == [
            0, 0, 0, 255,
            255, 255, 255, 255,
        ]
    )
}

@Test
func allNaNMatrixHasNoStatisticsOrAutomaticScale() {
    let matrix = Matrix(width: 2, height: 1, values: [.nan, .nan])

    #expect(SXMRenderer.histogram(matrix) == nil)
    #expect(SXMRenderer.automaticScale(matrix) == nil)
}
