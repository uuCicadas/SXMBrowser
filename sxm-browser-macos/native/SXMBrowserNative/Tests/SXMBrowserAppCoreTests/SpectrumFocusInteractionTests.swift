import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private func interactionSpectrum(
    id: UUID,
    filename: String,
    kind: SpectroscopyKind
) -> SpectroscopyFile {
    SpectroscopyFile(
        id: id,
        path: URL(fileURLWithPath: "/tmp/\(filename)"),
        filename: filename,
        kind: kind,
        experiment: kind.label,
        modifiedTime: .distantPast,
        savedTime: nil,
        position: nil,
        xLabel: "X",
        yLabel: "Y",
        colorIndex: 0,
        curve: SpectroscopyCurve(
            filename: filename,
            modifiedTime: .distantPast,
            columns: ["X", "Y"],
            valuesByColumn: [
                "X": [0, 1],
                "Y": [2, 3],
            ],
            x: [0, 1],
            y: [2, 3]
        )
    )
}

private func interactionPresentations(
    spectra: [SpectroscopyFile],
    hiddenIDs: Set<SpectroscopyFile.ID> = []
) -> [PresentedSpectroscopyGroup] {
    let sxm = SXMMetadata(
        path: URL(fileURLWithPath: "/tmp/sample.sxm"),
        filename: "sample.sxm",
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
    let groups = SpectroscopyGroup.compatibleGroups(
        sxm: sxm,
        spectra: spectra
    )
    return SpectroscopyPresentationProjection(
        groups: groups,
        hiddenSpectrumIDs: hiddenIDs
    ).groups
}

@Test
func plainSpectrumRowReplacesAssociationAndFocusesOnlyVisibleCurve() {
    let oldID = UUID()
    let clickedID = UUID()

    let visiblePlan = SpectrumRowInteractionPlan(
        existingAssociationIDs: [oldID],
        clickedID: clickedID,
        modifier: .plain,
        clickedIsVisible: true
    )
    #expect(visiblePlan.associationIDs == [clickedID])
    #expect(visiblePlan.shouldFocusClickedSpectrum)

    let hiddenPlan = SpectrumRowInteractionPlan(
        existingAssociationIDs: [oldID],
        clickedID: clickedID,
        modifier: .plain,
        clickedIsVisible: false
    )
    #expect(hiddenPlan.associationIDs == [clickedID])
    #expect(!hiddenPlan.shouldFocusClickedSpectrum)
}

@Test(
    arguments: [
        SpectrumRowModifier.command,
        SpectrumRowModifier.shift,
    ]
)
func additiveSpectrumRowModifiersToggleAssociationWithoutFocus(
    modifier: SpectrumRowModifier
) {
    let retainedID = UUID()
    let clickedID = UUID()

    let added = SpectrumRowInteractionPlan(
        existingAssociationIDs: [retainedID],
        clickedID: clickedID,
        modifier: modifier,
        clickedIsVisible: true
    )
    #expect(added.associationIDs == [retainedID, clickedID])
    #expect(!added.shouldFocusClickedSpectrum)

    let removed = SpectrumRowInteractionPlan(
        existingAssociationIDs: added.associationIDs,
        clickedID: clickedID,
        modifier: modifier,
        clickedIsVisible: true
    )
    #expect(removed.associationIDs == [retainedID])
    #expect(!removed.shouldFocusClickedSpectrum)
}

@Test
func focusPlanResolvesVisibleSpectrumToItsCanonicalGroup() {
    let first = interactionSpectrum(
        id: UUID(),
        filename: "first.dat",
        kind: .bias
    )
    let second = interactionSpectrum(
        id: UUID(),
        filename: "second.dat",
        kind: .z
    )
    let groups = interactionPresentations(
        spectra: [first, second]
    )
    let secondGroup = groups.first {
        $0.group.kind == .z
    }!

    let plan = SpectrumFocusPlan.resolve(
        spectrumID: second.id,
        groups: groups
    )

    #expect(plan?.groupID == secondGroup.id)
    #expect(plan?.spectrumID == second.id)
}

@Test
func focusPlanRejectsHiddenMissingAndStaleSpectra() {
    let visible = interactionSpectrum(
        id: UUID(),
        filename: "visible.dat",
        kind: .bias
    )
    let hidden = interactionSpectrum(
        id: UUID(),
        filename: "hidden.dat",
        kind: .bias
    )
    let groups = interactionPresentations(
        spectra: [visible, hidden],
        hiddenIDs: [hidden.id]
    )

    #expect(
        SpectrumFocusPlan.resolve(
            spectrumID: hidden.id,
            groups: groups
        ) == nil
    )
    #expect(
        SpectrumFocusPlan.resolve(
            spectrumID: UUID(),
            groups: groups
        ) == nil
    )
    #expect(
        SpectrumFocusPlan.resolve(
            spectrumID: visible.id,
            groups: []
        ) == nil
    )
}
