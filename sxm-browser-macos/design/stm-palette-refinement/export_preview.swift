import AppKit
import Foundation

// Compile with SXMBrowserCore and its current embedded palette resource.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let parser = SXMParser()
var manifest: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    let metadata = try parser.loadMetadata(url)
    let raw = try parser.loadMatrix(metadata, key: MatrixKey(channel: "Z", direction: .fwd))
    let processed = SXMRenderer.processedMatrix(raw, processing: .planeLinear)
    guard let stats = SXMRenderer.statistics(processed) else { continue }
    let key = url.deletingPathExtension().lastPathComponent
    for (name, matrix) in [("raw", raw), ("planeLinear", processed)] {
        try matrix.values.withUnsafeBytes { bytes in
            try Data(bytes).write(to: output.appendingPathComponent(key + "_" + name + ".f32"))
        }
    }
    for palette in [PaletteName.gray, .blueViolet] {
        let options = RenderOptions(channel: "Z", direction: .fwd, processing: .raw,
                                    palette: palette, vmin: stats.min, vmax: stats.max)
        try SXMRenderer.pngData(matrix: processed, options: options)
            .write(to: output.appendingPathComponent(key + "_" + palette.rawValue + ".png"))
    }
    manifest.append([
        "key": key, "path": url.path, "channel": "Z", "processing": "planeLinear",
        "width": raw.width, "height": raw.height, "finite_count": stats.count,
        "range_x_nm": (metadata.scanRange?.x ?? 0) * 1e9,
        "range_y_nm": (metadata.scanRange?.y ?? 0) * 1e9,
        "vmin": stats.min, "vmax": stats.max,
    ])
}
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("matrices.json"))
print("Exported \(manifest.count) real STM samples with the current plane fit and renderer.")
