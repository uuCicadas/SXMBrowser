import Foundation
import Observation
import Testing
@testable import SXMBrowserNativeUI

@MainActor
@Test
func derivedListsMemoizeAcrossRepeatedReadsAndUnrelatedMutations() {
    let model = AppModel()
    let f1 = makeTestSXM(filename: "b_scan.sxm", modifiedOffset: 10)
    let f2 = makeTestSXM(filename: "a_scan.sxm", modifiedOffset: 20)
    let f3 = makeTestSXM(filename: "c_bias.sxm", modifiedOffset: 30)
    model.dataset.files = [f1, f2, f3]

    let sorted1 = model.dataset.sortedFiles
    let sorted2 = model.dataset.sortedFiles
    #expect(sorted1.map(\.id) == sorted2.map(\.id))
    #expect(model.dataset.sortedFilesComputeCount == 1)

    let visible1 = model.dataset.visibleFiles
    let visible2 = model.dataset.visibleFiles
    #expect(visible1.map(\.id) == visible2.map(\.id))
    #expect(model.dataset.visibleFilesComputeCount == 1)

    // Unrelated viewer and status mutations must not recompute sorted/visible lists.
    model.viewer.scaleMin = -1.25
    model.viewer.scaleMax = 2.5
    model.dataset.status = "Rendered preview."
    _ = model.dataset.sortedFiles
    _ = model.dataset.visibleFiles
    #expect(model.dataset.sortedFilesComputeCount == 1)
    #expect(model.dataset.visibleFilesComputeCount == 1)

    // Changing search filters visibleFiles without re-sorting.
    model.dataset.appliedFilenameSearch = "scan"
    let filtered = model.dataset.visibleFiles
    #expect(filtered.map(\.filename).contains("b_scan.sxm"))
    #expect(filtered.map(\.filename).contains("a_scan.sxm"))
    #expect(!filtered.map(\.filename).contains("c_bias.sxm"))
    #expect(model.dataset.sortedFilesComputeCount == 1)
    #expect(model.dataset.visibleFilesComputeCount == 2)

    // Toggling sort order invalidates both sortedFiles and visibleFiles cleanly.
    let previousSortAscending = model.dataset.sortAscending
    defer {
        model.dataset.sortAscending = previousSortAscending
    }
    model.dataset.sortAscending = !previousSortAscending
    _ = model.dataset.sortedFiles
    _ = model.dataset.visibleFiles
    #expect(model.dataset.sortedFilesComputeCount == 2)
    #expect(model.dataset.visibleFilesComputeCount == 3)
}

@MainActor
@Test
func observableControllersIsolateCrossDomainUpdates() {
    let model = AppModel()
    model.dataset.files = [makeTestSXM(filename: "sample_001.sxm")]

    // 1. Mutating viewer.scaleMin must not invalidate dataset status, visibleFiles, or spectroscopy.
    let statusChangedOnScale = LockedFlag()
    let visibleChangedOnScale = LockedFlag()
    let spectroscopyChangedOnScale = LockedFlag()
    let scaleChanged = LockedFlag()

    withObservationTracking {
        _ = model.dataset.status
    } onChange: {
        statusChangedOnScale.trigger()
    }
    withObservationTracking {
        _ = model.dataset.visibleFiles
    } onChange: {
        visibleChangedOnScale.trigger()
    }
    withObservationTracking {
        _ = model.spectroscopy.singleSpectroscopyState
    } onChange: {
        spectroscopyChangedOnScale.trigger()
    }
    withObservationTracking {
        _ = model.viewer.scaleMin
    } onChange: {
        scaleChanged.trigger()
    }

    model.viewer.scaleMin = -0.42
    #expect(scaleChanged.isTriggered)
    #expect(!statusChangedOnScale.isTriggered)
    #expect(!visibleChangedOnScale.isTriggered)
    #expect(!spectroscopyChangedOnScale.isTriggered)

    // 2. Mutating dataset.status must only fire status observer, not visibleFiles or viewer frame.
    let statusChanged = LockedFlag()
    let visibleChangedOnStatus = LockedFlag()
    let frameChangedOnStatus = LockedFlag()

    withObservationTracking {
        _ = model.dataset.status
    } onChange: {
        statusChanged.trigger()
    }
    withObservationTracking {
        _ = model.dataset.visibleFiles
    } onChange: {
        visibleChangedOnStatus.trigger()
    }
    withObservationTracking {
        _ = model.viewer.renderedFrame
    } onChange: {
        frameChangedOnStatus.trigger()
    }

    model.dataset.status = "Loaded folder."
    #expect(statusChanged.isTriggered)
    #expect(!visibleChangedOnStatus.isTriggered)
    #expect(!frameChangedOnStatus.isTriggered)

    // 3. Mutating spectroscopy.singleSpectroscopyState must not invalidate viewer.scaleMax or sortedFiles.
    let spectroscopyChanged = LockedFlag()
    let scaleMaxChangedOnSpec = LockedFlag()
    let sortedChangedOnSpec = LockedFlag()

    withObservationTracking {
        _ = model.spectroscopy.singleSpectroscopyState
    } onChange: {
        spectroscopyChanged.trigger()
    }
    withObservationTracking {
        _ = model.viewer.scaleMax
    } onChange: {
        scaleMaxChangedOnSpec.trigger()
    }
    withObservationTracking {
        _ = model.dataset.sortedFiles
    } onChange: {
        sortedChangedOnSpec.trigger()
    }

    model.spectroscopy.singleSpectroscopyState.activateGroup("g1")
    #expect(spectroscopyChanged.isTriggered)
    #expect(!scaleMaxChangedOnSpec.isTriggered)
    #expect(!sortedChangedOnSpec.isTriggered)
}
