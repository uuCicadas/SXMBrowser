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
