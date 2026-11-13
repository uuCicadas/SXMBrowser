import SwiftUI
import SXMBrowserAppCore

/// A plain image annotation: the filled line's width is the calibrated length.
struct ScreenScaleBar: View {
    let scaleBar: ScaleBar

    static let height: CGFloat = 38
    static let edgeInset: CGFloat = 16

    var body: some View {
        VStack(spacing: 5) {
            Text(scaleBar.label)
                .font(.system(size: 22, weight: .regular))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.35)

            Rectangle()
                .frame(height: 4)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.75), radius: 1.5, x: 0, y: 0.5)
        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
        .frame(
            width: CGFloat(scaleBar.screenLengthPoints),
            height: Self.height,
            alignment: .bottom
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scale bar")
        .accessibilityValue(scaleBar.label)
    }
}
