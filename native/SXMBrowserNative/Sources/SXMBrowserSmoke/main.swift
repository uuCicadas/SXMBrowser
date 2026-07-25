import Foundation
import SXMBrowserCore

let folder = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
    ?? defaultExampleFolder()

let parser = SXMParser()
let report = try parser.scanFolder(folder)
let files = report.items
print("files=\(files.count) issues=\(report.issues.count)")
for file in files.prefix(3) {
    print("\(file.filename) \(file.pixels.width)x\(file.pixels.height) default=\(file.defaultChannel ?? "-")")
}

guard let first = files.first else {
    fail("Smoke failed: no SXM files were loaded from \(folder.path).")
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

let full = try parser.loadFullFile(first)
let channel = first.defaultChannel ?? first.channels[0].name
let direction = first.channels.first { $0.name == channel }?.directions.first ?? .fwd
guard let matrix = full.matrices[MatrixKey(channel: channel, direction: direction)] else {
    fail("Smoke failed: the first SXM file has no matrix for \(channel) \(direction.rawValue).")
}
let processed = SXMRenderer.processedMatrix(matrix, processing: defaultProcessing(for: channel))
guard let stats = SXMRenderer.histogram(processed, bins: 128), stats.count > 0 else {
    fail("Smoke failed: the first SXM file has no usable histogram statistics.")
}
print("first_hist_count=\(stats.count)")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}
