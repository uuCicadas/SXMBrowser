public enum BrowserKeyboardCommand: Equatable, Sendable {
    case move(
        GridNavigationDirection,
        extendingSelection: Bool
    )
    case openSelection
    case showGrid
}

public enum BrowserKeyboardRouting {
    public static func command(
        forMacVirtualKeyCode keyCode: UInt16,
        hasCommandModifiers: Bool,
        isShiftPressed: Bool,
        interactiveControlHasFocus: Bool
    ) -> BrowserKeyboardCommand? {
        guard !hasCommandModifiers,
              !interactiveControlHasFocus else {
            return nil
        }

        switch keyCode {
        case 123:
            return .move(
                .left,
                extendingSelection: isShiftPressed
            )
        case 124:
            return .move(
                .right,
                extendingSelection: isShiftPressed
            )
        case 125:
            return .move(
                .down,
                extendingSelection: isShiftPressed
            )
        case 126:
            return .move(
                .up,
                extendingSelection: isShiftPressed
            )
        case 36 where !isShiftPressed:
            return .openSelection
        case 53 where !isShiftPressed:
            return .showGrid
        default:
            return nil
        }
    }
}
