import Foundation
import SXMBrowserCore

let folder = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
    ?? defaultExampleFolder()

let parser = SXMParser()
let files = try parser.scanFolder(folder)
print("files=\(files.count)")
for file in files.prefix(3) {
    print("\(file.filename) \(file.pixels.width)x\(file.pixels.height) default=\(file.defaultChannel ?? "-")")
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

if let first = files.first {
    let full = try parser.loadFullFile(first)
    let channel = first.defaultChannel ?? first.channels[0].name
    let direction = first.channels.first { $0.name == channel }?.directions.first ?? .fwd
    if let matrix = full.matrices[MatrixKey(channel: channel, direction: direction)] {
        let processed = SXMRenderer.processedMatrix(matrix, processing: defaultProcessing(for: channel))
        let stats = SXMRenderer.histogram(processed, bins: 128)
        print("first_hist_count=\(stats?.count ?? 0)")
    }
}
