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
