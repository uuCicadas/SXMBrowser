import SwiftUI

/// Motion belongs to discrete UI feedback, never to live scientific data or gestures.
enum BrowserMotion {
    case feedback
    case navigation
    case disclosure

    func animation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch self {
        case .feedback:
            return .easeOut(duration: 0.12)
        case .navigation:
            return .easeInOut(duration: 0.18)
        case .disclosure:
            return .easeInOut(duration: 0.20)
        }
    }

    static func reveal(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .move(edge: edge).combined(with: .opacity)
    }
}

private struct BrowserMotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let motion: BrowserMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func browserMotion<Value: Equatable>(
        _ motion: BrowserMotion,
        value: Value
    ) -> some View {
        modifier(BrowserMotionModifier(motion: motion, value: value))
    }
}
