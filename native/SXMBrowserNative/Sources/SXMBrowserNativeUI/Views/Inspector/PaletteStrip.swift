import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct PaletteStrip: View {
    let palette: PaletteName
    let invert: Bool

    var body: some View {
        Canvas { context, size in
            let stops = PaletteStore.shared.stops(for: palette)
            let steps = max(2, Int(size.width))
            for idx in 0..<steps {
                let t = Double(idx) / Double(steps - 1)
                let sample = invert ? 1 - t : t
                let color = paletteColor(stops: stops, at: sample)
                let rect = CGRect(x: CGFloat(idx), y: 0, width: 1.5, height: size.height)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func paletteColor(stops: [PaletteStop], at value: Double) -> Color {
        guard let first = stops.first, let last = stops.last else { return .gray }
        if value <= first.position { return Color(red: first.r, green: first.g, blue: first.b) }
        if value >= last.position { return Color(red: last.r, green: last.g, blue: last.b) }
        for idx in 0..<(stops.count - 1) {
            let a = stops[idx]
            let b = stops[idx + 1]
            if value >= a.position && value <= b.position {
                let span = max(1e-12, b.position - a.position)
                let t = (value - a.position) / span
                return Color(
                    red: a.r * (1 - t) + b.r * t,
                    green: a.g * (1 - t) + b.g * t,
                    blue: a.b * (1 - t) + b.b * t
                )
            }
        }
        return Color(red: last.r, green: last.g, blue: last.b)
    }
}

