import Foundation
import SXMBrowserAppCore
import SXMBrowserCore
import Testing
@testable import SXMBrowserNativeUI

private func makeUITestSpectrum(
    id: UUID,
    filename: String,
    colorIndex: Int
) -> SpectroscopyFile {
    let curve = SpectroscopyCurve(
        filename: filename,
        modifiedTime: .distantPast,
        columns: ["Bias", "Current"],
        valuesByColumn: [
            "Bias": [-1, 1],
            "Current": [-2, 2],
        ],
        x: [-1, 1],
        y: [-2, 2]
    )
    return SpectroscopyFile(
        id: id,
        path: URL(fileURLWithPath: "/tmp/sxm-test/\(filename)"),
        filename: filename,
        kind: .bias,
        experiment: "Bias",
        modifiedTime: .distantPast,
        savedTime: nil,
        position: nil,
        xLabel: "Bias",
        yLabel: "Current",
        colorIndex: colorIndex,
        curve: curve
    )
}

@MainActor
@Test
func spectroscopyLegendEquatableDetectsVisibleIDReplacementAndFocusChanges() {
    let model = AppModel()
    let sxm = makeTestSXM(filename: "01.sxm")
    let s1 = makeUITestSpectrum(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        filename: "01.dat",
        colorIndex: 0
    )
    let s2 = makeUITestSpectrum(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
        filename: "02.dat",
        colorIndex: 1
    )
    let group = SpectroscopyGroup.compatibleGroups(sxm: sxm, spectra: [s1, s2])[0]

    let onlyFirstVisible = SpectroscopyPresentationProjection(
        groups: [group],
        hiddenSpectrumIDs: [s2.id]
    ).groups[0]
    let onlySecondVisible = SpectroscopyPresentationProjection(
        groups: [group],
        hiddenSpectrumIDs: [s1.id]
    ).groups[0]

    let legendFirst = SpectroscopyLegend(model: model, presentation: onlyFirstVisible)
    let legendFirstCopy = SpectroscopyLegend(model: model, presentation: onlyFirstVisible)
    let legendSecond = SpectroscopyLegend(model: model, presentation: onlySecondVisible)

    #expect(legendFirst == legendFirstCopy)
    // Same visible/total count (1/2) but different visible IDs must trigger SwiftUI diffing.
    #expect(legendFirst != legendSecond)

    model.dataset.files = [sxm]
    model.spectroscopy.spectrumGroupsByFileID[sxm.id] = [group]
    model.spectroscopy.spectrumParentIDBySpectrumID[s1.id] = sxm.id
    model.spectroscopy.spectrumParentIDBySpectrumID[s2.id] = sxm.id
    model.select(sxm)
    model.focusSingleSpectrum(s1)
    let legendFocused = SpectroscopyLegend(model: model, presentation: onlyFirstVisible)
    #expect(legendFirst != legendFocused)
}

@MainActor
@Test
func mixedGridArrowNavigationAlignsVisualColumnsAndExtendsRange() {
    let model = AppModel()
    let prevSortMode = model.dataset.sortMode
    let prevSortAscending = model.dataset.sortAscending
    let prevShowCards = model.spectroscopy.showsGridSpectroscopyCards
    defer {
        model.dataset.sortMode = prevSortMode
        model.dataset.sortAscending = prevSortAscending
        model.spectroscopy.showsGridSpectroscopyCards = prevShowCards
    }

    model.dataset.sortMode = .name
    model.dataset.sortAscending = true
    model.spectroscopy.showsGridSpectroscopyCards = true
    model.setMode(.grid)
    model.setGridNavigationColumnCount(3)

    let f1 = makeTestSXM(filename: "01.sxm")
    let f2 = makeTestSXM(filename: "02.sxm")
    let f3 = makeTestSXM(filename: "03.sxm")
    let f4 = makeTestSXM(filename: "04.sxm")
    let f5 = makeTestSXM(filename: "05.sxm")
    let spectrum = makeUITestSpectrum(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
        filename: "01.dat",
        colorIndex: 0
    )
    let group = SpectroscopyGroup.compatibleGroups(sxm: f1, spectra: [spectrum])[0]

    // 3 columns with mixed spectroscopy card after f1:
    // Row 0: [f1, spec, f2]
    // Row 1: [f3, f4,   f5]
    model.spectroscopy.spectrumGroupsByFileID[f1.id] = [group]
    model.dataset.files = [f1, f2, f3, f4, f5]
    model.select(f1)

    #expect(model.visibleDisplayItems.count == 6)

    model.moveSelectionForArrow(.right)
    #expect(model.selectedID == f2.id)

    model.moveSelectionForArrow(.down)
    #expect(model.selectedID == f5.id)

    model.moveSelectionForArrow(.up)
    #expect(model.selectedID == f2.id)

    model.moveSelectionForArrow(.left)
    #expect(model.selectedID == f1.id)

    model.moveSelectionForArrow(.down, extendingSelection: true)
    #expect(model.selectedID == f3.id)
    #expect(model.selectedIDs == Set([f1.id, f2.id, f3.id]))
}
