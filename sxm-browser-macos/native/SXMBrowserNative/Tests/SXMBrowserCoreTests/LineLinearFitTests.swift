import Testing
@testable import SXMBrowserCore

@Test
func lineLinearFitRemovesIndependentRowBackgroundsAndPreservesStructure() {
    // This structure is orthogonal to both a constant and a linear ramp.
    let structure: [Float] = [1, -2, 2, -2, 1]
    let first = structure.enumerated().map { index, value in
        Float(10 + 3 * index) + value
    }
    let second = structure.enumerated().map { index, value in
        Float(-7 - 2 * index) + 2 * value
    }
    let matrix = Matrix(width: 5, height: 2, values: first + second)

    let result = SXMRenderer.processedMatrix(matrix, processing: .lineLinear)

    #expect(result.width == matrix.width)
    #expect(result.height == matrix.height)
    #expect(result.values == structure + structure.map { 2 * $0 })
    #expect(matrix.values == first + second)
}

@Test
func lineLinearFitUsesOriginalPositionsAcrossNonFiniteGaps() {
    // The finite samples are at x = 0, 1, 3, 6. Their residuals have zero
    // mean and zero dot product with x, so the fitted line is 2 + 3*x.
    let matrix = Matrix(
        width: 7,
        height: 1,
        values: [3, 5, .nan, 9, .infinity, -.infinity, 21]
    )

    let result = SXMRenderer.processedMatrix(matrix, processing: .lineLinear)

    #expect(result[0, 0] == 1)
    #expect(result[1, 0] == 0)
    #expect(result[2, 0].isNaN)
    #expect(result[3, 0] == -2)
    #expect(result[4, 0] == .infinity)
    #expect(result[5, 0] == -.infinity)
    #expect(result[6, 0] == 1)
}

@Test
func lineLinearFitLeavesUnderdeterminedRowsUnchanged() {
    let matrix = Matrix(
        width: 3,
        height: 3,
        values: [
            .nan, .infinity, -.infinity,
            .nan, 7, .infinity,
            5, .nan, 9,
        ]
    )

    let result = SXMRenderer.processedMatrix(matrix, processing: .lineLinear)

    #expect(result[0, 0].isNaN)
    #expect(result[1, 0] == .infinity)
    #expect(result[2, 0] == -.infinity)
    #expect(result[0, 1].isNaN)
    #expect(result[1, 1] == 7)
    #expect(result[2, 1] == .infinity)
    #expect(result[0, 2] == 0)
    #expect(result[1, 2].isNaN)
    #expect(result[2, 2] == 0)

    let singleColumn = Matrix(width: 1, height: 2, values: [5, -9])
    let singleColumnResult = SXMRenderer.processedMatrix(singleColumn, processing: .lineLinear)
    #expect(singleColumnResult.values == singleColumn.values)
}

@Test
func lineLinearFitPreservesSmallResidualsAboveLargeOffsets() {
    let matrix = Matrix(
        width: 4,
        height: 2,
        values: [0, 1, 4, 6, 10_000_000, 10_000_001, 10_000_004, 10_000_006]
    )
    // Both rows have slope 2.1; their intercepts differ by exactly 10,000,000.
    let expected: [Float] = [0.4, -0.7, 0.2, 0.1]

    let result = SXMRenderer.processedMatrix(matrix, processing: .lineLinear)

    for y in 0..<2 {
        for x in 0..<4 {
            #expect(abs(result[x, y] - expected[x]) < 0.000_001)
        }
    }
}

@Test
func lineLinearFitRetainsNanoscaleResidualPrecision() {
    let matrix = Matrix(
        width: 4,
        height: 1,
        values: [1e-7, 1.00003e-7, 1.00009e-7, 1.00010e-7]
    )
    // Exact residual projection for x = 0...3, expressed as integer weights
    // to keep the reference independent of the renderer's fitted coefficients.
    let weights = [
        [3, -4, -1, 2],
        [-4, 7, -2, -1],
        [-1, -2, 7, -4],
        [2, -1, -4, 3],
    ]
    let baseline = Double(matrix.values[0])
    let centered = matrix.values.map { Double($0) - baseline }
    let expected = weights.map { row in
        zip(row, centered).reduce(0.0) { $0 + Double($1.0) * $1.1 } / 10
    }

    let result = SXMRenderer.processedMatrix(matrix, processing: .lineLinear)

    for x in 0..<4 {
        #expect(abs(Double(result[x, 0]) - expected[x]) < 1e-18)
    }
}
