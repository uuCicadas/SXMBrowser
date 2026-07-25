import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private struct SingleStateFixture {
    let first: SpectroscopyFile
    let second: SpectroscopyFile
    let third: SpectroscopyFile
    let firstGroup: SpectroscopyGroup
    let secondGroup: SpectroscopyGroup

    init() {
        let sxm = SXMMetadata(
            path: URL(fileURLWithPath: "/tmp/state.sxm"),
            filename: "state.sxm",
            header: [:],
            recordedTime: nil,
            modifiedTime: .distantPast,
            pixels: (width: 2, height: 2),
            scanRange: nil,
            scanOffset: nil,
            scanAngle: nil,
            scanDir: nil,
            zControllerOn: nil,
            channels: [],
            defaultChannel: nil
        )
        first = Self.makeSpectrum(
            id: UUID(
                uuidString:
                    "10000000-0000-0000-0000-000000000001"
            )!,
            filename: "01.dat",
            kind: .bias,
            experiment: "Bias"
        )
        second = Self.makeSpectrum(
            id: UUID(
                uuidString:
                    "10000000-0000-0000-0000-000000000002"
            )!,
            filename: "02.dat",
            kind: .bias,
            experiment: "Bias"
        )
        third = Self.makeSpectrum(
            id: UUID(
                uuidString:
                    "10000000-0000-0000-0000-000000000003"
            )!,
            filename: "03.dat",
            kind: .z,
            experiment: "Z"
        )
        let groups = SpectroscopyGroup.compatibleGroups(
            sxm: sxm,
            spectra: [second, third, first]
        )
        firstGroup = groups.first {
            $0.kind == .bias
        }!
        secondGroup = groups.first {
            $0.kind == .z
        }!
    }

    func presentations(
        hiddenIDs: Set<SpectroscopyFile.ID> = []
    ) -> [PresentedSpectroscopyGroup] {
        SpectroscopyPresentationProjection(
            groups: [firstGroup, secondGroup],
            hiddenSpectrumIDs: hiddenIDs
        ).groups
    }

    private static func makeSpectrum(
        id: UUID,
        filename: String,
        kind: SpectroscopyKind,
        experiment: String
    ) -> SpectroscopyFile {
        let columns = ["X", "Y"]
        return SpectroscopyFile(
            id: id,
            path: URL(fileURLWithPath: "/tmp/\(filename)"),
            filename: filename,
            kind: kind,
            experiment: experiment,
            modifiedTime: .distantPast,
            savedTime: nil,
            position: nil,
            xLabel: "X",
            yLabel: "Y",
            colorIndex: 0,
            curve: SpectroscopyCurve(
                filename: filename,
                modifiedTime: .distantPast,
                columns: columns,
                valuesByColumn: [
                    "X": [0, 1],
                    "Y": [2, 3],
                ],
                x: [0, 1],
                y: [2, 3]
            )
        )
    }
}

@Test
func drawerUsesPersistableDefaultsAndClampsHeight() {
    var state = SingleSpectroscopyState()

    #expect(state.isExpanded)
    #expect(state.height == 260)
    state.setHeight(100)
    #expect(state.height == 180)
    state.setHeight(900)
    #expect(state.height == 420)
    state.setHeight(.nan)
    state.setHeight(.infinity)
    state.setHeight(-.infinity)
    #expect(state.height == 420)
    #expect(SingleSpectroscopyState(height: .infinity).height == 260)
}

@Test
func activeGroupAndFocusFallBackDeterministically() {
    let fixture = SingleStateFixture()
    var state = SingleSpectroscopyState(
        activeGroupID: "missing",
        focusedSpectrumID: UUID()
    )

    state.reconcile(with: fixture.presentations())

    #expect(state.activeGroupID == fixture.firstGroup.id)
    #expect(state.focusedSpectrumID == fixture.first.id)
}

@Test
func equivalentGroupRefreshPreservesActiveGroupAndFocus() {
    let fixture = SingleStateFixture()
    var state = SingleSpectroscopyState()
    state.reconcile(with: fixture.presentations())
    state.activateGroup(fixture.secondGroup.id)
    state.reconcile(with: fixture.presentations())
    state.focusSpectrum(fixture.third.id)

    state.reconcile(with: fixture.presentations())

    #expect(state.activeGroupID == fixture.secondGroup.id)
    #expect(state.focusedSpectrumID == fixture.third.id)
}

@Test
func hidingFocusedCurveChoosesNextThenPrevious() {
    let fixture = SingleStateFixture()
    var state = SingleSpectroscopyState()
    state.reconcile(with: fixture.presentations())
    state.focusSpectrum(fixture.first.id)

    state.reconcile(
        with: fixture.presentations(hiddenIDs: [fixture.first.id])
    )
    #expect(state.focusedSpectrumID == fixture.second.id)

    state.focusSpectrum(fixture.second.id)
    state.reconcile(
        with: fixture.presentations(hiddenIDs: [fixture.second.id])
    )
    #expect(state.focusedSpectrumID == fixture.first.id)
}

@Test
func allCurvesHiddenClearsFocusButKeepsCanonicalGroup() {
    let fixture = SingleStateFixture()
    var state = SingleSpectroscopyState()
    state.reconcile(with: fixture.presentations())

    state.reconcile(
        with: fixture.presentations(
            hiddenIDs: [fixture.first.id, fixture.second.id]
        )
    )

    #expect(state.activeGroupID == fixture.firstGroup.id)
    #expect(state.focusedSpectrumID == nil)

    state.reconcile(
        with: fixture.presentations(hiddenIDs: [fixture.first.id])
    )
    #expect(state.activeGroupID == fixture.firstGroup.id)
    #expect(state.focusedSpectrumID == fixture.second.id)
}

@Test
func missingActiveGroupFallsBackAndEmptyInputClearsRuntimeIDs() {
    let fixture = SingleStateFixture()
    var state = SingleSpectroscopyState()
    state.reconcile(with: fixture.presentations())
    state.activateGroup(fixture.secondGroup.id)
    state.reconcile(with: fixture.presentations())

    state.reconcile(
        with: SpectroscopyPresentationProjection(
            groups: [fixture.firstGroup],
            hiddenSpectrumIDs: []
        ).groups
    )
    #expect(state.activeGroupID == fixture.firstGroup.id)
    #expect(state.focusedSpectrumID == fixture.first.id)

    state.reconcile(with: [])
    #expect(state.activeGroupID == nil)
    #expect(state.focusedSpectrumID == nil)
}

@Test
func expandedPreferenceDoesNotChangeHeightGroupOrFocus() {
    let fixture = SingleStateFixture()
    var state = SingleSpectroscopyState(
        isExpanded: false,
        height: 314
    )
    state.reconcile(with: fixture.presentations())
    #expect(!state.isExpanded)
    #expect(state.height == 314)
    state.activateGroup(fixture.secondGroup.id)
    state.reconcile(with: fixture.presentations())
    state.focusSpectrum(fixture.third.id)
    let groupID = state.activeGroupID
    let spectrumID = state.focusedSpectrumID

    state.setExpanded(true)

    #expect(state.isExpanded)
    #expect(state.height == 314)
    #expect(state.activeGroupID == groupID)
    #expect(state.focusedSpectrumID == spectrumID)
}
