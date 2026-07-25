import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private func axisPreferenceIndex(
    folder: URL,
    sxmItems: [(UUID, String)]
) throws -> DatasetPathIndex {
    try DatasetPathIndex(
        folderURL: folder,
        sxmItems: sxmItems.map {
            DatasetPathItem(
                id: $0.0,
                url: folder.appendingPathComponent($0.1)
            )
        },
        datItems: []
    )
}

private func axisRuntimeGroup(
    id: String,
    sxmID: UUID,
    kind: SpectroscopyKind = .bias,
    experimentIdentity: String? = nil,
    columns: [String],
    preferredX: String,
    preferredY: String
) -> SpectrumAxisRuntimeGroup {
    SpectrumAxisRuntimeGroup(
        id: id,
        sxmID: sxmID,
        kind: kind,
        experimentIdentity: experimentIdentity,
        schemaFingerprint:
            SpectroscopyColumnSchema(columns: columns).fingerprint,
        availableColumns: columns,
        preferredX: preferredX,
        preferredY: preferredY
    )
}

private func axisPreference(
    sxmPath: String,
    group: SpectrumAxisRuntimeGroup,
    x: String,
    y: String
) throws -> SpectrumAxisPreferenceV1 {
    try SpectrumAxisPreferenceV1(
        sxmPath: sxmPath,
        kind: group.kind,
        experimentIdentity: group.experimentIdentity,
        schemaFingerprint: group.schemaFingerprint,
        selection: AxisSelection(xColumn: x, yColumn: y)
    )
}

private func legacyAxisPreference(
    sxmPath: String,
    group: SpectrumAxisRuntimeGroup,
    x: String,
    y: String
) throws -> SpectrumAxisPreferenceV1 {
    try SpectrumAxisPreferenceV1(
        sxmPath: sxmPath,
        kind: group.kind,
        schemaFingerprint: group.schemaFingerprint,
        selection: AxisSelection(xColumn: x, yColumn: y)
    )
}

@Test
func stableAxisPreferenceRestoresAfterRuntimeIDsChange() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Reopen")
    let firstSXMID = UUID()
    let reopenedSXMID = UUID()
    let columns = ["Bias (V)", "Current (A)", "Phase (deg)"]
    let firstGroup = axisRuntimeGroup(
        id: "first-runtime-group",
        sxmID: firstSXMID,
        columns: columns,
        preferredX: "Bias (V)",
        preferredY: "Current (A)"
    )
    let reopenedGroup = axisRuntimeGroup(
        id: "reopened-runtime-group",
        sxmID: reopenedSXMID,
        columns: [
            " bias (v) ",
            "current (a)",
            "phase (deg)",
        ],
        preferredX: " bias (v) ",
        preferredY: "current (a)"
    )
    let preference = try axisPreference(
        sxmPath: "image.sxm",
        group: firstGroup,
        x: "Phase (deg)",
        y: "Current (A)"
    )
    let firstIndex = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(firstSXMID, "image.sxm")]
    )
    let reopenedIndex = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(reopenedSXMID, "image.sxm")]
    )

    let first = SpectrumAxisPreferenceProjection(
        preferences: [preference],
        groups: [firstGroup],
        pathIndex: firstIndex
    )
    let reopened = SpectrumAxisPreferenceProjection(
        preferences: [preference],
        groups: [reopenedGroup],
        pathIndex: reopenedIndex
    )

    let expected = AxisSelection(
        xColumn: "Phase (deg)",
        yColumn: "Current (A)"
    )
    #expect(
        first.axisState.selection(forGroupID: firstGroup.id) == expected
    )
    #expect(
        reopened.axisState.selection(forGroupID: reopenedGroup.id)
            == AxisSelection(
                xColumn: "phase (deg)",
                yColumn: "current (a)"
            )
    )
    #expect(reopened.issues.isEmpty)
}

@Test
func stableAxisPreferencesRemainIndependentAcrossGroups() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Groups")
    let sxmID = UUID()
    let bias = axisRuntimeGroup(
        id: "bias-group",
        sxmID: sxmID,
        columns: ["Bias", "Current", "Phase"],
        preferredX: "Bias",
        preferredY: "Current"
    )
    let z = axisRuntimeGroup(
        id: "z-group",
        sxmID: sxmID,
        kind: .z,
        columns: ["Z", "Current", "Frequency"],
        preferredX: "Z",
        preferredY: "Current"
    )
    let preferences = [
        try axisPreference(
            sxmPath: "image.sxm",
            group: bias,
            x: "Bias",
            y: "Phase"
        ),
        try axisPreference(
            sxmPath: "image.sxm",
            group: z,
            x: "Frequency",
            y: "Current"
        ),
    ]
    let index = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(sxmID, "image.sxm")]
    )

    let projection = SpectrumAxisPreferenceProjection(
        preferences: preferences,
        groups: [z, bias],
        pathIndex: index
    )

    #expect(
        projection.axisState.selection(forGroupID: bias.id)
            == AxisSelection(xColumn: "Bias", yColumn: "Phase")
    )
    #expect(
        projection.axisState.selection(forGroupID: z.id)
            == AxisSelection(xColumn: "Frequency", yColumn: "Current")
    )
}

@Test
func axisPreferencesRemainIndependentAcrossExperimentGroups() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Experiments")
    let sxmID = UUID()
    let columns = ["Frequency", "Current", "Phase"]
    let frequency = axisRuntimeGroup(
        id: "frequency-group",
        sxmID: sxmID,
        kind: .other,
        experimentIdentity: "Frequency Sweep",
        columns: columns,
        preferredX: "Frequency",
        preferredY: "Current"
    )
    let lockIn = axisRuntimeGroup(
        id: "lock-in-group",
        sxmID: sxmID,
        kind: .other,
        experimentIdentity: "Lock-In Sweep",
        columns: columns,
        preferredX: "Frequency",
        preferredY: "Current"
    )
    let index = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(sxmID, "image.sxm")]
    )
    let projection = SpectrumAxisPreferenceProjection(
        preferences: [
            try axisPreference(
                sxmPath: "image.sxm",
                group: frequency,
                x: "Frequency",
                y: "Phase"
            ),
            try axisPreference(
                sxmPath: "image.sxm",
                group: lockIn,
                x: "Phase",
                y: "Current"
            ),
        ],
        groups: [lockIn, frequency],
        pathIndex: index
    )

    #expect(projection.issues.isEmpty)
    #expect(
        projection.axisState.selection(forGroupID: frequency.id)
            == AxisSelection(xColumn: "Frequency", yColumn: "Phase")
    )
    #expect(
        projection.axisState.selection(forGroupID: lockIn.id)
            == AxisSelection(xColumn: "Phase", yColumn: "Current")
    )
}

@Test
func uniqueLegacyAxisPreferenceUpgradesToExplicitExperimentKey() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Legacy-Unique")
    let sxmID = UUID()
    let group = axisRuntimeGroup(
        id: "frequency-group",
        sxmID: sxmID,
        kind: .other,
        experimentIdentity: " Frequency   Sweep ",
        columns: ["Frequency", "Current", "Phase"],
        preferredX: "Frequency",
        preferredY: "Current"
    )
    let legacy = try legacyAxisPreference(
        sxmPath: "image.sxm",
        group: group,
        x: "Frequency",
        y: "Phase"
    )
    let index = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(sxmID, "image.sxm")]
    )

    let projection = SpectrumAxisPreferenceProjection(
        preferences: [legacy],
        groups: [group],
        pathIndex: index
    )

    #expect(projection.issues.isEmpty)
    #expect(
        projection.axisState.selection(forGroupID: group.id)
            == AxisSelection(xColumn: "Frequency", yColumn: "Phase")
    )
    #expect(projection.retainedPreferences.count == 1)
    #expect(
        projection.retainedPreferences[0].key.experimentIdentity
            == "frequency sweep"
    )
}

@Test
func ambiguousLegacyAxisPreferenceIsRetainedButNotApplied() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Legacy-Ambiguous")
    let sxmID = UUID()
    let columns = ["Frequency", "Current", "Phase"]
    let first = axisRuntimeGroup(
        id: "frequency-group",
        sxmID: sxmID,
        kind: .other,
        experimentIdentity: "Frequency Sweep",
        columns: columns,
        preferredX: "Frequency",
        preferredY: "Current"
    )
    let second = axisRuntimeGroup(
        id: "lock-in-group",
        sxmID: sxmID,
        kind: .other,
        experimentIdentity: "Lock-In Sweep",
        columns: columns,
        preferredX: "Frequency",
        preferredY: "Current"
    )
    let legacy = try legacyAxisPreference(
        sxmPath: "image.sxm",
        group: first,
        x: "Phase",
        y: "Current"
    )
    let index = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(sxmID, "image.sxm")]
    )

    let projection = SpectrumAxisPreferenceProjection(
        preferences: [legacy],
        groups: [second, first],
        pathIndex: index
    )

    #expect(projection.retainedPreferences == [legacy])
    #expect(
        projection.issues.map(\.reason) == [
            .ambiguousExperiment(
                availableIdentities: [
                    "frequency sweep",
                    "lock-in sweep",
                ]
            ),
        ]
    )
    #expect(
        projection.axisState.selection(forGroupID: first.id)
            == AxisSelection(xColumn: "Frequency", yColumn: "Current")
    )
    #expect(
        projection.axisState.selection(forGroupID: second.id)
            == AxisSelection(xColumn: "Frequency", yColumn: "Current")
    )
}

@Test
func missingOrAmbiguousColumnsRejectTheWholeSavedPair() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Columns")
    let ambiguousSXMID = UUID()
    let missingSXMID = UUID()
    let ambiguous = axisRuntimeGroup(
        id: "ambiguous-group",
        sxmID: ambiguousSXMID,
        columns: ["Bias", " bias ", "Current"],
        preferredX: "Bias",
        preferredY: "Current"
    )
    let missing = axisRuntimeGroup(
        id: "missing-group",
        sxmID: missingSXMID,
        columns: ["Voltage", "Current"],
        preferredX: "Voltage",
        preferredY: "Current"
    )
    let ambiguousPreference = try axisPreference(
        sxmPath: "ambiguous.sxm",
        group: ambiguous,
        x: "BIAS",
        y: "Current"
    )
    let missingPreference = try axisPreference(
        sxmPath: "missing.sxm",
        group: missing,
        x: "Current",
        y: "Not Present"
    )
    let index = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [
            (ambiguousSXMID, "ambiguous.sxm"),
            (missingSXMID, "missing.sxm"),
        ]
    )

    let projection = SpectrumAxisPreferenceProjection(
        preferences: [missingPreference, ambiguousPreference],
        groups: [missing, ambiguous],
        pathIndex: index
    )

    #expect(
        projection.axisState.selection(forGroupID: ambiguous.id)
            == AxisSelection(xColumn: "Bias", yColumn: "Current")
    )
    #expect(
        projection.axisState.selection(forGroupID: missing.id)
            == AxisSelection(xColumn: "Voltage", yColumn: "Current")
    )
    #expect(
        projection.issues.contains {
            $0.reason == .ambiguousColumn(
                axis: .x,
                column: "BIAS",
                matches: ["Bias", " bias "]
            )
        }
    )
    #expect(
        projection.issues.contains {
            $0.reason == .missingColumn(
                axis: .y,
                column: "Not Present"
            )
        }
    )
}

@Test
func changingOneAxisPreservesTheOtherAndOfflinePreferences() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Update")
    let sxmID = UUID()
    let group = axisRuntimeGroup(
        id: "current-group",
        sxmID: sxmID,
        columns: ["Bias", "Current", "Phase"],
        preferredX: "Bias",
        preferredY: "Current"
    )
    let index = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(sxmID, "current.sxm")]
    )
    let offlineGroup = axisRuntimeGroup(
        id: "offline-group",
        sxmID: UUID(),
        columns: ["Z", "Current"],
        preferredX: "Z",
        preferredY: "Current"
    )
    let offline = try axisPreference(
        sxmPath: "offline/missing.sxm",
        group: offlineGroup,
        x: "Z",
        y: "Current"
    )
    let plan = try SpectrumAxisPreferenceUpdatePlan(
        group: group,
        changing: .x,
        to: "Phase",
        currentSelection: AxisSelection(
            xColumn: "Bias",
            yColumn: "Current"
        ),
        pathIndex: index
    )
    let yPlan = try SpectrumAxisPreferenceUpdatePlan(
        group: group,
        changing: .y,
        to: "Bias",
        currentSelection: plan.selection,
        pathIndex: index
    )
    let updated = try plan.applying(to: [offline])
    let offlineProjection = SpectrumAxisPreferenceProjection(
        preferences: updated,
        groups: [group],
        pathIndex: index
    )

    #expect(
        plan.selection
            == AxisSelection(xColumn: "Phase", yColumn: "Current")
    )
    #expect(
        yPlan.selection
            == AxisSelection(xColumn: "Phase", yColumn: "Bias")
    )
    #expect(updated.contains(offline))
    #expect(updated.count == 2)
    #expect(
        try plan.applying(to: updated) == updated
    )
    #expect(offlineProjection.retainedPreferences.contains(offline))
    #expect(
        offlineProjection.issues.contains {
            $0.key == offline.key && $0.reason == .missingSXMPath
        }
    )
}

@Test
func hiddenOrReassociatedGroupRestoresWhenItReturns() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Rebuild")
    let sxmID = UUID()
    let original = axisRuntimeGroup(
        id: "group-before-rebuild",
        sxmID: sxmID,
        columns: ["Bias", "Current", "Phase"],
        preferredX: "Bias",
        preferredY: "Current"
    )
    let rebuilt = axisRuntimeGroup(
        id: "group-after-rebuild",
        sxmID: sxmID,
        columns: original.availableColumns,
        preferredX: "Bias",
        preferredY: "Current"
    )
    let preference = try axisPreference(
        sxmPath: "image.sxm",
        group: original,
        x: "Bias",
        y: "Phase"
    )
    let index = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(sxmID, "image.sxm")]
    )

    let unavailable = SpectrumAxisPreferenceProjection(
        preferences: [preference],
        groups: [],
        pathIndex: index
    )
    let restored = SpectrumAxisPreferenceProjection(
        preferences: unavailable.retainedPreferences,
        groups: [rebuilt],
        pathIndex: index
    )

    #expect(
        unavailable.issues.map(\.reason) == [.groupUnavailable]
    )
    #expect(unavailable.retainedPreferences == [preference])
    #expect(
        restored.axisState.selection(forGroupID: rebuilt.id)
            == AxisSelection(xColumn: "Bias", yColumn: "Phase")
    )
}

@Test
func incompatibleSchemaIsReportedWithoutRemovingPreference() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Schema")
    let sxmID = UUID()
    let oldGroup = axisRuntimeGroup(
        id: "old-group",
        sxmID: sxmID,
        columns: ["Bias", "Current"],
        preferredX: "Bias",
        preferredY: "Current"
    )
    let currentGroup = axisRuntimeGroup(
        id: "new-group",
        sxmID: sxmID,
        columns: ["Bias", "Current", "Phase"],
        preferredX: "Bias",
        preferredY: "Current"
    )
    let preference = try axisPreference(
        sxmPath: "image.sxm",
        group: oldGroup,
        x: "Bias",
        y: "Current"
    )
    let index = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(sxmID, "image.sxm")]
    )

    let projection = SpectrumAxisPreferenceProjection(
        preferences: [preference],
        groups: [currentGroup],
        pathIndex: index
    )

    #expect(projection.retainedPreferences == [preference])
    #expect(
        projection.issues.map(\.reason) == [
            .incompatibleSchema(
                availableFingerprints: [
                    currentGroup.schemaFingerprint,
                ]
            ),
        ]
    )
    #expect(
        projection.axisState.selection(forGroupID: currentGroup.id)
            == AxisSelection(xColumn: "Bias", yColumn: "Current")
    )
}

@Test
func rejectedAxisUpdateCannotChangeThePublishedState() throws {
    let folder = URL(fileURLWithPath: "/tmp/Axis-Failure")
    let sxmID = UUID()
    let group = axisRuntimeGroup(
        id: "group",
        sxmID: sxmID,
        columns: ["Bias", "Current"],
        preferredX: "Bias",
        preferredY: "Current"
    )
    let index = try axisPreferenceIndex(
        folder: folder,
        sxmItems: [(sxmID, "image.sxm")]
    )
    let originalState = SpectrumAxisPreferenceProjection.safeDefaults(
        for: [group]
    )

    #expect(throws: SpectrumAxisPreferenceUpdatePlanError.self) {
        _ = try SpectrumAxisPreferenceUpdatePlan(
            group: group,
            changing: .y,
            to: "Missing",
            currentSelection: try #require(
                originalState.selection(forGroupID: group.id)
            ),
            pathIndex: index
        )
    }
    #expect(
        originalState.selection(forGroupID: group.id)
            == AxisSelection(xColumn: "Bias", yColumn: "Current")
    )
}
