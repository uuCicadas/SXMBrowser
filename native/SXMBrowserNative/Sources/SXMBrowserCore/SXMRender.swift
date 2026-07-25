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

    public static func statistics(_ matrix: Matrix) -> MatrixStatistics? {
        var finite = matrix.values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }

        var mean = 0.0
        var sumOfSquaredDeviations = 0.0
        for (index, sample) in finite.enumerated() {
            let value = Double(sample)
            let count = Double(index + 1)
            let delta = value - mean
            mean += delta / count
            let adjustedDelta = value - mean
            sumOfSquaredDeviations += delta * adjustedDelta
        }

        finite.sort()
        let minValue = Double(finite[0])
        let maxValue = Double(finite[finite.count - 1])
        let variance = max(
            0,
            sumOfSquaredDeviations / Double(finite.count)
        )

        return MatrixStatistics(
            count: finite.count,
            min: minValue,
            max: maxValue,
            p1: percentile(finite, 1),
            p99: percentile(finite, 99),
            mean: mean,
            std: sqrt(variance)
        )
    }

    public static func histogram(
        _ matrix: Matrix,
        statistics: MatrixStatistics,
        bins requestedBins: Int = 256
    ) -> HistogramDistribution {
        let bins = max(16, min(2048, requestedBins))
        if statistics.max == statistics.min {
            var hist = [Int](repeating: 0, count: bins)
            hist[bins / 2] = matrix.values.lazy.filter(\.isFinite).count
            return HistogramDistribution(
                bins: bins,
                counts: hist,
                edges: [Double](
                    repeating: statistics.min,
                    count: bins + 1
                )
            )
        }

        let width = (statistics.max - statistics.min) / Double(bins)
        var hist = [Int](repeating: 0, count: bins)
        for sample in matrix.values where sample.isFinite {
            let value = Double(sample)
            let idx = min(
                bins - 1,
                max(0, Int((value - statistics.min) / width))
            )
            hist[idx] += 1
        }
        let edges = (0...bins).map {
            statistics.min + Double($0) * width
        }

        return HistogramDistribution(
            bins: bins,
            counts: hist,
            edges: edges
        )
    }

    public static func histogram(
        _ matrix: Matrix,
        bins requestedBins: Int = 256
    ) -> HistogramStats? {
        guard let statistics = statistics(matrix) else { return nil }
        return HistogramStats(
            statistics: statistics,
            distribution: histogram(
                matrix,
                statistics: statistics,
                bins: requestedBins
            )
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
        guard let statistics = statistics(matrix) else { return nil }
        return automaticScale(statistics)
    }

    public static func automaticScale(
        _ statistics: MatrixStatistics
    ) -> (vmin: Double, vmax: Double) {
        if statistics.min == statistics.max {
            return (statistics.min, statistics.max)
        }
        if statistics.p99 <= statistics.p1 {
            return (statistics.min, statistics.max)
        }
        return (statistics.p1, statistics.p99)
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

private func percentile(_ sorted: [Float], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    if sorted.count == 1 { return Double(sorted[0]) }
    let pos = (p / 100) * Double(sorted.count - 1)
    let lo = Int(floor(pos))
    let hi = Int(ceil(pos))
    if lo == hi { return Double(sorted[lo]) }
    let t = pos - Double(lo)
    return Double(sorted[lo]) * (1 - t) + Double(sorted[hi]) * t
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
