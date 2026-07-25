import Testing
@testable import SXMBrowserAppCore

@Test
func deletionPlanContainsOnlyVisibleSelectionInDisplayOrder() {
    let plan = FileDeletionPlan(
        visibleIDs: ["A", "C", "E"],
        selectedIDs: ["A", "B", "C", "D", "E"]
    )

    #expect(plan.targetIDs == ["A", "C", "E"])
}

@Test
func deletionPlanDeduplicatesVisibleInput() {
    let plan = FileDeletionPlan(
        visibleIDs: ["A", "A", "B"],
        selectedIDs: ["A", "B"]
    )

    #expect(plan.targetIDs == ["A", "B"])
}
