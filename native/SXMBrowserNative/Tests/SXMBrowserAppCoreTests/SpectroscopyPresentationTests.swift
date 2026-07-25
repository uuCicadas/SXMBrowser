import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private func presentationTestSXM() -> SXMMetadata {
    SXMMetadata(
        path: URL(fileURLWithPath: "/tmp/presentation.sxm"),
        filename: "presentation.sxm",
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
}

private func presentationTestSpectrum(
    id: UUID,
    filename: String,
    colorIndex: Int,
    kind: SpectroscopyKind = .bias,
    experiment: String = "Bias",
    columns: [String] = ["Bias", "Current"]
) -> SpectroscopyFile {
    let curve = SpectroscopyCurve(
        filename: filename,
        modifiedTime: .distantPast,
        columns: columns,
        valuesByColumn: [
            columns[0]: [0, 1],
            columns[1]: [2, 3],
        ],
        x: [0, 1],
        y: [2, 3]
    )
    return SpectroscopyFile(
        id: id,
        path: URL(fileURLWithPath: "/tmp/\(filename)"),
        filename: filename,
        kind: kind,
        experiment: experiment,
        modifiedTime: .distantPast,
        savedTime: nil,
        position: nil,
        xLabel: columns[0],
        yLabel: columns[1],
        colorIndex: colorIndex,
        curve: curve
    )
}

private func presentationTestGroup()
    -> (
        group: SpectroscopyGroup,
        first: SpectroscopyFile,
        second: SpectroscopyFile
    )
{
    let first = presentationTestSpectrum(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        filename: "01.dat",
        colorIndex: 0
    )
    let second = presentationTestSpectrum(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        filename: "02.dat",
        colorIndex: 1
    )
    let group = SpectroscopyGroup.compatibleGroups(
        sxm: presentationTestSXM(),
        spectra: [second, first]
    )[0]
    return (group, first, second)
}

@Test
func hiddenSpectrumRemainsInLegendButNotPlotOrMarkers() {
    let fixture = presentationTestGroup()
    let projection = SpectroscopyPresentationProjection(
        groups: [fixture.group],
        hiddenSpectrumIDs: [fixture.first.id]
    )
    let presented = projection.groups[0]

    #expect(presented.allSpectra.map(\.id) == [
        fixture.first.id,
        fixture.second.id,
    ])
    #expect(presented.visibleSpectra.map(\.id) == [fixture.second.id])
    #expect(presented.visibleCurveCountText == "1 curve")
    #expect(projection.markerSpectra.map(\.id) == [fixture.second.id])
}

@Test
func allHiddenGroupIsOmittedFromGridButRetainedForDrawer() {
    let fixture = presentationTestGroup()
    let projection = SpectroscopyPresentationProjection(
        groups: [fixture.group],
        hiddenSpectrumIDs: [fixture.first.id, fixture.second.id]
    )

    #expect(projection.groups.count == 1)
    #expect(projection.groups[0].allSpectra.count == 2)
    #expect(projection.groups[0].visibleSpectra.isEmpty)
    #expect(projection.groups[0].visibleCurveCountText == "0 curves")
    #expect(projection.gridGroups.isEmpty)
}

@Test
func showingHiddenSpectrumRestoresTheSameCanonicalGroupAndStyleSeed() {
    let fixture = presentationTestGroup()
    let hidden = SpectroscopyPresentationProjection(
        groups: [fixture.group],
        hiddenSpectrumIDs: [fixture.first.id]
    )
    let restored = SpectroscopyPresentationProjection(
        groups: [fixture.group],
        hiddenSpectrumIDs: []
    )

    #expect(hidden.groups[0].id == restored.groups[0].id)
    #expect(restored.groups[0].visibleSpectra[0].id == fixture.first.id)
    #expect(
        restored.groups[0].visibleSpectra[0].colorIndex
            == fixture.first.colorIndex
    )
}

@Test
func unknownHiddenIDDoesNotChangeProjectionOrder() {
    let fixture = presentationTestGroup()
    let projection = SpectroscopyPresentationProjection(
        groups: [fixture.group],
        hiddenSpectrumIDs: [UUID()]
    )

    #expect(projection.groups.map(\.id) == [fixture.group.id])
    #expect(
        projection.groups[0].visibleSpectra.map(\.filename)
            == ["01.dat", "02.dat"]
    )
}

@Test
func singleDrawerDistinguishesEmptyHiddenAndReadyContent() {
    let fixture = presentationTestGroup()
    let empty = SingleSpectroscopyDrawerPresentation(
        groups: [],
        activeGroupID: nil
    )
    #expect(empty.availability == .noAssociatedSpectra)
    #expect(empty.activeGroup == nil)
    #expect(empty.visibleCountText == "0 of 0 visible")

    let allHiddenProjection = SpectroscopyPresentationProjection(
        groups: [fixture.group],
        hiddenSpectrumIDs: [fixture.first.id, fixture.second.id]
    )
    let allHidden = SingleSpectroscopyDrawerPresentation(
        groups: allHiddenProjection.groups,
        activeGroupID: fixture.group.id
    )
    #expect(
        allHidden.availability
            == .activeGroupHasNoVisibleCurves
    )
    #expect(allHidden.activeGroup?.id == fixture.group.id)
    #expect(allHidden.visibleCountText == "0 of 2 visible")

    let readyProjection = SpectroscopyPresentationProjection(
        groups: [fixture.group],
        hiddenSpectrumIDs: [fixture.first.id]
    )
    let ready = SingleSpectroscopyDrawerPresentation(
        groups: readyProjection.groups,
        activeGroupID: "missing"
    )
    #expect(ready.availability == .ready)
    #expect(ready.activeGroup?.id == fixture.group.id)
    #expect(ready.visibleCountText == "1 of 2 visible")
}

@Test
func hiddenActiveGroupDoesNotClaimOtherGroupsAreHidden() {
    let fixture = presentationTestGroup()
    let otherSpectrum = presentationTestSpectrum(
        id: UUID(
            uuidString:
                "00000000-0000-0000-0000-000000000003"
        )!,
        filename: "03.dat",
        colorIndex: 2,
        columns: ["Voltage", "Conductance"]
    )
    let canonicalGroups = SpectroscopyGroup.compatibleGroups(
        sxm: presentationTestSXM(),
        spectra: [
            fixture.first,
            fixture.second,
            otherSpectrum,
        ]
    )
    let projection = SpectroscopyPresentationProjection(
        groups: canonicalGroups,
        hiddenSpectrumIDs: [
            fixture.first.id,
            fixture.second.id,
        ]
    )
    let hiddenGroup = projection.groups.first {
        $0.allSpectra.contains(where: {
            $0.id == fixture.first.id
        })
    }!
    let visibleGroup = projection.groups.first {
        $0.allSpectra.contains(where: {
            $0.id == otherSpectrum.id
        })
    }!
    let drawer = SingleSpectroscopyDrawerPresentation(
        groups: projection.groups,
        activeGroupID: hiddenGroup.id
    )

    #expect(
        drawer.availability
            == .activeGroupHasNoVisibleCurves
    )
    #expect(visibleGroup.visibleSpectra.count == 1)
    #expect(hiddenGroup.columnSummary != visibleGroup.columnSummary)
}
