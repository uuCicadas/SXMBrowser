import AppKit
import CoreGraphics
import Foundation

public enum SXMRenderError: LocalizedError {
    case missingMatrix
    case imageCreationFailed

    public var errorDescription: String? {
        switch self {
        case .missingMatrix: "Selected matrix is not available."
        case .imageCreationFailed: "Could not create image."
        }
    }
}

public enum SXMRenderer {
    public static func processedMatrix(_ matrix: Matrix, processing: ProcessingMode) -> Matrix {
        switch processing {
        case .raw:
            return matrix
        case .lineMean:
            return lineMeanSubtract(matrix)
        case .lineLinear:
            return lineLinearFit(matrix)
        case .planeLinear:
            return planeLinearFit(matrix)
        }
    }

    public static func histogram(_ matrix: Matrix, bins requestedBins: Int = 256) -> HistogramStats? {
        let finite = matrix.values.compactMap { value -> Double? in
            value.isFinite ? Double(value) : nil
        }
        guard !finite.isEmpty else { return nil }
        let sorted = finite.sorted()
        let minValue = sorted.first ?? 0
        let maxValue = sorted.last ?? minValue
        let bins = max(16, min(2048, requestedBins))
        if maxValue == minValue {
            var hist = [Int](repeating: 0, count: bins)
            hist[bins / 2] = finite.count
            return HistogramStats(
                count: finite.count,
                min: minValue,
                max: maxValue,
                p1: minValue,
                p99: maxValue,
                mean: minValue,
                std: 0,
                bins: bins,
                hist: hist,
                edges: [Double](repeating: minValue, count: bins + 1)
            )
        }

        let width = (maxValue - minValue) / Double(bins)
        var hist = [Int](repeating: 0, count: bins)
        var sum = 0.0
        var sumSq = 0.0
        for value in finite {
            let idx = min(bins - 1, max(0, Int((value - minValue) / width)))
            hist[idx] += 1
            sum += value
            sumSq += value * value
        }
        let mean = sum / Double(finite.count)
        let variance = max(0, sumSq / Double(finite.count) - mean * mean)
        let edges = (0...bins).map { minValue + Double($0) * width }

        return HistogramStats(
            count: finite.count,
            min: minValue,
            max: maxValue,
            p1: percentile(sorted, 1),
            p99: percentile(sorted, 99),
            mean: mean,
            std: sqrt(variance),
            bins: bins,
            hist: hist,
            edges: edges
        )
    }

    public static func renderImage(matrix: Matrix, options: RenderOptions) throws -> NSImage {
        let processed = processedMatrix(matrix, processing: options.processing)
        return try renderProcessedImage(matrix: processed, options: options)
    }

    public static func renderProcessedImage(matrix: Matrix, options: RenderOptions) throws -> NSImage {
        let rgba = colorize(
            matrix: matrix,
            palette: options.palette,
            vmin: options.vmin,
            vmax: options.vmax,
            invert: options.invert
        )
        guard let cgImage = makeCGImage(rgba: rgba, width: matrix.width, height: matrix.height) else {
            throw SXMRenderError.imageCreationFailed
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: matrix.width, height: matrix.height))
        if let outputSize = options.outputSize {
            return resized(image, maxSide: CGFloat(outputSize))
        }
        return image
    }

    public static func pngData(matrix: Matrix, options: RenderOptions) throws -> Data {
        let image = try renderImage(matrix: matrix, options: options)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw SXMRenderError.imageCreationFailed
        }
        return png
    }

    public static func automaticScale(_ matrix: Matrix) -> (vmin: Double, vmax: Double)? {
        let finite = matrix.values.compactMap { $0.isFinite ? Double($0) : nil }.sorted()
        guard let first = finite.first, let last = finite.last else { return nil }
        if first == last {
            return (first, last)
        }
        let lo = percentile(finite, 1)
        let hi = percentile(finite, 99)
        if hi <= lo {
            return (first, last)
        }
        return (lo, hi)
    }

    public static func colorize(
        matrix: Matrix,
        palette: PaletteName,
        vmin: Double?,
        vmax: Double?,
        invert: Bool
    ) -> [UInt8] {
        let auto = (vmin == nil || vmax == nil) ? automaticScale(matrix) : nil
        let lo = vmin ?? auto?.vmin ?? 0
        let hi = vmax ?? auto?.vmax ?? 1
        let hasSpan = lo.isFinite && hi.isFinite && hi > lo

        let stops = PaletteStore.shared.stops(for: palette)
        var rgba = [UInt8](repeating: 255, count: matrix.width * matrix.height * 4)
        for idx in matrix.values.indices {
            let value = matrix.values[idx]
            var scaled = value.isFinite
                ? (hasSpan ? (Double(value) - lo) / (hi - lo) : 0.5)
                : 0
            scaled = min(1, max(0, scaled))
            if invert { scaled = 1 - scaled }
            let color = interpolate(stops: stops, at: scaled)
            let base = idx * 4
            rgba[base] = UInt8(min(255, max(0, round(color.r * 255))))
            rgba[base + 1] = UInt8(min(255, max(0, round(color.g * 255))))
            rgba[base + 2] = UInt8(min(255, max(0, round(color.b * 255))))
            rgba[base + 3] = 255
        }
        return rgba
    }
}

public final class PaletteStore: @unchecked Sendable {
    public static let shared = PaletteStore()
    private var cache: [String: [PaletteStop]] = [:]

    private init() {}

    public func stops(for palette: PaletteName) -> [PaletteStop] {
        switch palette {
        case .gwyddionNet:
            return gwyddionGradient("Gwyddion.net") ?? fallbackGwyddionNet
        case .gray:
            return [PaletteStop(0, 0, 0, 0), PaletteStop(1, 1, 1, 1)]
        case .grayInverted:
            return [PaletteStop(0, 1, 1, 1), PaletteStop(1, 0, 0, 0)]
        case .gold:
            return gwyddionGradient("Gold") ?? fallbackGold
        case .viridis:
            return viridis
        case .inferno:
            return inferno
        case .bwr:
            return bwr
        case .flame:
            return gwyddionGradient("Flame") ?? fallbackFlame
        }
    }

    private func gwyddionGradient(_ name: String) -> [PaletteStop]? {
        if let cached = cache[name] { return cached }
        let candidates = [
            "\(NSHomeDirectory())/.gwyddion/gradients/\(name)",
            "/opt/homebrew/share/gwyddion/gradients/\(name)",
            "/opt/homebrew/Cellar/gwyddion/2.71/share/gwyddion/gradients/\(name)",
            "/usr/local/share/gwyddion/gradients/\(name)",
        ]
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let stops = text.split(whereSeparator: \.isNewline).compactMap { line -> PaletteStop? in
                let parts = line.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                guard parts.count == 5 else { return nil }
                return PaletteStop(parts[0], parts[1], parts[2], parts[3])
            }.sorted { $0.position < $1.position }
            if stops.count >= 2 {
                cache[name] = stops
                return stops
            }
        }
        return nil
    }
}

public struct PaletteStop: Sendable {
    public let position: Double
    public let r: Double
    public let g: Double
    public let b: Double

    public init(_ position: Double, _ r: Double, _ g: Double, _ b: Double) {
        self.position = position
        self.r = r
        self.g = g
        self.b = b
    }
}

private func lineMeanSubtract(_ matrix: Matrix) -> Matrix {
    var output = matrix
    for y in 0..<matrix.height {
        var sum = 0.0
        var count = 0.0
        for x in 0..<matrix.width {
            let value = matrix[x, y]
            if value.isFinite {
                sum += Double(value)
                count += 1
            }
        }
        guard count > 0 else { continue }
        let mean = Float(sum / count)
        for x in 0..<matrix.width {
            output[x, y] = matrix[x, y] - mean
        }
    }
    return output
}

private func lineLinearFit(_ matrix: Matrix) -> Matrix {
    var output = matrix
    let n = Double(matrix.width)
    let sumX = Double(matrix.width - 1) * n / 2
    let sumXX = Double(matrix.width - 1) * Double(matrix.width) * Double(2 * matrix.width - 1) / 6

    for y in 0..<matrix.height {
        var valid = 0.0
        var sx = 0.0
        var sy = 0.0
        var sxx = 0.0
        var sxy = 0.0
        for x in 0..<matrix.width {
            let value = matrix[x, y]
            if value.isFinite {
                let dx = Double(x)
                let dy = Double(value)
                valid += 1
                sx += dx
                sy += dy
                sxx += dx * dx
                sxy += dx * dy
            }
        }
        if valid < 2 { continue }
        let denominator = valid * sxx - sx * sx
        let slope = abs(denominator) < .ulpOfOne ? 0 : (valid * sxy - sx * sy) / denominator
        let intercept = (sy - slope * sx) / valid
        for x in 0..<matrix.width {
            output[x, y] = matrix[x, y] - Float(slope * Double(x) + intercept)
        }

        _ = (sumX, sumXX)
    }
    return output
}

private func planeLinearFit(_ matrix: Matrix) -> Matrix {
    var normal = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
    var rhs = [Double](repeating: 0, count: 3)
    var count = 0

    for y in 0..<matrix.height {
        for x in 0..<matrix.width {
            let value = matrix[x, y]
            guard value.isFinite else { continue }
            let row = [Double(x), Double(y), 1.0]
            for i in 0..<3 {
                rhs[i] += row[i] * Double(value)
                for j in 0..<3 {
                    normal[i][j] += row[i] * row[j]
                }
            }
            count += 1
        }
    }
    guard count >= 3, let coeff = solve3x3(normal, rhs) else { return matrix }

    var output = matrix
    for y in 0..<matrix.height {
        for x in 0..<matrix.width {
            output[x, y] = matrix[x, y] - Float(coeff[0] * Double(x) + coeff[1] * Double(y) + coeff[2])
        }
    }
    return output
}

private func solve3x3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    var m = [
        [a[0][0], a[0][1], a[0][2], b[0]],
        [a[1][0], a[1][1], a[1][2], b[1]],
        [a[2][0], a[2][1], a[2][2], b[2]],
    ]

    for pivot in 0..<3 {
        var maxRow = pivot
        for row in pivot..<3 where abs(m[row][pivot]) > abs(m[maxRow][pivot]) {
            maxRow = row
        }
        if abs(m[maxRow][pivot]) < 1e-20 { return nil }
        if maxRow != pivot { m.swapAt(maxRow, pivot) }
        let div = m[pivot][pivot]
        for col in pivot..<4 { m[pivot][col] /= div }
        for row in 0..<3 where row != pivot {
            let factor = m[row][pivot]
            for col in pivot..<4 {
                m[row][col] -= factor * m[pivot][col]
            }
        }
    }
    return [m[0][3], m[1][3], m[2][3]]
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    if sorted.count == 1 { return sorted[0] }
    let pos = (p / 100) * Double(sorted.count - 1)
    let lo = Int(floor(pos))
    let hi = Int(ceil(pos))
    if lo == hi { return sorted[lo] }
    let t = pos - Double(lo)
    return sorted[lo] * (1 - t) + sorted[hi] * t
}

private func interpolate(stops: [PaletteStop], at value: Double) -> (r: Double, g: Double, b: Double) {
    guard let first = stops.first, let last = stops.last else { return (value, value, value) }
    if value <= first.position { return (first.r, first.g, first.b) }
    if value >= last.position { return (last.r, last.g, last.b) }

    for idx in 0..<(stops.count - 1) {
        let a = stops[idx]
        let b = stops[idx + 1]
        if value >= a.position && value <= b.position {
            let span = max(1e-12, b.position - a.position)
            let t = (value - a.position) / span
            return (
                a.r * (1 - t) + b.r * t,
                a.g * (1 - t) + b.g * t,
                a.b * (1 - t) + b.b * t
            )
        }
    }
    return (last.r, last.g, last.b)
}

private func makeCGImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    let data = Data(rgba) as CFData
    guard let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}

private func resized(_ image: NSImage, maxSide: CGFloat) -> NSImage {
    let size = image.size
    let scale = min(1, maxSide / max(size.width, size.height))
    let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    let output = NSImage(size: target)
    output.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
    output.unlockFocus()
    return output
}

private let fallbackGwyddionNet = [
    PaletteStop(0.00, 0.000, 0.000, 0.000),
    PaletteStop(0.18, 0.075, 0.090, 0.420),
    PaletteStop(0.36, 0.000, 0.445, 0.720),
    PaletteStop(0.54, 0.000, 0.650, 0.360),
    PaletteStop(0.72, 0.850, 0.720, 0.120),
    PaletteStop(1.00, 1.000, 1.000, 1.000),
]

private let fallbackGold = [
    PaletteStop(0.00, 0.000, 0.000, 0.000),
    PaletteStop(0.35, 0.280, 0.110, 0.020),
    PaletteStop(0.72, 0.850, 0.560, 0.160),
    PaletteStop(1.00, 1.000, 0.950, 0.650),
]

private let fallbackFlame = [
    PaletteStop(0.000000, 0.000000, 0.000000, 0.000000),
    PaletteStop(0.007843, 0.003921, 0.006274, 0.022352),
    PaletteStop(0.101960, 0.003921, 0.082352, 0.290196),
    PaletteStop(0.200000, 0.003921, 0.341176, 0.584313),
    PaletteStop(0.337254, 0.003921, 0.996078, 0.996078),
    PaletteStop(0.666666, 0.950980, 0.003921, 0.003921),
    PaletteStop(0.682352, 0.996078, 0.050588, 0.003921),
    PaletteStop(1.000000, 0.996078, 0.996078, 0.003921),
]

private let viridis = [
    PaletteStop(0.00, 0.267, 0.005, 0.329),
    PaletteStop(0.25, 0.230, 0.322, 0.546),
    PaletteStop(0.50, 0.128, 0.567, 0.551),
    PaletteStop(0.75, 0.369, 0.789, 0.383),
    PaletteStop(1.00, 0.993, 0.906, 0.144),
]

private let inferno = [
    PaletteStop(0.00, 0.001, 0.000, 0.014),
    PaletteStop(0.25, 0.342, 0.063, 0.429),
    PaletteStop(0.50, 0.735, 0.216, 0.330),
    PaletteStop(0.75, 0.978, 0.549, 0.039),
    PaletteStop(1.00, 0.988, 0.998, 0.645),
]

private let bwr = [
    PaletteStop(0.00, 0.075, 0.231, 0.682),
    PaletteStop(0.50, 0.965, 0.965, 0.965),
    PaletteStop(1.00, 0.706, 0.016, 0.150),
]
