import AppKit
import Foundation

// Compile alongside the app's current SXMBrowserCore sources and embedded resources.
// Matrices therefore use the app's parser, scan orientation, and processing.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let parser = SXMParser()
var manifest: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    let metadata = try parser.loadMetadata(url)
    let channelNames = Set(["Z", metadata.defaultChannel ?? "Z"])
    for channel in metadata.channels where channelNames.contains(channel.name) {
        let matrix = try parser.loadMatrix(metadata, key: MatrixKey(channel: channel.name, direction: .fwd))
        for processing in [ProcessingMode.raw, .planeLinear] {
            let processed = SXMRenderer.processedMatrix(matrix, processing: processing)
            guard let stats = SXMRenderer.statistics(processed) else { continue }
            let key = url.deletingPathExtension().lastPathComponent + "_" + channel.name.replacingOccurrences(of: " ", with: "_") + "_" + processing.rawValue
            try processed.values.withUnsafeBytes { bytes in
                try Data(bytes).write(to: output.appendingPathComponent(key + ".f32"))
            }
            for palette in [PaletteName.gray, .flame] {
                let options = RenderOptions(channel: channel.name, direction: .fwd, processing: .raw, palette: palette, vmin: stats.min, vmax: stats.max)
                try SXMRenderer.pngData(matrix: processed, options: options)
                    .write(to: output.appendingPathComponent(key + "_" + palette.rawValue + ".png"))
            }
            manifest.append([
                "key": key, "path": url.path, "filename": metadata.filename,
                "channel": channel.name, "unit": channel.unit, "processing": processing.rawValue,
                "width": matrix.width, "height": matrix.height,
                "range_x_nm": (metadata.scanRange?.x ?? 0) * 1e9,
                "range_y_nm": (metadata.scanRange?.y ?? 0) * 1e9,
                "feedback_on": metadata.zControllerOn ?? false,
                "vmin": stats.min, "vmax": stats.max, "p1": stats.p1, "p99": stats.p99
            ])
        }
    }
}
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("matrices.json"))
print("Exported \(manifest.count) matrices using the current native parser and renderer.")
