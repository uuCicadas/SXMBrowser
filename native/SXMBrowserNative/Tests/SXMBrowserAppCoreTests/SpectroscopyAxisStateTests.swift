import Testing
@testable import SXMBrowserAppCore

@Test
func spectroscopyGroupsKeepIndependentAxisSelections() throws {
    var state = SpectroscopyAxisState()
    let biasColumns = ["Bias (V)", "Current (A)", "Frequency (Hz)"]
    let zColumns = ["Z (m)", "Current (A)", "Phase (deg)"]

    state.ensureSelection(
        forGroupID: "bias-schema",
        availableColumns: biasColumns,
        preferredX: "Bias (V)",
        preferredY: "Current (A)"
    )
    state.ensureSelection(
        forGroupID: "z-schema",
        availableColumns: zColumns,
        preferredX: "Z (m)",
        preferredY: "Current (A)"
    )
    let changedBiasAxis = state.setYColumn(
        "Frequency (Hz)",
        forGroupID: "bias-schema",
        availableColumns: biasColumns,
        preferredX: "Bias (V)",
        preferredY: "Current (A)"
    )
    let changedZAxis = state.setXColumn(
        "Phase (deg)",
        forGroupID: "z-schema",
        availableColumns: zColumns,
        preferredX: "Z (m)",
        preferredY: "Current (A)"
    )
    #expect(changedBiasAxis)
    #expect(changedZAxis)

    let bias = try #require(state.selection(forGroupID: "bias-schema"))
    let z = try #require(state.selection(forGroupID: "z-schema"))
    #expect(bias == AxisSelection(
        xColumn: "Bias (V)",
        yColumn: "Frequency (Hz)"
    ))
    #expect(z == AxisSelection(
        xColumn: "Phase (deg)",
        yColumn: "Current (A)"
    ))
}

@Test
func invalidAxisColumnIsRejectedWithoutChangingSelection() throws {
    var state = SpectroscopyAxisState()
    let columns = ["Bias (V)", "Current (A)"]
    let ensured = state.ensureSelection(
        forGroupID: "bias-schema",
        availableColumns: columns,
        preferredX: "Bias (V)",
        preferredY: "Current (A)"
    )
    let initial = try #require(ensured)

    let changedInvalidAxis = state.setYColumn(
        "Missing",
        forGroupID: "bias-schema",
        availableColumns: columns,
        preferredX: "Bias (V)",
        preferredY: "Current (A)"
    )
    #expect(!changedInvalidAxis)
    #expect(state.selection(forGroupID: "bias-schema") == initial)
}

@Test
func stableGroupIDPreservesSelectionAcrossContextSwitches() throws {
    var state = SpectroscopyAxisState()
    let firstColumns = ["Bias (V)", "Current (A)", "Phase (deg)"]

    state.ensureSelection(
        forGroupID: "first-file-bias-schema",
        availableColumns: firstColumns,
        preferredX: "Bias (V)",
        preferredY: "Current (A)"
    )
    let changedFirstFileAxis = state.setYColumn(
        "Phase (deg)",
        forGroupID: "first-file-bias-schema",
        availableColumns: firstColumns,
        preferredX: "Bias (V)",
        preferredY: "Current (A)"
    )
    #expect(changedFirstFileAxis)

    state.ensureSelection(
        forGroupID: "second-file-z-schema",
        availableColumns: ["Z (m)", "Current (A)"],
        preferredX: "Z (m)",
        preferredY: "Current (A)"
    )
    let restoredSelection = state.ensureSelection(
        forGroupID: "first-file-bias-schema",
        availableColumns: [" bias (v) ", "current (a)", "phase (deg)"],
        preferredX: " bias (v) ",
        preferredY: "current (a)"
    )
    let restored = try #require(restoredSelection)

    #expect(restored.xColumn == " bias (v) ")
    #expect(restored.yColumn == "phase (deg)")
}

@Test
func emptyGroupCannotRetainAnInvalidSelection() {
    var state = SpectroscopyAxisState()
    state.ensureSelection(
        forGroupID: "group",
        availableColumns: ["X", "Y"],
        preferredX: "X",
        preferredY: "Y"
    )

    #expect(
        state.ensureSelection(
            forGroupID: "group",
            availableColumns: [],
            preferredX: "X",
            preferredY: "Y"
        ) == nil
    )
    #expect(state.selection(forGroupID: "group") == nil)
}
