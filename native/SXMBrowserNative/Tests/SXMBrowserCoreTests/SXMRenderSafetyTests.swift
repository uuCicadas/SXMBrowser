import CoreGraphics
import Foundation
import ImageIO
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

@Test
func renderedImagesAndPNGExportUseExplicitSRGBAndBackgroundSafeDownsampling() async throws {
    let matrix = Matrix(
        width: 256,
        height: 128,
        values: (0..<(256 * 128)).map(Float.init)
    )

    let fullImage = try SXMRenderer.renderImage(
        matrix: matrix,
        options: RenderOptions(
            channel: "Z",
            direction: .fwd,
            processing: .raw,
            palette: .duskViolet
        )
    )
    let fullCG = try #require(fullImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(fullCG.colorSpace?.name == CGColorSpace.sRGB)

    let thumbDims: (width: Int, height: Int, colorSpaceName: String?) = try await Task.detached {
        let thumb = try SXMRenderer.renderImage(
            matrix: matrix,
            options: RenderOptions(
                channel: "Z",
                direction: .fwd,
                processing: .raw,
                palette: .duskViolet,
                outputSize: 64
            )
        )
        let cg = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return (Int(thumb.size.width), Int(thumb.size.height), cg.colorSpace?.name as String?)
    }.value

    #expect(thumbDims.width == 64)
    #expect(thumbDims.height == 32)
    #expect(thumbDims.colorSpaceName == (CGColorSpace.sRGB as String))

    let png = try SXMRenderer.pngData(
        matrix: matrix,
        options: RenderOptions(
            channel: "Z",
            direction: .fwd,
            processing: .raw,
            palette: .duskViolet
        )
    )
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let decodedCG = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decodedCG.colorSpace?.name == CGColorSpace.sRGB)
}
