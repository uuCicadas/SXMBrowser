import SwiftUI
import SXMBrowserAppCore

/// A calibrated image annotation: the horizontal bar's width equals the calibrated length.
struct ScreenScaleBar: View {
    let scaleBar: ScaleBar

    static let height: CGFloat = 30
    static let edgeInset: CGFloat = 14

    var body: some View {
        let barWidth = max(4, CGFloat(scaleBar.screenLengthPoints))
        VStack(spacing: 4) {
            Text(scaleBar.label)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.85), radius: 1.5, x: 0, y: 0.5)
                .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)

            ZStack(alignment: .bottom) {
                scaleShape(width: barWidth)
                    .stroke(Color.black.opacity(0.75), lineWidth: 4.5)
                scaleShape(width: barWidth)
                    .stroke(Color.white, lineWidth: 2.2)
            }
            .frame(width: barWidth, height: 6)
        }
        .frame(
            width: barWidth,
            height: Self.height,
            alignment: .bottom
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scale bar")
        .accessibilityValue(scaleBar.label)
    }

    private func scaleShape(width: CGFloat) -> Path {
        var path = Path()
        let yBottom: CGFloat = 5.5
        let yTop: CGFloat = 0.5
        let yBar: CGFloat = 4.5
        path.move(to: CGPoint(x: 0.5, y: yTop))
        path.addLine(to: CGPoint(x: 0.5, y: yBottom))
        path.move(to: CGPoint(x: 0.5, y: yBar))
        path.addLine(to: CGPoint(x: max(0.5, width - 0.5), y: yBar))
        path.move(to: CGPoint(x: max(0.5, width - 0.5), y: yTop))
        path.addLine(to: CGPoint(x: max(0.5, width - 0.5), y: yBottom))
        return path
    }
}
