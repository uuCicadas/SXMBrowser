import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct PaletteStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: PaletteName
    let invert: Bool

    var body: some View {
        LinearGradient(
            gradient: Gradient(stops: gradientStops),
            startPoint: .leading,
            endPoint: .trailing
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var gradientStops: [Gradient.Stop] {
        let stops = PaletteStore.shared.stops(for: palette)
        guard !stops.isEmpty else {
            return [Gradient.Stop(color: .gray, location: 0)]
        }
        if invert {
            return stops.reversed().map { stop in
                Gradient.Stop(
                    color: Color(.sRGB, red: stop.r, green: stop.g, blue: stop.b, opacity: 1),
                    location: 1.0 - stop.position
                )
            }
        }
        return stops.map { stop in
            Gradient.Stop(
                color: Color(.sRGB, red: stop.r, green: stop.g, blue: stop.b, opacity: 1),
                location: stop.position
            )
        }
    }
}

