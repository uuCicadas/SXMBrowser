import Foundation
import Testing
@testable import SXMBrowserCore

@Test
func matrixStatisticsAreIndependentOfHistogramBins() throws {
    let matrix = Matrix(
        width: 4,
        height: 2,
        values: [-4, -1, 0, 2, 8, .nan, .infinity, 16]
    )
    let statistics = try #require(SXMRenderer.statistics(matrix))
    let histogram64 = try #require(SXMRenderer.histogram(matrix, bins: 64))
    let histogram512 = try #require(SXMRenderer.histogram(matrix, bins: 512))

    #expect(histogram64.statistics == statistics)
    #expect(histogram512.statistics == statistics)
    #expect(histogram64.statistics == histogram512.statistics)
    #expect(histogram64.bins == 64)
    #expect(histogram512.bins == 512)
}

@Test
func cachedStatisticsCanRebinWithoutChangingTotals() throws {
    let matrix = Matrix(
        width: 5,
        height: 2,
        values: [-10, -5, -1, 0, 1, 5, 10, .nan, .infinity, -.infinity]
    )
    let statistics = try #require(SXMRenderer.statistics(matrix))
    let histogram16 = SXMRenderer.histogram(
        matrix,
        statistics: statistics,
        bins: 16
    )
    let histogram1024 = SXMRenderer.histogram(
        matrix,
        statistics: statistics,
        bins: 1024
    )

    #expect(histogram16.counts.reduce(0, +) == statistics.count)
    #expect(histogram1024.counts.reduce(0, +) == statistics.count)
    #expect(histogram16.edges.count == histogram16.bins + 1)
    #expect(histogram1024.edges.count == histogram1024.bins + 1)
    #expect(histogram16.edges.first == statistics.min)
    #expect(histogram16.edges.last == statistics.max)
    #expect(histogram1024.edges.first == statistics.min)
    #expect(histogram1024.edges.last == statistics.max)
}

@Test
func reusableStatisticsPreserveConstantAndAllNaNBehavior() throws {
    let constant = Matrix(
        width: 3,
        height: 1,
        values: [7.25, 7.25, 7.25]
    )
    let statistics = try #require(SXMRenderer.statistics(constant))
    let histogram = SXMRenderer.histogram(
        constant,
        statistics: statistics,
        bins: 64
    )

    #expect(statistics.min == 7.25)
    #expect(statistics.max == 7.25)
    #expect(statistics.mean == 7.25)
    #expect(statistics.std == 0)
    #expect(histogram.counts[32] == 3)
    #expect(histogram.edges.allSatisfy { $0 == 7.25 })

    let allNaN = Matrix(width: 2, height: 1, values: [.nan, .nan])
    #expect(SXMRenderer.statistics(allNaN) == nil)
    #expect(SXMRenderer.histogram(allNaN, bins: 64) == nil)
    #expect(SXMRenderer.automaticScale(allNaN) == nil)
}

@Test
func automaticScaleFromStatisticsMatchesMatrixConvenience() throws {
    let matrix = Matrix(
        width: 5,
        height: 2,
        values: [-100, -4, -2, -1, 0, 1, 2, 4, 100, .nan]
    )
    let statistics = try #require(SXMRenderer.statistics(matrix))
    let direct = try #require(SXMRenderer.automaticScale(matrix))
    let reused = SXMRenderer.automaticScale(statistics)

    #expect(direct.vmin == reused.vmin)
    #expect(direct.vmax == reused.vmax)
    #expect(direct.vmin == statistics.min)
    #expect(direct.vmax == statistics.max)
}

@Test
func matrixStatisticsUseNumericallyStableVariance() throws {
    let values = (0..<10_000).map { index -> Float in
        let offset = (index * 37) % 2_001 - 1_000
        return Float(1_000_000_000 + offset)
    }
    let matrix = Matrix(width: values.count, height: 1, values: values)
    let statistics = try #require(SXMRenderer.statistics(matrix))

    let doubles = values.map(Double.init)
    let expectedMean = doubles.reduce(0, +) / Double(doubles.count)
    let expectedVariance = doubles.reduce(0) { partial, value in
        let deviation = value - expectedMean
        return partial + deviation * deviation
    } / Double(doubles.count)
    let expectedStandardDeviation = sqrt(expectedVariance)

    #expect(abs(statistics.mean - expectedMean) < 0.000_01)
    #expect(abs(statistics.std - expectedStandardDeviation) < 0.000_001)
}
