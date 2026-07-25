import Testing
@testable import SXMBrowserAppCore

@Test
func selectionActionsUseVisibleOrderAndIgnoreHiddenSelections() {
    let presentation = SelectionActionPresentation(
        visibleIDs: ["C", "A", "C", "D"],
        selectedIDs: ["A", "B", "C"]
    )

    #expect(presentation.orderedIDs == ["C", "A"])
    #expect(presentation.placement == .actionBar)
}

@Test
func selectionActionPlacementUsesNoneOverflowAndActionBarThresholds() {
    #expect(
        SelectionActionPresentation(
            visibleIDs: ["A"],
            selectedIDs: []
        ).placement == .none
    )
    #expect(
        SelectionActionPresentation(
            visibleIDs: ["A", "B"],
            selectedIDs: ["A", "hidden"]
        ).placement == .overflow
    )
    #expect(
        SelectionActionPresentation(
            visibleIDs: ["A", "B"],
            selectedIDs: ["A", "B"]
        ).placement == .actionBar
    )
}

@Test
func filteringASelectionCanCollapseTheActionBarToOverflow() {
    let selected: Set<String> = ["A", "B", "C"]
    let before = SelectionActionPresentation(
        visibleIDs: ["A", "B", "C"],
        selectedIDs: selected
    )
    let after = SelectionActionPresentation(
        visibleIDs: ["B"],
        selectedIDs: selected
    )

    #expect(before.placement == .actionBar)
    #expect(after.orderedIDs == ["B"])
    #expect(after.placement == .overflow)
}
