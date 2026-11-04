import Testing
@testable import SXMBrowserCore

@Test
func planeLinearFitRemovesOneGlobalPlaneAndPreservesStructure() {
    // Both profiles have zero mean and zero linear component. The y profile
    // must survive a global plane fit, unlike independent per-row corrections.
    let xStructure: [Float] = [1, -2, 2, -2, 1]
    let yStructure: [Float] = [1, -2, 1]
    var values: [Float] = []
    var expected: [Float] = []
    for y in 0..<3 {
        for x in 0..<5 {
            let structure = xStructure[x] + yStructure[y]
            expected.append(structure)
            values.append(Float(10 + 3 * x - 4 * y) + structure)
        }
    }
    let matrix = Matrix(width: 5, height: 3, values: values)

    let result = SXMRenderer.processedMatrix(matrix, processing: .planeLinear)

    #expect(result.width == 5)
    #expect(result.height == 3)
    for (actual, wanted) in zip(result.values, expected) {
        #expect(abs(actual - wanted) < 0.000_001)
    }
    #expect(matrix.values == values)
}

@Test
func planeLinearFitUsesOriginalCoordinatesAcrossNonFiniteGaps() {
    // Finite residuals [1, -1, 0, -1, 1] are orthogonal to 1, x, and y.
    // The underlying plane is 2 + 3*x - 2*y.
    let matrix = Matrix(
        width: 4,
        height: 3,
        values: [
            3, .nan, .infinity, 10,
            -.infinity, 3, .nan, .nan,
            -3, .nan, .nan, 8,
        ]
    )

    let result = SXMRenderer.processedMatrix(matrix, processing: .planeLinear)

    for (index, residual) in [(0, 1.0), (3, -1.0), (5, 0.0), (8, -1.0), (11, 1.0)] {
        #expect(abs(Double(result.values[index]) - residual) < 0.000_001)
    }
    for index in matrix.values.indices where !matrix.values[index].isFinite {
        #expect(result.values[index].bitPattern == matrix.values[index].bitPattern)
    }
}

@Test
func planeLinearFitPreservesSmallResidualsAboveLargeOffsets() {
    // Independent reference: each row's slope is 2.1 and x intercept is -0.4.
    // The y slope is 10. The old Float-before-subtraction lost these residuals.
    let matrix = Matrix(
        width: 4,
        height: 2,
        values: [
            10_000_000, 10_000_001, 10_000_004, 10_000_006,
            10_000_010, 10_000_011, 10_000_014, 10_000_016,
        ]
    )
    let expected: [Float] = [0.4, -0.7, 0.2, 0.1]

    let result = SXMRenderer.processedMatrix(matrix, processing: .planeLinear)

    for y in 0..<2 {
        for x in 0..<4 {
            #expect(abs(result[x, y] - expected[x]) < 0.000_001)
        }
    }
}

@Test
func planeLinearFitRetainsNanoscaleResidualPrecision() {
    let matrix = Matrix(
        width: 2,
        height: 2,
        values: [1e-7, 1.00003e-7, 1.00009e-7, 1.00010e-7]
    )
    // On a 2x2 grid the residual subspace is exactly [1, -1, -1, 1].
    let z = matrix.values.map(Double.init)
    let residual = ((z[3] - z[2]) - (z[1] - z[0])) / 4
    let expected = [residual, -residual, -residual, residual]

    let result = SXMRenderer.processedMatrix(matrix, processing: .planeLinear)

    for (actual, wanted) in zip(result.values, expected) {
        #expect(abs(Double(actual) - wanted) < 1e-18)
    }
}

@Test
func planeLinearFitLeavesUnderdeterminedGeometryUnchanged() {
    let cases = [
        Matrix(width: 4, height: 1, values: [1, 4, 5, 9]),
        Matrix(width: 1, height: 4, values: [1, 4, 5, 9]),
        Matrix(width: 2, height: 2, values: [1, .nan, .infinity, 9]),
        Matrix(width: 2, height: 2, values: [.nan, .infinity, -.infinity, .nan]),
        Matrix(width: 3, height: 3, values: [1, .nan, .nan, .nan, 4, .nan, .nan, .nan, 9]),
    ]

    for matrix in cases {
        let result = SXMRenderer.processedMatrix(matrix, processing: .planeLinear)
        #expect(result.values.map(\.bitPattern) == matrix.values.map(\.bitPattern))
    }
}

@Test
func planeLinearFitResidualIsOrthogonalToAllPlaneComponents() {
    let matrix = Matrix(
        width: 4,
        height: 3,
        values: [2, 8, 3, .nan, 1, .nan, 6, 13, -2, 5, 3, 7]
    )
    let result = SXMRenderer.processedMatrix(matrix, processing: .planeLinear)
    var constantMoment = 0.0
    var xMoment = 0.0
    var yMoment = 0.0
    for y in 0..<matrix.height {
        for x in 0..<matrix.width where result[x, y].isFinite {
            let residual = Double(result[x, y])
            constantMoment += residual
            xMoment += Double(x) * residual
            yMoment += Double(y) * residual
        }
    }
    // These are the least-squares optimality conditions, independent of the
    // particular coefficient-solving method used in the implementation.
    #expect(abs(constantMoment) < 0.000_002)
    #expect(abs(xMoment) < 0.000_004)
    #expect(abs(yMoment) < 0.000_004)
}
