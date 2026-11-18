import SXMBrowserAppCore
import Testing
@testable import SXMBrowserNativeUI

@Test
func gridCardClickActionDispatchesSingleAndDoubleClickImmediately() {
    #expect(
        GridCardClickAction.resolve(
            clickCount: 1,
            isControlModified: false,
            isCommandModified: false,
            isShiftModified: false
        ) == .select(SelectionGestureModifiers(command: false, shift: false))
    )

    #expect(
        GridCardClickAction.resolve(
            clickCount: 2,
            isControlModified: false,
            isCommandModified: false,
            isShiftModified: false
        ) == .selectAndOpenSingle
    )

    #expect(
        GridCardClickAction.resolve(
            clickCount: 2,
            isControlModified: false,
            isCommandModified: true,
            isShiftModified: false
        ) == .select(SelectionGestureModifiers(command: true, shift: false))
    )

    #expect(
        GridCardClickAction.resolve(
            clickCount: 2,
            isControlModified: false,
            isCommandModified: false,
            isShiftModified: true
        ) == .select(SelectionGestureModifiers(command: false, shift: true))
    )

    #expect(
        GridCardClickAction.resolve(
            clickCount: 1,
            isControlModified: true,
            isCommandModified: false,
            isShiftModified: false
        ) == .ignore
    )
}
