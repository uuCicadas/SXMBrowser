import AppKit
import Foundation
import SXMBrowserCore

private enum BenchmarkFailure: Error {
    case usage(String)
    case unsupported(String)
    case gate(String)

    var exitCode: Int32 {
        switch self {
        case .usage:
            64
        case .unsupported:
            69
        case .gate:
            1
        }
    }

    var reason: String {
        switch self {
        case .usage(let reason), .unsupported(let reason), .gate(let reason):
            reason
        }
    }
}

private struct BenchmarkConfiguration {
    let fileCount: Int
    let width: Int
    let height: Int
    let trials: Int
    let maximumScanMilliseconds: Double
    let maximumImageMilliseconds: Double
    let maximumThumbnailMilliseconds: Double
    let pixelCount: Int
    let payloadByteCount: Int
    let gradientFileCount: Int

    static func parse() throws -> BenchmarkConfiguration {
        let expectedFlags: Set<String> = [
            "--files",
            "--width",
            "--height",
            "--trials",
            "--max-scan-ms",
            "--max-image-ms",
            "--max-thumbnail-ms",
        ]
        let arguments = Array(CommandLine.arguments.dropFirst())
        var values: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let flag = arguments[index]
            guard expectedFlags.contains(flag) else {
                throw BenchmarkFailure.usage(
                    "Unknown benchmark argument: \(flag). \(usage)"
                )
            }
            guard values[flag] == nil else {
                throw BenchmarkFailure.usage(
                    "Duplicate benchmark argument: \(flag). \(usage)"
                )
            }
            guard index + 1 < arguments.count else {
                throw BenchmarkFailure.usage(
                    "Missing value for \(flag). \(usage)"
                )
            }
            values[flag] = arguments[index + 1]
            index += 2
        }

        let missing = expectedFlags.subtracting(values.keys).sorted()
        guard missing.isEmpty else {
            throw BenchmarkFailure.usage(
                "Missing benchmark arguments: "
                    + missing.joined(separator: ", ")
                    + ". \(usage)"
            )
        }

        let fileCount = try positiveInteger("--files", in: values)
        let width = try positiveInteger("--width", in: values)
        let height = try positiveInteger("--height", in: values)
        let trials = try positiveInteger("--trials", in: values)
        let scanLimit = try positiveFiniteDouble(
            "--max-scan-ms",
            in: values
        )
        let imageLimit = try positiveFiniteDouble(
            "--max-image-ms",
            in: values
        )
        let thumbnailLimit = try positiveFiniteDouble(
            "--max-thumbnail-ms",
            in: values
        )

        guard fileCount <= 5_000 else {
            throw BenchmarkFailure.usage(
                "--files must be within 1...5000."
            )
        }
        guard trials <= 25 else {
            throw BenchmarkFailure.usage(
                "--trials must be within 1...25."
            )
        }
        guard width <= SXMParser.maximumPixelDimension,
              height <= SXMParser.maximumPixelDimension else {
            throw BenchmarkFailure.usage(
                "--width and --height must not exceed "
                    + "\(SXMParser.maximumPixelDimension)."
            )
        }
        for (flag, limit) in [
            ("--max-scan-ms", scanLimit),
            ("--max-image-ms", imageLimit),
            ("--max-thumbnail-ms", thumbnailLimit),
        ] where limit > 60_000 {
            throw BenchmarkFailure.usage(
                "\(flag) must not exceed 60000."
            )
        }

        let (pixelCount, pixelOverflow) =
            width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow,
              pixelCount <= SXMParser.maximumPixelCount else {
            throw BenchmarkFailure.usage(
                "The requested pixel count is unsupported."
            )
        }
        let (payloadByteCount, payloadOverflow) =
            pixelCount.multipliedReportingOverflow(by: 4)
        guard !payloadOverflow else {
            throw BenchmarkFailure.usage(
                "The requested payload byte count overflows."
            )
        }
        let (twiceTrials, trialOverflow) =
            trials.multipliedReportingOverflow(by: 2)
        let (gradientFileCount, gradientOverflow) =
            twiceTrials.addingReportingOverflow(1)
        guard !trialOverflow,
              !gradientOverflow,
              gradientFileCount <= fileCount else {
            throw BenchmarkFailure.usage(
                "--files must provide one warmup file and two independent "
                    + "files per trial."
            )
        }
        let (physicalPayloadBytes, physicalOverflow) =
            payloadByteCount.multipliedReportingOverflow(
                by: gradientFileCount
            )
        guard !physicalOverflow,
              physicalPayloadBytes <= 256 * 1024 * 1024 else {
            throw BenchmarkFailure.usage(
                "The requested rendered fixture payload exceeds 256 MiB."
            )
        }
        let (logicalPayloadBytes, logicalOverflow) =
            payloadByteCount.multipliedReportingOverflow(by: fileCount)
        guard !logicalOverflow,
              logicalPayloadBytes <= 64 * 1024 * 1024 * 1024 else {
            throw BenchmarkFailure.usage(
                "The requested logical fixture payload exceeds 64 GiB."
            )
        }

        return BenchmarkConfiguration(
            fileCount: fileCount,
            width: width,
            height: height,
            trials: trials,
            maximumScanMilliseconds: scanLimit,
            maximumImageMilliseconds: imageLimit,
            maximumThumbnailMilliseconds: thumbnailLimit,
            pixelCount: pixelCount,
            payloadByteCount: payloadByteCount,
            gradientFileCount: gradientFileCount
        )
    }

    private static func positiveInteger(
        _ flag: String,
        in values: [String: String]
    ) throws -> Int {
        guard let rawValue = values[flag],
              let value = Int(rawValue),
              value > 0 else {
            throw BenchmarkFailure.usage(
                "\(flag) must be a positive integer."
            )
        }
        return value
    }

    private static func positiveFiniteDouble(
        _ flag: String,
        in values: [String: String]
    ) throws -> Double {
        guard let rawValue = values[flag],
              let value = Double(rawValue),
              value.isFinite,
              value > 0 else {
            throw BenchmarkFailure.usage(
                "\(flag) must be a positive finite number."
            )
        }
        return value
    }

    private static let usage =
        "Usage: SXMBrowserBenchmark --files <count> "
        + "--width <pixels> --height <pixels> --trials <count> "
        + "--max-scan-ms <milliseconds> "
        + "--max-image-ms <milliseconds> "
        + "--max-thumbnail-ms <milliseconds>"
}

private struct SyntheticFixture {
    let folder: URL
    let filenames: [String]
    let gradientFilenames: [String]

    func remove() throws {
        try FileManager.default.removeItem(at: folder)
    }
}

private struct Timed<Value> {
    let value: Value
    let milliseconds: Double
}

private func measure<Value>(
    _ operation: () throws -> Value
) rethrows -> Timed<Value> {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try operation()
    let end = DispatchTime.now().uptimeNanoseconds
    return Timed(
        value: value,
        milliseconds: Double(end - start) / 1_000_000
    )
}

private func validateEnvironment() throws {
    #if DEBUG
    throw BenchmarkFailure.unsupported(
        "Performance gates require a Release build."
    )
    #else
    #if arch(arm64)
    #else
    throw BenchmarkFailure.unsupported(
        "Performance gates require native Apple Silicon execution."
    )
    #endif

    let version = ProcessInfo.processInfo.operatingSystemVersion
    guard version.majorVersion >= 14 else {
        throw BenchmarkFailure.unsupported(
            "Performance gates require macOS 14 or newer."
        )
    }
    #endif
}

private func makeSyntheticFixture(
    configuration: BenchmarkConfiguration
) throws -> SyntheticFixture {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "sxm-browser-benchmark-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: false
    )

    do {
        let header = """
        :NANONIS_VERSION:
        2
        :SCANIT_TYPE:
        FLOAT MSBFIRST
        :SCAN_PIXELS:
        \(configuration.width) \(configuration.height)
        :DATA_INFO:
        Channel\tName\tUnit\tDirection
        0\tZ\tm\tforward
        :SCANIT_END:

        """
        var prefix = Data(header.utf8)
        prefix.append(contentsOf: [0x1a, 0x04])
        let (completeFileByteCount, fileSizeOverflow) =
            prefix.count.addingReportingOverflow(
                configuration.payloadByteCount
            )
        guard !fileSizeOverflow,
              let completeFileLength = UInt64(
                  exactly: completeFileByteCount
              ) else {
            throw BenchmarkFailure.usage(
                "The synthetic fixture file size overflows."
            )
        }

        var gradientPayload = Data(
            count: configuration.payloadByteCount
        )
        gradientPayload.withUnsafeMutableBytes {
            (rawBuffer: UnsafeMutableRawBufferPointer) in
            for sampleIndex in 0..<configuration.pixelCount {
                let x = sampleIndex % configuration.width
                let y = sampleIndex / configuration.width
                let deterministicValue = (
                    x * x
                        + 3 * y * y
                        + 7 * x * y
                        + 17 * x
                        + 31 * y
                ) % 8_191
                let sample = Float(deterministicValue) / 8_190
                let bits = sample.bitPattern
                let byteIndex = sampleIndex * 4
                rawBuffer[byteIndex] = UInt8(
                    truncatingIfNeeded: bits >> 24
                )
                rawBuffer[byteIndex + 1] = UInt8(
                    truncatingIfNeeded: bits >> 16
                )
                rawBuffer[byteIndex + 2] = UInt8(
                    truncatingIfNeeded: bits >> 8
                )
                rawBuffer[byteIndex + 3] = UInt8(
                    truncatingIfNeeded: bits
                )
            }
        }

        var filenames: [String] = []
        var gradientFilenames: [String] = []
        filenames.reserveCapacity(configuration.fileCount)
        gradientFilenames.reserveCapacity(
            configuration.gradientFileCount
        )

        for fileIndex in 0..<configuration.fileCount {
            let filename = String(
                format: "benchmark-%06d.sxm",
                fileIndex
            )
            let url = folder.appendingPathComponent(filename)
            if fileIndex < configuration.gradientFileCount {
                var data = prefix
                data.append(gradientPayload)
                try data.write(to: url, options: .atomic)
                gradientFilenames.append(filename)
            } else {
                try prefix.write(to: url, options: .atomic)
                let handle = try FileHandle(forWritingTo: url)
                do {
                    try handle.truncate(atOffset: completeFileLength)
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
            }
            filenames.append(filename)
        }

        return SyntheticFixture(
            folder: folder,
            filenames: filenames,
            gradientFilenames: gradientFilenames
        )
    } catch {
        try? FileManager.default.removeItem(at: folder)
        throw error
    }
}

private func matrixKey(
    for metadata: SXMMetadata
) throws -> (channel: String, key: MatrixKey) {
    guard let channel = metadata.defaultChannel,
          let channelInfo = metadata.channels.first(where: {
              $0.name == channel
          }),
          let direction = channelInfo.directions.first else {
        throw BenchmarkFailure.gate(
            "\(metadata.filename) has no usable default matrix."
        )
    }
    return (
        channel,
        MatrixKey(channel: channel, direction: direction)
    )
}

private func validateFixturePayloads(
    _ fixture: SyntheticFixture,
    configuration: BenchmarkConfiguration,
    parser: SXMParser
) throws {
    guard let gradientFilename = fixture.gradientFilenames.first,
          let sparseFilename = fixture.filenames.last else {
        throw BenchmarkFailure.gate(
            "The synthetic fixture did not create its validation files."
        )
    }

    let gradientMetadata = try parser.loadMetadata(
        fixture.folder.appendingPathComponent(gradientFilename)
    )
    let gradientSelection = try matrixKey(for: gradientMetadata)
    let gradientMatrix = try parser.loadMatrix(
        gradientMetadata,
        key: gradientSelection.key
    )
    guard gradientMatrix.width == configuration.width,
          gradientMatrix.height == configuration.height,
          gradientMatrix.values.count == configuration.pixelCount,
          gradientMatrix.values.allSatisfy(\.isFinite),
          gradientMatrix.values.contains(where: { $0 != 0 }) else {
        throw BenchmarkFailure.gate(
            "The deterministic gradient fixture is invalid."
        )
    }

    let sparseMetadata = try parser.loadMetadata(
        fixture.folder.appendingPathComponent(sparseFilename)
    )
    let sparseSelection = try matrixKey(for: sparseMetadata)
    let sparseMatrix = try parser.loadMatrix(
        sparseMetadata,
        key: sparseSelection.key
    )
    guard sparseMatrix.width == configuration.width,
          sparseMatrix.height == configuration.height,
          sparseMatrix.values.count == configuration.pixelCount,
          sparseMatrix.values.allSatisfy({ $0 == 0 }) else {
        throw BenchmarkFailure.gate(
            "The sparse zero fixture is invalid."
        )
    }
}

private func validateScan(
    _ report: ScanReport<SXMMetadata>,
    configuration: BenchmarkConfiguration
) throws {
    guard report.issues.isEmpty else {
        let details = report.issues.map {
            "\($0.file.lastPathComponent):\($0.reason)"
        }.joined(separator: " | ")
        throw BenchmarkFailure.gate(
            "Synthetic scan produced issues: \(details)"
        )
    }
    guard report.items.count == configuration.fileCount,
          Set(report.items.map(\.filename)).count
            == configuration.fileCount,
          report.items.allSatisfy({
              $0.pixels.width == configuration.width
                  && $0.pixels.height == configuration.height
                  && $0.defaultChannel != nil
          }) else {
        throw BenchmarkFailure.gate(
            "Synthetic scan did not return exactly "
                + "\(configuration.fileCount) unique "
                + "\(configuration.width)x\(configuration.height) files."
        )
    }
}

private func metadata(
    named filename: String,
    in files: [SXMMetadata]
) throws -> SXMMetadata {
    guard let metadata = files.first(where: {
        $0.filename == filename
    }) else {
        throw BenchmarkFailure.gate(
            "Scanned metadata is missing \(filename)."
        )
    }
    return metadata
}

private func renderFirstImage(
    _ metadata: SXMMetadata,
    parser: SXMParser,
    configuration: BenchmarkConfiguration
) throws {
    let selection = try matrixKey(for: metadata)
    let matrix = try parser.loadMatrix(
        metadata,
        key: selection.key
    )
    let processing = defaultProcessing(for: selection.channel)
    let processed = try SXMRenderer.processedMatrix(
        matrix,
        processing: processing,
        cancellation: .none
    )
    guard let statistics = try SXMRenderer.statistics(
        processed,
        cancellation: .none
    ), statistics.count == configuration.pixelCount else {
        throw BenchmarkFailure.gate(
            "\(metadata.filename) produced incomplete image statistics."
        )
    }
    let scale = SXMRenderer.automaticScale(statistics)
    let image = try SXMRenderer.renderProcessedImage(
        matrix: processed,
        options: RenderOptions(
            channel: selection.channel,
            direction: selection.key.direction,
            processing: processing,
            palette: defaultPalette(for: selection.channel),
            vmin: scale.vmin,
            vmax: scale.vmax
        ),
        cancellation: .none
    )
    guard Int(image.size.width.rounded()) == configuration.width,
          Int(image.size.height.rounded()) == configuration.height else {
        throw BenchmarkFailure.gate(
            "\(metadata.filename) produced an invalid first image."
        )
    }
}

private func renderFirstThumbnail(
    _ metadata: SXMMetadata,
    parser: SXMParser,
    configuration: BenchmarkConfiguration
) throws {
    let selection = try matrixKey(for: metadata)
    let matrix = try parser.loadMatrix(
        metadata,
        key: selection.key
    )
    guard matrix.width == configuration.width,
          matrix.height == configuration.height,
          matrix.values.count == configuration.pixelCount else {
        throw BenchmarkFailure.gate(
            "\(metadata.filename) produced an incomplete thumbnail matrix."
        )
    }
    let image = try SXMRenderer.renderImage(
        matrix: matrix,
        options: RenderOptions(
            channel: selection.channel,
            direction: selection.key.direction,
            processing: defaultProcessing(for: selection.channel),
            palette: defaultPalette(for: selection.channel),
            outputSize: 260
        ),
        cancellation: .none
    )
    guard image.size.width > 0,
          image.size.height > 0,
          image.size.width <= 260.5,
          image.size.height <= 260.5 else {
        throw BenchmarkFailure.gate(
            "\(metadata.filename) produced an invalid first thumbnail."
        )
    }
}

private func median(_ samples: [Double]) -> Double {
    let ordered = samples.sorted()
    let middle = ordered.count / 2
    if ordered.count.isMultiple(of: 2) {
        return (ordered[middle - 1] + ordered[middle]) / 2
    }
    return ordered[middle]
}

private let outputLocale = Locale(identifier: "en_US_POSIX")

private func formatted(_ value: Double) -> String {
    String(format: "%.3f", locale: outputLocale, value)
}

private func formatted(_ values: [Double]) -> String {
    values.map(formatted).joined(separator: ",")
}

private func runBenchmark() throws {
    let configuration = try BenchmarkConfiguration.parse()
    try validateEnvironment()

    let fixture = try makeSyntheticFixture(
        configuration: configuration
    )
    defer {
        try? fixture.remove()
    }

    let parser = SXMParser()
    try validateFixturePayloads(
        fixture,
        configuration: configuration,
        parser: parser
    )

    let warmupScan = try parser.scanFolder(fixture.folder)
    try validateScan(warmupScan, configuration: configuration)

    var scanSamples: [Double] = []
    var scannedFiles = warmupScan.items
    scanSamples.reserveCapacity(configuration.trials)
    for _ in 0..<configuration.trials {
        let timedScan = try measure {
            try parser.scanFolder(fixture.folder)
        }
        try validateScan(
            timedScan.value,
            configuration: configuration
        )
        scannedFiles = timedScan.value.items
        scanSamples.append(timedScan.milliseconds)
    }

    let warmupMetadata = try metadata(
        named: fixture.gradientFilenames[0],
        in: scannedFiles
    )
    try renderFirstImage(
        warmupMetadata,
        parser: parser,
        configuration: configuration
    )
    try renderFirstThumbnail(
        warmupMetadata,
        parser: parser,
        configuration: configuration
    )

    var imageSamples: [Double] = []
    var thumbnailSamples: [Double] = []
    imageSamples.reserveCapacity(configuration.trials)
    thumbnailSamples.reserveCapacity(configuration.trials)

    for trial in 0..<configuration.trials {
        let imageMetadata = try metadata(
            named: fixture.gradientFilenames[trial + 1],
            in: scannedFiles
        )
        let timedImage = try measure {
            try renderFirstImage(
                imageMetadata,
                parser: parser,
                configuration: configuration
            )
        }
        imageSamples.append(timedImage.milliseconds)
    }

    for trial in 0..<configuration.trials {
        let thumbnailMetadata = try metadata(
            named: fixture.gradientFilenames[
                configuration.trials + trial + 1
            ],
            in: scannedFiles
        )
        let timedThumbnail = try measure {
            try renderFirstThumbnail(
                thumbnailMetadata,
                parser: parser,
                configuration: configuration
            )
        }
        thumbnailSamples.append(timedThumbnail.milliseconds)
    }

    let scanMedian = median(scanSamples)
    let imageMedian = median(imageSamples)
    let thumbnailMedian = median(thumbnailSamples)

    print("benchmark_fixture_files=\(configuration.fileCount)")
    print(
        "benchmark_fixture_size="
            + "\(configuration.width)x\(configuration.height)"
    )
    print("benchmark_trials=\(configuration.trials)")
    print("scan_samples_ms=\(formatted(scanSamples))")
    print("scan_median_ms=\(formatted(scanMedian))")
    print("first_image_samples_ms=\(formatted(imageSamples))")
    print("first_image_median_ms=\(formatted(imageMedian))")
    print(
        "first_thumbnail_samples_ms="
            + formatted(thumbnailSamples)
    )
    print(
        "first_thumbnail_median_ms="
            + formatted(thumbnailMedian)
    )
    print(
        "limits_ms=scan:\(formatted(configuration.maximumScanMilliseconds)),"
            + "image:\(formatted(configuration.maximumImageMilliseconds)),"
            + "thumbnail:"
            + formatted(configuration.maximumThumbnailMilliseconds)
    )

    var failures: [String] = []
    if scanMedian > configuration.maximumScanMilliseconds {
        failures.append(
            "scan median \(formatted(scanMedian)) ms exceeds "
                + "\(formatted(configuration.maximumScanMilliseconds)) ms"
        )
    }
    if imageMedian > configuration.maximumImageMilliseconds {
        failures.append(
            "first image median \(formatted(imageMedian)) ms exceeds "
                + "\(formatted(configuration.maximumImageMilliseconds)) ms"
        )
    }
    if thumbnailMedian > configuration.maximumThumbnailMilliseconds {
        failures.append(
            "first thumbnail median "
                + "\(formatted(thumbnailMedian)) ms exceeds "
                + "\(formatted(configuration.maximumThumbnailMilliseconds)) ms"
        )
    }
    guard failures.isEmpty else {
        throw BenchmarkFailure.gate(
            failures.joined(separator: "; ")
        )
    }
    print("benchmark_result=passed")
}

private func writeFailure(code: Int32, reason: String) {
    let singleLineReason = reason
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let output = """
    benchmark_result=failed
    benchmark_exit_code=\(code)
    benchmark_error=\(singleLineReason)

    """
    FileHandle.standardError.write(Data(output.utf8))
}

do {
    try runBenchmark()
} catch let failure as BenchmarkFailure {
    writeFailure(code: failure.exitCode, reason: failure.reason)
    exit(failure.exitCode)
} catch {
    writeFailure(code: 70, reason: error.localizedDescription)
    exit(70)
}
