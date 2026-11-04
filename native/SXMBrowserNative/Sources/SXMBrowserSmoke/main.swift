import AppKit
import Foundation
import SXMBrowserCore

private enum SmokeFailure: Error {
    case usage(String)
    case input(String)
    case contract(String)

    var exitCode: Int32 {
        switch self {
        case .usage:
            64
        case .input:
            66
        case .contract:
            1
        }
    }

    var reason: String {
        switch self {
        case .usage(let reason), .input(let reason), .contract(let reason):
            reason
        }
    }
}

private struct PixelDimensions {
    let width: Int
    let height: Int
}

private struct FirstRenderFixture {
    let filename: String
    let channel: String
    let direction: ScanDirection
    let matrix: Matrix
}

private let expectedSXMDimensions: [String: PixelDimensions] = [
    "Au1110145.sxm": PixelDimensions(width: 112, height: 112),
    "Au1110191.sxm": PixelDimensions(width: 112, height: 112),
    "Au1110363.sxm": PixelDimensions(width: 112, height: 112),
    "Au1110365.sxm": PixelDimensions(width: 512, height: 512),
    "Au1110410.sxm": PixelDimensions(width: 112, height: 112),
    "Au1110419.sxm": PixelDimensions(width: 112, height: 112),
]

private let expectedDATNames: Set<String> = [
    "Au1110145Z-Spectroscopy-1.dat",
    "Au1110145Z-Spectroscopy-2.dat",
    "Au1110145Z-Spectroscopy-3.dat",
    "Au1110145Z-Spectroscopy-4.dat",
    "Au1110145Z-Spectroscopy-5.dat",
    "Au1110191Z-Spectroscopy-1.dat",
    "Au1110191Z-Spectroscopy-2dat.dat",
    "Au1110191Z-Spectroscopy-3.dat",
    "Au1110363Bias-Spectroscopy-1.dat",
    "Au1110363Bias-Spectroscopy-2.dat",
    "Au1110365Bias-Spectroscopy-1.dat",
    "Au1110365Bias-Spectroscopy-2.dat",
    "Au1110410Z-Spectroscopy-1.dat",
    "Au1110410Z-Spectroscopy-2.dat",
    "Au1110410Z-Spectroscopy-3.dat",
    "Au1110419Z-Spectroscopy-1.dat",
    "Au1110419Z-Spectroscopy-2.dat",
    "Au1110419Z-Spectroscopy-3.dat",
]

private func canonicalSampleFolder() throws -> URL {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2,
          arguments[0] == "--canonical-sample",
          !arguments[1].isEmpty else {
        throw SmokeFailure.usage(
            "Usage: SXMBrowserSmoke --canonical-sample <directory>"
        )
    }

    let folder = URL(
        fileURLWithPath: arguments[1],
        isDirectory: true
    ).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: folder.path,
        isDirectory: &isDirectory
    ), isDirectory.boolValue,
       FileManager.default.isReadableFile(atPath: folder.path) else {
        throw SmokeFailure.input(
            "Canonical sample directory is missing or unreadable: "
                + folder.path
        )
    }
    return folder
}

private func verifyCanonicalNames(
    actual: [String],
    expected: Set<String>,
    kind: String
) throws {
    let actualNames = Set(actual)
    let missing = expected.subtracting(actualNames).sorted()
    let unexpected = actualNames.subtracting(expected).sorted()
    guard actual.count == expected.count,
          actualNames.count == actual.count,
          missing.isEmpty,
          unexpected.isEmpty else {
        let missingText = missing.isEmpty ? "-" : missing.joined(separator: ",")
        let unexpectedText = unexpected.isEmpty
            ? "-"
            : unexpected.joined(separator: ",")
        throw SmokeFailure.contract(
            "\(kind) file set does not match the canonical sample; "
                + "expected=\(expected.count) actual=\(actual.count) "
                + "missing=\(missingText) unexpected=\(unexpectedText)"
        )
    }
}

private func validateSXMFiles(
    _ files: [SXMMetadata],
    parser: SXMParser
) throws -> (
    payloadCount: Int,
    matrixCount: Int,
    firstRender: FirstRenderFixture
) {
    guard let firstFile = files.first else {
        throw SmokeFailure.contract("The canonical sample has no SXM files.")
    }

    var payloadCount = 0
    var matrixCount = 0
    var firstRender: FirstRenderFixture?

    for file in files {
        guard let expected = expectedSXMDimensions[file.filename] else {
            throw SmokeFailure.contract(
                "Unexpected SXM file reached payload validation: "
                    + file.filename
            )
        }
        guard file.pixels.width == expected.width,
              file.pixels.height == expected.height else {
            throw SmokeFailure.contract(
                "\(file.filename) dimensions are "
                    + "\(file.pixels.width)x\(file.pixels.height); expected "
                    + "\(expected.width)x\(expected.height)"
            )
        }

        let full: SXMFullFile
        do {
            full = try parser.loadFullFile(file)
        } catch {
            throw SmokeFailure.contract(
                "Could not load the complete payload for \(file.filename): "
                    + error.localizedDescription
            )
        }
        payloadCount += 1

        guard !full.matrices.isEmpty else {
            throw SmokeFailure.contract(
                "\(file.filename) contains no readable matrices."
            )
        }
        for matrix in full.matrices.values {
            guard matrix.width == expected.width,
                  matrix.height == expected.height,
                  matrix.values.count == expected.width * expected.height else {
                throw SmokeFailure.contract(
                    "\(file.filename) contains a matrix with inconsistent "
                        + "dimensions or sample count."
                )
            }
            matrixCount += 1
        }

        guard let channel = full.metadata.defaultChannel,
              let channelInfo = full.metadata.channels.first(where: {
                  $0.name == channel
              }),
              let direction = channelInfo.directions.first else {
            throw SmokeFailure.contract(
                "\(file.filename) has no usable default channel."
            )
        }
        let defaultKey = MatrixKey(
            channel: channel,
            direction: direction
        )
        guard let defaultMatrix = full.matrices[defaultKey] else {
            throw SmokeFailure.contract(
                "\(file.filename) is missing its default matrix "
                    + "\(channel) \(direction.rawValue)."
            )
        }

        if file.id == firstFile.id {
            firstRender = FirstRenderFixture(
                filename: file.filename,
                channel: channel,
                direction: direction,
                matrix: defaultMatrix
            )
        }
    }

    guard let firstRender else {
        throw SmokeFailure.contract(
            "The first canonical SXM payload was not validated."
        )
    }
    return (payloadCount, matrixCount, firstRender)
}

private func validateSpectroscopyFiles(
    _ files: [SpectroscopyFile]
) throws -> Int {
    for file in files {
        let curve = file.curve
        guard curve.columns.count >= 2,
              Set(curve.columns).count == curve.columns.count,
              curve.valuesByColumn.count == curve.columns.count,
              curve.x.count >= 2,
              curve.y.count == curve.x.count,
              curve.x.allSatisfy(\.isFinite),
              curve.y.allSatisfy(\.isFinite) else {
            throw SmokeFailure.contract(
                "\(file.filename) has an incomplete spectroscopy curve."
            )
        }

        for column in curve.columns {
            guard let values = curve.valuesByColumn[column],
                  values.count == curve.x.count,
                  values.allSatisfy(\.isFinite) else {
                throw SmokeFailure.contract(
                    "\(file.filename) has an incomplete or non-finite "
                        + "column: \(column)"
                )
            }
        }
    }
    return files.count
}

private func validateFirstRender(
    _ fixture: FirstRenderFixture
) throws -> (statisticsCount: Int, histogramBins: Int, imageSize: String) {
    let processing = defaultProcessing(for: fixture.channel)
    let processed: Matrix
    let statistics: MatrixStatistics
    let histogram: HistogramDistribution
    let image: NSImage

    do {
        processed = try SXMRenderer.processedMatrix(
            fixture.matrix,
            processing: processing,
            cancellation: .none
        )
        guard let measuredStatistics = try SXMRenderer.statistics(
            processed,
            cancellation: .none
        ) else {
            throw SmokeFailure.contract(
                "\(fixture.filename) produced no finite render statistics."
            )
        }
        statistics = measuredStatistics
        histogram = try SXMRenderer.histogram(
            processed,
            statistics: statistics,
            bins: 128,
            cancellation: .none
        )
        let scale = SXMRenderer.automaticScale(statistics)
        image = try SXMRenderer.renderProcessedImage(
            matrix: processed,
            options: RenderOptions(
                channel: fixture.channel,
                direction: fixture.direction,
                processing: processing,
                palette: defaultPalette(for: fixture.channel),
                vmin: scale.vmin,
                vmax: scale.vmax
            ),
            cancellation: .none
        )
    } catch let failure as SmokeFailure {
        throw failure
    } catch {
        throw SmokeFailure.contract(
            "Could not process and render \(fixture.filename): "
                + error.localizedDescription
        )
    }

    guard statistics.count > 0,
          histogram.bins == 128,
          histogram.counts.count == 128,
          histogram.edges.count == 129,
          histogram.counts.reduce(0, +) == statistics.count else {
        throw SmokeFailure.contract(
            "\(fixture.filename) produced inconsistent histogram results."
        )
    }

    let imageWidth = Int(image.size.width.rounded())
    let imageHeight = Int(image.size.height.rounded())
    guard imageWidth == fixture.matrix.width,
          imageHeight == fixture.matrix.height else {
        throw SmokeFailure.contract(
            "\(fixture.filename) rendered at \(imageWidth)x\(imageHeight); "
                + "expected \(fixture.matrix.width)x\(fixture.matrix.height)."
        )
    }
    return (
        statistics.count,
        histogram.bins,
        "\(imageWidth)x\(imageHeight)"
    )
}

private func runSmoke() throws {
    let folder = try canonicalSampleFolder()
    let validPaletteCount = PaletteName.allCases.filter {
        PaletteStore.shared.stops(for: $0).count >= 2
    }.count
    let expectedPalettes: [PaletteName] = [.gray, .flame, .blueViolet, .duskViolet, .deepBlue]
    guard Set(PaletteName.allCases) == Set(expectedPalettes),
          validPaletteCount == expectedPalettes.count else {
        throw SmokeFailure.contract(
            "The embedded palette catalog is incomplete; "
                + "expected=\(expectedPalettes.count) "
                + "actual=\(validPaletteCount)."
        )
    }

    // Exercise PNG export for both user-selected STM palettes. The canonical
    // sample's first image can be an AFM channel and therefore render only gray.
    let paletteRamp = Matrix(
        width: 257,
        height: 1,
        values: (0...256).map { Float($0) / 256 }
    )
    for palette in [PaletteName.blueViolet, .duskViolet, .deepBlue] {
        let options = RenderOptions(
            channel: "Z",
            direction: .fwd,
            processing: .raw,
            palette: palette,
            vmin: 0,
            vmax: 1
        )
        let png = try SXMRenderer.pngData(matrix: paletteRamp, options: options)
        guard let bitmap = NSBitmapImageRep(data: png),
              bitmap.pixelsWide == paletteRamp.width,
              bitmap.pixelsHigh == paletteRamp.height,
              let low = bitmap.colorAt(x: 0, y: 0),
              let high = bitmap.colorAt(x: paletteRamp.width - 1, y: 0),
              low != high else {
            throw SmokeFailure.contract(
                "Palette \(palette.rawValue) did not produce a valid PNG gradient."
            )
        }
    }

    let sxmParser = SXMParser()
    let spectroscopyParser = SpectroscopyParser()
    let sxmReport: ScanReport<SXMMetadata>
    let spectroscopyReport: ScanReport<SpectroscopyFile>
    do {
        sxmReport = try sxmParser.scanFolder(folder)
        spectroscopyReport = try spectroscopyParser.scanFolder(folder)
    } catch {
        throw SmokeFailure.contract(
            "Could not scan the canonical sample: "
                + error.localizedDescription
        )
    }

    print("canonical_sample=\(folder.path)")
    print("palettes=\(validPaletteCount)/\(expectedPalettes.count)")
    print(
        "sxm_files=\(sxmReport.items.count) "
            + "sxm_issues=\(sxmReport.issues.count)"
    )
    print(
        "dat_files=\(spectroscopyReport.items.count) "
            + "dat_issues=\(spectroscopyReport.issues.count)"
    )

    guard sxmReport.issues.isEmpty else {
        let details = sxmReport.issues.map {
            "\($0.file.lastPathComponent):\($0.stage.rawValue):\($0.reason)"
        }.joined(separator: " | ")
        throw SmokeFailure.contract("SXM scan issues: \(details)")
    }
    guard spectroscopyReport.issues.isEmpty else {
        let details = spectroscopyReport.issues.map {
            "\($0.file.lastPathComponent):\($0.stage.rawValue):\($0.reason)"
        }.joined(separator: " | ")
        throw SmokeFailure.contract("DAT scan issues: \(details)")
    }

    try verifyCanonicalNames(
        actual: sxmReport.items.map(\.filename),
        expected: Set(expectedSXMDimensions.keys),
        kind: "SXM"
    )
    try verifyCanonicalNames(
        actual: spectroscopyReport.items.map(\.filename),
        expected: expectedDATNames,
        kind: "DAT"
    )

    let sxmValidation = try validateSXMFiles(
        sxmReport.items,
        parser: sxmParser
    )
    let datCurveCount = try validateSpectroscopyFiles(
        spectroscopyReport.items
    )
    let renderValidation = try validateFirstRender(
        sxmValidation.firstRender
    )

    print(
        "sxm_payloads=\(sxmValidation.payloadCount) "
            + "sxm_matrices=\(sxmValidation.matrixCount)"
    )
    print("dat_curves=\(datCurveCount)")
    print(
        "first_file=\(sxmValidation.firstRender.filename) "
            + "first_channel=\(sxmValidation.firstRender.channel) "
            + "first_direction=\(sxmValidation.firstRender.direction.rawValue)"
    )
    print(
        "first_statistics_count=\(renderValidation.statisticsCount) "
            + "first_histogram_bins=\(renderValidation.histogramBins) "
            + "first_image_size=\(renderValidation.imageSize)"
    )
    print("smoke_result=passed")
}

private func writeFailure(code: Int32, reason: String) {
    let singleLineReason = reason
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let output = """
    smoke_result=failed
    smoke_exit_code=\(code)
    smoke_error=\(singleLineReason)

    """
    FileHandle.standardError.write(Data(output.utf8))
}

do {
    try runSmoke()
} catch let failure as SmokeFailure {
    writeFailure(code: failure.exitCode, reason: failure.reason)
    exit(failure.exitCode)
} catch {
    writeFailure(code: 70, reason: error.localizedDescription)
    exit(70)
}
