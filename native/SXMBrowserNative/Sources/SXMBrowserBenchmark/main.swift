import Foundation
import SXMBrowserCore

struct TimerResult<T> {
    let value: T
    let milliseconds: Double
}

func measure<T>(_ work: () throws -> T) rethrows -> TimerResult<T> {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try work()
    let end = DispatchTime.now().uptimeNanoseconds
    return TimerResult(value: value, milliseconds: Double(end - start) / 1_000_000.0)
}

let args = CommandLine.arguments.dropFirst()
let folder = args.first.map(URL.init(fileURLWithPath:))
    ?? defaultExampleFolder()

let parser = SXMParser()
let spectroscopyParser = SpectroscopyParser()

let scan = try measure {
    try parser.scanFolder(folder)
}

let spectraScan = try measure {
    try spectroscopyParser.scanFolder(folder)
}

print("folder=\(folder.path)")
print(String(format: "scan_files=%d scan_issues=%d scan_ms=%.2f", scan.value.items.count, scan.value.issues.count, scan.milliseconds))
print(String(format: "spectra_files=%d spectra_issues=%d spectra_scan_ms=%.2f", spectraScan.value.items.count, spectraScan.value.issues.count, spectraScan.milliseconds))

guard let first = scan.value.items.first else {
    fail("Benchmark failed: no SXM files were loaded from \(folder.path).")
}

let full = try measure {
    try parser.loadFullFile(first)
}

let channel = first.defaultChannel ?? first.channels.first?.name ?? ""
let direction = first.channels.first { $0.name == channel }?.directions.first ?? .fwd
guard let matrix = full.value.matrices[MatrixKey(channel: channel, direction: direction)] else {
    print("first_matrix=missing")
    exit(1)
}

let processing = defaultProcessing(for: channel)
let processed = measure {
    SXMRenderer.processedMatrix(matrix, processing: processing)
}

let stats = measure {
    SXMRenderer.histogram(processed.value, bins: 256)
}
guard let histogram = stats.value, histogram.count > 0 else {
    fail("Benchmark failed: the first SXM file has no usable histogram statistics.")
}

let image = try measure {
    try SXMRenderer.renderProcessedImage(
        matrix: processed.value,
        options: RenderOptions(
            channel: channel,
            direction: direction,
            processing: processing,
            palette: defaultPalette(for: channel),
            vmin: histogram.p1,
            vmax: histogram.p99,
            outputSize: 260
        )
    )
}

print("first_file=\(first.filename)")
print("first_channel=\(channel) direction=\(direction.rawValue) processing=\(processing.rawValue)")
print(String(format: "load_full_ms=%.2f process_ms=%.2f hist_ms=%.2f thumb_render_ms=%.2f", full.milliseconds, processed.milliseconds, stats.milliseconds, image.milliseconds))

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func defaultExampleFolder() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [
        cwd.appendingPathComponent("example"),
        cwd.appendingPathComponent("../example").standardizedFileURL,
        cwd.appendingPathComponent("../../example").standardizedFileURL,
        cwd.appendingPathComponent("../../../example").standardizedFileURL,
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? cwd
}
