import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

enum AppTheme {
    static let page = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .controlBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let control = Color(nsColor: .controlColor)
    static let toolbar = Color(nsColor: .windowBackgroundColor)
    static let stage = Color(nsColor: .underPageBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.16)
    static let histogramFill = Color(red: 0.86, green: 0.70, blue: 0.32)
    static let histogramStroke = Color(red: 0.98, green: 0.80, blue: 0.34)
    static let histogramHandle = Color(red: 0.30, green: 0.68, blue: 0.94)

    static func gridStage(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.100, green: 0.105, blue: 0.112)
            : Color(red: 0.945, green: 0.952, blue: 0.958)
    }

    static func cardSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.155, green: 0.162, blue: 0.172)
            : Color(red: 0.985, green: 0.987, blue: 0.990)
    }

    static func selectedTile(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.122, green: 0.205, blue: 0.335)
            : Color(red: 0.905, green: 0.940, blue: 0.990)
    }

    static func imageWell(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.090, green: 0.096, blue: 0.104)
            : Color(red: 0.928, green: 0.936, blue: 0.944)
    }

    static func tileBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.11)
            : Color.black.opacity(0.08)
    }

    static func elevatedCard(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.145, green: 0.152, blue: 0.165, opacity: 1)
            : Color(.sRGB, red: 0.992, green: 0.994, blue: 0.997, opacity: 1)
    }

    static func hairlineBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.09)
    }

    static let focusRing = Color.accentColor.opacity(0.65)

    static func plotCanvasBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.086, green: 0.094, blue: 0.108, opacity: 1)
            : Color(.sRGB, red: 0.992, green: 0.994, blue: 0.997, opacity: 1)
    }

    static func plotBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.24)
            : Color.black.opacity(0.28)
    }

    static func plotMajorGrid(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.08)
    }

    static func plotZeroLine(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.26)
            : Color.black.opacity(0.22)
    }

    static func plotAxisText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.76)
            : Color.black.opacity(0.72)
    }

    static func plotBadgeBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.125, green: 0.135, blue: 0.152, opacity: 0.88)
            : Color(.sRGB, red: 0.975, green: 0.980, blue: 0.988, opacity: 0.90)
    }

    static func histogramBarFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.88, green: 0.72, blue: 0.34).opacity(0.78)
            : Color(red: 0.84, green: 0.66, blue: 0.25).opacity(0.76)
    }

    static func histogramBarStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.99, green: 0.82, blue: 0.40)
            : Color(red: 0.72, green: 0.54, blue: 0.14)
    }

    static func histogramClipOverlay(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.black.opacity(0.36)
            : Color.black.opacity(0.09)
    }

    static func histogramHandleStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.36, green: 0.75, blue: 0.98)
            : Color(red: 0.14, green: 0.52, blue: 0.84)
    }

    static func missingDataLightTile(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.135, green: 0.142, blue: 0.156, opacity: 1)
            : Color(.sRGB, red: 0.945, green: 0.950, blue: 0.958, opacity: 1)
    }

    static func missingDataDarkTile(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.105, green: 0.112, blue: 0.124, opacity: 1)
            : Color(.sRGB, red: 0.895, green: 0.904, blue: 0.916, opacity: 1)
    }

    private static let siPrefixes: [(scale: Double, symbol: String)] = [
        (1e9, "G"),
        (1e6, "M"),
        (1e3, "k"),
        (1.0, ""),
        (1e-3, "m"),
        (1e-6, "µ"),
        (1e-9, "n"),
        (1e-12, "p"),
        (1e-15, "f"),
    ]

    static func formattedSI(
        _ value: Double,
        unit: String,
        maxFractionDigits: Int = 2
    ) -> String {
        guard value.isFinite else { return "—" }
        let suffix = unit.isEmpty ? "" : " \(unit)"
        if value == 0 || abs(value) < 1e-18 {
            return "0\(suffix)"
        }
        let absValue = abs(value)
        if let prefix = siPrefixes.first(where: { absValue >= $0.scale * 0.9995 }) {
            let scaled = value / prefix.scale
            let number = formatScalar(scaled, maxFractionDigits: maxFractionDigits)
            let prefixedUnit = "\(prefix.symbol)\(unit)"
            return prefixedUnit.isEmpty ? number : "\(number) \(prefixedUnit)"
        }
        return "\(String(format: "%.2e", value))\(suffix)"
    }

    static func formattedScanFootprint(_ range: InspectorCoordinatePair?) -> String? {
        guard let range else { return nil }
        return formattedScanFootprint((x: range.x, y: range.y))
    }

    static func formattedScanFootprint(_ range: (x: Double, y: Double)?) -> String? {
        guard let range,
              range.x.isFinite, range.y.isFinite,
              range.x > 0, range.y > 0 else {
            return nil
        }
        let dominant = max(range.x, range.y)
        if let prefix = siPrefixes.first(where: { dominant >= $0.scale * 0.9995 }) {
            let minRatio = min(range.x, range.y) / prefix.scale
            if minRatio >= 0.05 {
                let xText = formatScalar(range.x / prefix.scale, maxFractionDigits: 2)
                let yText = formatScalar(range.y / prefix.scale, maxFractionDigits: 2)
                return "\(xText) × \(yText) \(prefix.symbol)m"
            }
        }
        return "\(formattedSI(range.x, unit: "m")) × \(formattedSI(range.y, unit: "m"))"
    }

    static func formattedDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 {
            return "\(formatScalar(seconds, maxFractionDigits: 1)) s"
        }
        let rounded = Int(seconds.rounded())
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let remSeconds = rounded % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(remSeconds)s"
    }

    static func formattedTemperature(_ kelvin: Double) -> String {
        guard kelvin.isFinite, kelvin > 0 else { return "—" }
        if kelvin < 20 {
            return String(format: "%.2f K", kelvin)
        }
        return String(format: "%.1f K", kelvin)
    }

    private static func formatScalar(_ value: Double, maxFractionDigits: Int) -> String {
        let magnitude = abs(value)
        let digits: Int
        if magnitude >= 100 {
            digits = 0
        } else if magnitude >= 10 {
            digits = min(maxFractionDigits, 1)
        } else {
            digits = maxFractionDigits
        }
        var text = String(format: "%.*f", digits, value)
        if text.contains(".") {
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

struct MissingDataBackdrop: View {
    var tileSize: CGFloat = 8
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let step = max(4, tileSize)
            let light = AppTheme.missingDataLightTile(for: colorScheme)
            let dark = AppTheme.missingDataDarkTile(for: colorScheme)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))

            let columns = Int(ceil(size.width / step))
            let rows = Int(ceil(size.height / step))
            var darkPath = Path()
            for row in 0..<rows {
                for col in 0..<columns where (row + col).isMultiple(of: 2) {
                    darkPath.addRect(
                        CGRect(
                            x: CGFloat(col) * step,
                            y: CGFloat(row) * step,
                            width: step,
                            height: step
                        )
                    )
                }
            }
            context.fill(darkPath, with: .color(dark))
        }
        .accessibilityHidden(true)
    }
}

func compact(_ value: Double) -> String {
    if value == 0 { return "0" }
    let absValue = abs(value)

    let prefixes: [(Double, String)] = [
        (1e9, "G"),
        (1e6, "M"),
        (1e3, "k"),
        (1.0, ""),
        (1e-3, "m"),
        (1e-6, "u"),
        (1e-9, "n"),
        (1e-12, "p"),
    ]

    if let prefix = prefixes.first(where: { absValue >= $0.0 }) {
        let scaled = value / prefix.0
        let magnitude = abs(scaled)
        let format: String
        if magnitude >= 100 {
            format = "%.0f%@"
        } else if magnitude >= 10 {
            format = "%.2g%@"
        } else {
            format = "%.3g%@"
        }
        return String(format: format, scaled, prefix.1)
    }

    return String(format: "%.3e", value)
}

private struct CursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    if !isPushed {
                        cursor.push()
                        isPushed = true
                    }
                } else if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
            .onDisappear {
                if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorModifier(cursor: cursor))
    }
}
