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
        try! processedMatrix(
            matrix,
            processing: processing,
            cancellation: .none
        )
    }

    public static func processedMatrix(
        _ matrix: Matrix,
        processing: ProcessingMode,
        cancellation: CancellationCheckpoint
    ) throws -> Matrix {
        try cancellation.check()
        switch processing {
        case .raw:
            return matrix
        case .lineMean:
            return try lineMeanSubtract(matrix, cancellation: cancellation)
        case .lineSlope:
            return try lineSlopeSubtract(matrix, cancellation: cancellation)
        case .lineLinear:
            return try lineLinearFit(matrix, cancellation: cancellation)
        case .lineDerivative:
            return try lineDifferentiate(matrix, cancellation: cancellation)
        case .planeLinear:
            return try planeLinearFit(matrix, cancellation: cancellation)
        }
    }

    public static func statistics(_ matrix: Matrix) -> MatrixStatistics? {
        try! statistics(matrix, cancellation: .none)
    }

    public static func statistics(
        _ matrix: Matrix,
        cancellation: CancellationCheckpoint
    ) throws -> MatrixStatistics? {
        try cancellation.check()
        var finite: [Float] = []
        finite.reserveCapacity(matrix.values.count)

        var mean = 0.0
        var sumOfSquaredDeviations = 0.0
        for (index, sample) in matrix.values.enumerated() {
            if index.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            guard sample.isFinite else { continue }
            finite.append(sample)
            let value = Double(sample)
            let count = Double(finite.count)
            let delta = value - mean
            mean += delta / count
            let adjustedDelta = value - mean
            sumOfSquaredDeviations += delta * adjustedDelta
        }
        guard !finite.isEmpty else { return nil }

        try cancellation.check()
        finite.sort()
        try cancellation.check()
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
        try! histogram(
            matrix,
            statistics: statistics,
            bins: requestedBins,
            cancellation: .none
        )
    }

    public static func histogram(
        _ matrix: Matrix,
        statistics: MatrixStatistics,
        bins requestedBins: Int = 256,
        cancellation: CancellationCheckpoint
    ) throws -> HistogramDistribution {
        try cancellation.check()
        let bins = max(16, min(2048, requestedBins))
        if statistics.max == statistics.min {
            var hist = [Int](repeating: 0, count: bins)
            var finiteCount = 0
            for (index, sample) in matrix.values.enumerated() {
                if index.isMultiple(of: 4_096) {
                    try cancellation.check()
                }
                if sample.isFinite {
                    finiteCount += 1
                }
            }
            hist[bins / 2] = finiteCount
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
        for (index, sample) in matrix.values.enumerated() {
            if index.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            guard sample.isFinite else { continue }
            let value = Double(sample)
            let idx = min(
                bins - 1,
                max(0, Int((value - statistics.min) / width))
            )
            hist[idx] += 1
        }
        try cancellation.check()
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
        try! histogram(
            matrix,
            bins: requestedBins,
            cancellation: .none
        )
    }

    public static func histogram(
        _ matrix: Matrix,
        bins requestedBins: Int = 256,
        cancellation: CancellationCheckpoint
    ) throws -> HistogramStats? {
        guard let statistics = try statistics(
            matrix,
            cancellation: cancellation
        ) else {
            return nil
        }
        return HistogramStats(
            statistics: statistics,
            distribution: try histogram(
                matrix,
                statistics: statistics,
                bins: requestedBins,
                cancellation: cancellation
            )
        )
    }

    public static func renderImage(
        matrix: Matrix,
        options: RenderOptions,
        cancellation: CancellationCheckpoint = .none
    ) throws -> NSImage {
        let processed = try processedMatrix(
            matrix,
            processing: options.processing,
            cancellation: cancellation
        )
        return try renderProcessedImage(
            matrix: processed,
            options: options,
            cancellation: cancellation
        )
    }

    public static func renderProcessedImage(
        matrix: Matrix,
        options: RenderOptions,
        cancellation: CancellationCheckpoint = .none
    ) throws -> NSImage {
        let rgba = try colorize(
            matrix: matrix,
            palette: options.palette,
            vmin: options.vmin,
            vmax: options.vmax,
            invert: options.invert,
            cancellation: cancellation
        )
        try cancellation.check()
        guard let cgImage = makeCGImage(rgba: rgba, width: matrix.width, height: matrix.height) else {
            throw SXMRenderError.imageCreationFailed
        }
        try cancellation.check()
        let image = NSImage(cgImage: cgImage, size: NSSize(width: matrix.width, height: matrix.height))
        if let outputSize = options.outputSize {
            return try resized(
                image,
                maxSide: CGFloat(outputSize),
                cancellation: cancellation
            )
        }
        return image
    }

    public static func pngData(
        matrix: Matrix,
        options: RenderOptions,
        cancellation: CancellationCheckpoint = .none
    ) throws -> Data {
        let image = try renderImage(
            matrix: matrix,
            options: options,
            cancellation: cancellation
        )
        try cancellation.check()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw SXMRenderError.imageCreationFailed
        }
        try cancellation.check()
        return png
    }

    public static func automaticScale(_ matrix: Matrix) -> (vmin: Double, vmax: Double)? {
        try! automaticScale(matrix, cancellation: .none)
    }

    public static func automaticScale(
        _ matrix: Matrix,
        cancellation: CancellationCheckpoint
    ) throws -> (vmin: Double, vmax: Double)? {
        guard let statistics = try statistics(
            matrix,
            cancellation: cancellation
        ) else {
            return nil
        }
        return automaticScale(statistics)
    }

    public static func automaticScale(
        _ statistics: MatrixStatistics
    ) -> (vmin: Double, vmax: Double) {
        (statistics.min, statistics.max)
    }

    public static func colorize(
        matrix: Matrix,
        palette: PaletteName,
        vmin: Double?,
        vmax: Double?,
        invert: Bool
    ) -> [UInt8] {
        try! colorize(
            matrix: matrix,
            palette: palette,
            vmin: vmin,
            vmax: vmax,
            invert: invert,
            cancellation: .none
        )
    }

    public static func colorize(
        matrix: Matrix,
        palette: PaletteName,
        vmin: Double?,
        vmax: Double?,
        invert: Bool,
        cancellation: CancellationCheckpoint
    ) throws -> [UInt8] {
        let auto = try (vmin == nil || vmax == nil)
            ? automaticScale(matrix, cancellation: cancellation)
            : nil
        let lo = vmin ?? auto?.vmin ?? 0
        let hi = vmax ?? auto?.vmax ?? 1
        let hasSpan = lo.isFinite && hi.isFinite && hi > lo

        try cancellation.check()
        let stops = PaletteStore.shared.stops(for: palette)
        var rgba = [UInt8](repeating: 255, count: matrix.width * matrix.height * 4)
        for idx in matrix.values.indices {
            if idx.isMultiple(of: 4_096) {
                try cancellation.check()
            }
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
        try cancellation.check()
        return rgba
    }
}

private func lineMeanSubtract(
    _ matrix: Matrix,
    cancellation: CancellationCheckpoint
) throws -> Matrix {
    var output = matrix
    for y in 0..<matrix.height {
        try cancellation.check()
        var sum = 0.0
        var count = 0.0
        for x in 0..<matrix.width {
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            let value = matrix[x, y]
            if value.isFinite {
                sum += Double(value)
                count += 1
            }
        }
        guard count > 0 else { continue }
        let mean = Float(sum / count)
        for x in 0..<matrix.width {
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            output[x, y] = matrix[x, y] - mean
        }
    }
    return output
}

/// Removes each scan line's least-squares slope and intercept using finite samples.
private func lineLinearFit(
    _ matrix: Matrix,
    cancellation: CancellationCheckpoint
) throws -> Matrix {
    var output = matrix

    for y in 0..<matrix.height {
        try cancellation.check()
        var valid = 0.0
        var sx = 0.0
        var sy = 0.0
        var sxx = 0.0
        var sxy = 0.0
        for x in 0..<matrix.width {
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
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
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            // Subtract before narrowing so a small residual is not rounded away
            // when the original signal has a much larger constant offset.
            output[x, y] = Float(Double(matrix[x, y]) - (slope * Double(x) + intercept))
        }
    }
    return output
}

private func lineSlopeSubtract(
    _ matrix: Matrix,
    cancellation: CancellationCheckpoint
) throws -> Matrix {
    var output = matrix

    for y in 0..<matrix.height {
        try cancellation.check()
        var valid = 0.0
        var sx = 0.0
        var sy = 0.0
        var sxx = 0.0
        var sxy = 0.0
        for x in 0..<matrix.width {
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
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
        let meanX = sx / valid
        for x in 0..<matrix.width {
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            output[x, y] = matrix[x, y] - Float(slope * (Double(x) - meanX))
        }
    }
    return output
}

private func lineDifferentiate(
    _ matrix: Matrix,
    cancellation: CancellationCheckpoint
) throws -> Matrix {
    var output = matrix

    for y in 0..<matrix.height {
        try cancellation.check()
        for x in 0..<matrix.width {
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            let current = matrix[x, y]
            guard current.isFinite else {
                output[x, y] = .nan
                continue
            }
            let left = x > 0 ? matrix[x - 1, y] : .nan
            let right = x + 1 < matrix.width ? matrix[x + 1, y] : .nan
            if left.isFinite && right.isFinite {
                output[x, y] = (right - left) / 2
            } else if right.isFinite {
                output[x, y] = right - current
            } else if left.isFinite {
                output[x, y] = current - left
            } else {
                output[x, y] = 0
            }
        }
    }
    return output
}

/// Removes one least-squares plane z = ax + by + c across all finite pixels.
/// A unique plane requires at least three non-collinear finite samples; otherwise
/// leave the data unchanged rather than silently choosing a different correction.
private func planeLinearFit(
    _ matrix: Matrix,
    cancellation: CancellationCheckpoint
) throws -> Matrix {
    // Normalize coordinates and remove a reference height before accumulating.
    // Centering avoids subtracting large, nearly equal normal-equation terms.
    let xScale = Double(max(1, matrix.width - 1))
    let yScale = Double(max(1, matrix.height - 1))
    var referenceHeight: Double?
    var count = 0.0
    var sumX = 0.0
    var sumY = 0.0
    var sumZ = 0.0
    for y in 0..<matrix.height {
        try cancellation.check()
        for x in 0..<matrix.width {
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            let value = matrix[x, y]
            guard value.isFinite else { continue }
            let z = Double(value)
            if referenceHeight == nil { referenceHeight = z }
            count += 1
            sumX += Double(x) / xScale
            sumY += Double(y) / yScale
            sumZ += z - referenceHeight!
        }
    }
    guard count >= 3, let referenceHeight else { return matrix }
    let meanX = sumX / count
    let meanY = sumY / count
    let meanZ = sumZ / count

    var xx = 0.0
    var xy = 0.0
    var yy = 0.0
    var xz = 0.0
    var yz = 0.0
    for y in 0..<matrix.height {
        try cancellation.check()
        for x in 0..<matrix.width {
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            let value = matrix[x, y]
            guard value.isFinite else { continue }
            let dx = Double(x) / xScale - meanX
            let dy = Double(y) / yScale - meanY
            let dz = (Double(value) - referenceHeight) - meanZ
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
            xz += dx * dz
            yz += dy * dz
        }
    }
    let determinant = xx * yy - xy * xy
    // Relative rank check covers single rows, columns, and arbitrary collinear
    // masks without a height-unit-dependent absolute pivot threshold.
    guard xx > 0, yy > 0,
          determinant > 64 * Double.ulpOfOne * xx * yy else { return matrix }
    let slopeX = (xz * yy - yz * xy) / determinant
    let slopeY = (yz * xx - xz * xy) / determinant

    var output = matrix
    for y in 0..<matrix.height {
        try cancellation.check()
        for x in 0..<matrix.width {
            if x.isMultiple(of: 4_096) {
                try cancellation.check()
            }
            let value = matrix[x, y]
            guard value.isFinite else { continue }
            let fittedOffset = meanZ
                + slopeX * (Double(x) / xScale - meanX)
                + slopeY * (Double(y) / yScale - meanY)
            // Keep the subtraction in Double: converting the fitted plane to
            // Float first can erase small residuals above a large baseline.
            output[x, y] = Float((Double(value) - referenceHeight) - fittedOffset)
        }
    }
    return output
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
    guard value.isFinite else { return (last.r, last.g, last.b) }

    // Locate the first stop at or above the value. Exact stop matches use
    // the preceding interval, preserving the original interpolation arithmetic.
    var lower = 1
    var upper = stops.count - 1
    while lower < upper {
        let middle = lower + (upper - lower) / 2
        if value <= stops[middle].position {
            upper = middle
        } else {
            lower = middle + 1
        }
    }
    let a = stops[lower - 1]
    let b = stops[lower]
    let span = max(1e-12, b.position - a.position)
    let t = (value - a.position) / span
    return (
        a.r * (1 - t) + b.r * t,
        a.g * (1 - t) + b.g * t,
        a.b * (1 - t) + b.b * t
    )
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

private func resized(
    _ image: NSImage,
    maxSide: CGFloat,
    cancellation: CancellationCheckpoint
) throws -> NSImage {
    try cancellation.check()
    let size = image.size
    let scale = min(1, maxSide / max(size.width, size.height))
    let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    let output = NSImage(size: target)
    output.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
    output.unlockFocus()
    try cancellation.check()
    return output
}
