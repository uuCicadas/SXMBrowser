import Foundation
import Testing
@testable import SXMBrowserCore

private func makeSXMFixture(
    pixels: String = "2 2",
    scanType: String? = "FLOAT MSBFIRST",
    direction: String = "forward",
    samples: [Float] = [],
    channelRows: [String]? = nil,
    trailingBytes: Data = Data()
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sxm-parser-\(UUID().uuidString).sxm")
    let scanTypeSection = scanType.map {
        ":SCANIT_TYPE:\n\($0)\n"
    } ?? ""
    let rows = channelRows ?? ["0\tZ\tm\t\(direction)"]
    let header = """
    :NANONIS_VERSION:
    2
    \(scanTypeSection):SCAN_PIXELS:
    \(pixels)
    :DATA_INFO:
    Channel\tName\tUnit\tDirection
    \(rows.joined(separator: "\n"))
    :SCANIT_END:

    """

    var data = Data(header.utf8)
    data.append(contentsOf: [0x1a, 0x04])
    for sample in samples {
        let bits = sample.bitPattern
        data.append(UInt8((bits >> 24) & 0xff))
        data.append(UInt8((bits >> 16) & 0xff))
        data.append(UInt8((bits >> 8) & 0xff))
        data.append(UInt8(bits & 0xff))
    }
    data.append(trailingBytes)
    try data.write(to: url)
    return url
}

private func capturedParserError<T>(
    _ operation: () throws -> T
) -> SXMParserError? {
    do {
        _ = try operation()
        return nil
    } catch let error as SXMParserError {
        return error
    } catch {
        return nil
    }
}

@Test
func pixelDimensionBoundariesAreValidatedWithoutAllocatingMatrices() throws {
    let validPixels = ["1 1", "16384 1", "16384 4096"]
    for pixels in validPixels {
        let url = try makeSXMFixture(pixels: pixels)
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = try SXMParser().loadMetadata(url)
        #expect(metadata.pixels.width >= 1)
        #expect(metadata.pixels.height >= 1)
    }

    let tooWide = try makeSXMFixture(pixels: "16385 1")
    defer { try? FileManager.default.removeItem(at: tooWide) }
    #expect(
        capturedParserError { try SXMParser().loadMetadata(tooWide) }
            == .pixelDimensionsOutOfRange(
                tooWide,
                width: 16_385,
                height: 1,
                maximumDimension: 16_384
            )
    )

    let tooMany = try makeSXMFixture(pixels: "16384 4097")
    defer { try? FileManager.default.removeItem(at: tooMany) }
    #expect(
        capturedParserError { try SXMParser().loadMetadata(tooMany) }
            == .pixelCountExceedsLimit(
                tooMany,
                count: 67_125_248,
                maximumCount: 67_108_864
            )
    )
}

@Test
func nonIntegerAndOutOfRangePixelTokensAreRejected() throws {
    for pixels in ["0 1", "-1 1"] {
        let url = try makeSXMFixture(pixels: pixels)
        defer { try? FileManager.default.removeItem(at: url) }
        let error = capturedParserError { try SXMParser().loadMetadata(url) }
        guard case .pixelDimensionsOutOfRange = error else {
            Issue.record("Expected out-of-range dimensions for \(pixels)")
            continue
        }
    }

    for pixels in ["1.5 2", "1e3 2", "NaN 2", "999999999999999999999999 2"] {
        let url = try makeSXMFixture(pixels: pixels)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(
            capturedParserError { try SXMParser().loadMetadata(url) }
                == .invalidPixels(url, rawValue: pixels)
        )
    }

    let overflowValue = "\(Int.max) 2"
    let overflow = try makeSXMFixture(pixels: overflowValue)
    defer { try? FileManager.default.removeItem(at: overflow) }
    #expect(
        capturedParserError { try SXMParser().loadMetadata(overflow) }
            == .pixelCountOverflow(
                overflow,
                width: Int.max,
                height: 2
            )
    )
}

@Test
func onlyExplicitFloatMSBFirstStorageIsAccepted() throws {
    let normalized = try makeSXMFixture(scanType: "  float   msbfirst  ")
    defer { try? FileManager.default.removeItem(at: normalized) }
    _ = try SXMParser().loadMetadata(normalized)

    let missing = try makeSXMFixture(scanType: nil)
    defer { try? FileManager.default.removeItem(at: missing) }
    #expect(
        capturedParserError { try SXMParser().loadMetadata(missing) }
            == .missingScanType(missing)
    )

    for value in ["FLOAT LSBFIRST", "DOUBLE MSBFIRST", "FLOAT MSBFIRST EXTRA"] {
        let url = try makeSXMFixture(scanType: value)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(
            capturedParserError { try SXMParser().loadMetadata(url) }
                == .unsupportedScanType(url, rawValue: value)
        )
    }
}

@Test
func matrixPayloadLengthIsCheckedBeforeDecoding() throws {
    let short = try makeSXMFixture(
        samples: [1, 2, 3],
        trailingBytes: Data([0, 0, 0])
    )
    defer { try? FileManager.default.removeItem(at: short) }
    let shortMetadata = try SXMParser().loadMetadata(short)
    #expect(
        capturedParserError { try SXMParser().loadFullFile(shortMetadata) }
            == .shortData(short, expectedBytes: 16, availableBytes: 15)
    )

    let shortBoth = try makeSXMFixture(
        direction: "both",
        samples: [1, 2, 3, 4]
    )
    defer { try? FileManager.default.removeItem(at: shortBoth) }
    let bothMetadata = try SXMParser().loadMetadata(shortBoth)
    #expect(
        capturedParserError { try SXMParser().loadFullFile(bothMetadata) }
            == .shortData(shortBoth, expectedBytes: 32, availableBytes: 16)
    )
}

@Test
func msbPayloadIsDecodedExactlyAndAllowsTrailingBytes() throws {
    let samples: [Float] = [1, -2.5, 0.25, 8]
    let url = try makeSXMFixture(
        samples: samples,
        trailingBytes: Data([0xff])
    )
    defer { try? FileManager.default.removeItem(at: url) }

    let metadata = try SXMParser().loadMetadata(url)
    let full = try SXMParser().loadFullFile(metadata)
    let matrix = try #require(
        full.matrices[MatrixKey(channel: "Z", direction: .fwd)]
    )

    #expect(matrix.values == samples)
}

@Test
func fullLoadRevalidatesHeaderAndRejectsExternalReplacement() throws {
    let url = try makeSXMFixture(
        pixels: "1 1",
        samples: [1]
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let metadata = try SXMParser().loadMetadata(url)

    let replacement = try makeSXMFixture(
        pixels: "1 1",
        scanType: "FLOAT LSBFIRST",
        samples: [1]
    )
    defer { try? FileManager.default.removeItem(at: replacement) }
    try Data(contentsOf: replacement).write(to: url, options: .atomic)

    #expect(
        capturedParserError { try SXMParser().loadFullFile(metadata) }
            == .unsupportedScanType(url, rawValue: "FLOAT LSBFIRST")
    )
}

@Test
func duplicateChannelNamesAreRejected() throws {
    let url = try makeSXMFixture(
        channelRows: [
            "0\tZ\tm\tforward",
            "1\tZ\tm\tbackward",
        ]
    )
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(
        capturedParserError { try SXMParser().loadMetadata(url) }
            == .duplicateChannel(url, name: "Z")
    )
}
