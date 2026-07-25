import Testing
@testable import SXMBrowserAppCore

private enum Item: String, Sendable {
    case a, b, c, d, e
}

private func expectValid(
    _ state: SelectionState<Item>,
    visibleIDs: [Item]
) {
    let visibleSet = Set(visibleIDs)
    #expect(state.selectedIDs.isSubset(of: visibleSet))
    #expect((state.primaryID == nil) == state.selectedIDs.isEmpty)
    if let primaryID = state.primaryID {
        #expect(state.selectedIDs.contains(primaryID))
    }
    if let anchorID = state.anchorID {
        #expect(visibleSet.contains(anchorID))
    }
}

@Test
func rangeSelectionUsesOnlyVisibleItems() {
    let visible: [Item] = [.a, .c, .e]
    var state = SelectionState<Item>()

    state.selectOnly(.a, in: visible)
    state.selectRange(to: .e, in: visible)

    #expect(state.primaryID == .e)
    #expect(state.anchorID == .a)
    #expect(state.selectedIDs == [.a, .c, .e])
    expectValid(state, visibleIDs: visible)
}

@Test
func filteringConvergesSelectionAndClearsEmptyResults() {
    var state = SelectionState<Item>()
    let all: [Item] = [.a, .b, .c]
    state.selectAll(in: all)
    state.selectOnly(.a, in: all)
    state.toggle(.b, in: all)

    state.reconcile(with: [.b], fallbackToFirst: false)
    #expect(state.primaryID == .b)
    #expect(state.selectedIDs == [.b])
    expectValid(state, visibleIDs: [.b])

    state.reconcile(with: [], fallbackToFirst: false)
    #expect(state == SelectionState<Item>())
    expectValid(state, visibleIDs: [])
}

@Test
func togglingPrimaryChoosesFirstRemainingVisibleItem() {
    let visible: [Item] = [.a, .b, .c]
    var state = SelectionState<Item>()
    state.selectAll(in: visible)
    state.selectOnly(.b, in: visible)
    state.toggle(.a, in: visible)
    state.toggle(.c, in: visible)

    state.toggle(.c, in: visible)

    #expect(state.primaryID == .a)
    #expect(state.selectedIDs == [.a, .b])
    #expect(state.anchorID == .a)
    expectValid(state, visibleIDs: visible)
}

@Test
func selectAllNeverIncludesHiddenItems() {
    var state = SelectionState<Item>()
    state.selectOnly(.b, in: [.a, .b, .c])

    state.selectAll(in: [.a, .c])

    #expect(state.primaryID == .a)
    #expect(state.selectedIDs == [.a, .c])
    expectValid(state, visibleIDs: [.a, .c])
}

@Test
func steppingDoesNotClampAtEitherEnd() {
    let visible: [Item] = [.a, .b, .c]
    var state = SelectionState<Item>()
    state.selectOnly(.a, in: visible)

    #expect(!state.canStep(by: -1, in: visible))
    #expect(state.canStep(by: 1, in: visible))
    state.step(by: -1, in: visible)
    #expect(state.primaryID == .a)

    state.step(by: 1, in: visible)
    #expect(state.primaryID == .b)
    state.step(by: 1, in: visible)
    #expect(state.primaryID == .c)
    #expect(state.canStep(by: -1, in: visible))
    #expect(!state.canStep(by: 1, in: visible))
    state.step(by: 1, in: visible)
    #expect(state.primaryID == .c)
    expectValid(state, visibleIDs: visible)
}

@Test
func removalChoosesSuccessorThenPredecessor() {
    let oldVisible: [Item] = [.a, .b, .c, .d]
    var middle = SelectionState<Item>()
    middle.selectOnly(.b, in: oldVisible)

    middle.reconcileAfterRemoval(
        removedIDs: [.b],
        oldVisibleIDs: oldVisible,
        newVisibleIDs: [.a, .c, .d]
    )

    #expect(middle.primaryID == .c)
    expectValid(middle, visibleIDs: [.a, .c, .d])

    var last = SelectionState<Item>()
    last.selectOnly(.d, in: oldVisible)
    last.reconcileAfterRemoval(
        removedIDs: [.d],
        oldVisibleIDs: oldVisible,
        newVisibleIDs: [.a, .b, .c]
    )

    #expect(last.primaryID == .c)
    expectValid(last, visibleIDs: [.a, .b, .c])
}

@Test
func failedRemovalKeepsSurvivingPrimarySelected() {
    let visible: [Item] = [.a, .b, .c]
    var state = SelectionState<Item>()
    state.selectOnly(.b, in: visible)

    state.reconcileAfterRemoval(
        removedIDs: [.a],
        oldVisibleIDs: visible,
        newVisibleIDs: [.b, .c]
    )

    #expect(state.primaryID == .b)
    #expect(state.selectedIDs == [.b])
    expectValid(state, visibleIDs: [.b, .c])
}
