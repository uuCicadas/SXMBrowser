import Testing
@testable import SXMBrowserAppCore

@Test
func keyboardRoutingMapsArrowKeysAndShiftRangeSelection() {
    #expect(
        BrowserKeyboardRouting.command(
            forMacVirtualKeyCode: 123,
            hasCommandModifiers: false,
            isShiftPressed: false,
            interactiveControlHasFocus: false
        ) == .move(.left, extendingSelection: false)
    )
    #expect(
        BrowserKeyboardRouting.command(
            forMacVirtualKeyCode: 125,
            hasCommandModifiers: false,
            isShiftPressed: true,
            interactiveControlHasFocus: false
        ) == .move(.down, extendingSelection: true)
    )
}

@Test
func keyboardRoutingMapsOpenAndGridCommands() {
    #expect(
        BrowserKeyboardRouting.command(
            forMacVirtualKeyCode: 36,
            hasCommandModifiers: false,
            isShiftPressed: false,
            interactiveControlHasFocus: false
        ) == .openSelection
    )
    #expect(
        BrowserKeyboardRouting.command(
            forMacVirtualKeyCode: 53,
            hasCommandModifiers: false,
            isShiftPressed: false,
            interactiveControlHasFocus: false
        ) == .showGrid
    )
}

@Test
func keyboardRoutingLeavesInteractiveAndModifiedKeysAlone() {
    for keyCode: UInt16 in [36, 53, 123, 124, 125, 126] {
        #expect(
            BrowserKeyboardRouting.command(
                forMacVirtualKeyCode: keyCode,
                hasCommandModifiers: true,
                isShiftPressed: false,
                interactiveControlHasFocus: false
            ) == nil
        )
        #expect(
            BrowserKeyboardRouting.command(
                forMacVirtualKeyCode: keyCode,
                hasCommandModifiers: false,
                isShiftPressed: false,
                interactiveControlHasFocus: true
            ) == nil
        )
    }

    #expect(
        BrowserKeyboardRouting.command(
            forMacVirtualKeyCode: 36,
            hasCommandModifiers: false,
            isShiftPressed: true,
            interactiveControlHasFocus: false
        ) == nil
    )
    #expect(
        BrowserKeyboardRouting.command(
            forMacVirtualKeyCode: 49,
            hasCommandModifiers: false,
            isShiftPressed: false,
            interactiveControlHasFocus: false
        ) == nil
    )
}
