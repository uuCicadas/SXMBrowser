import Testing
@testable import SXMBrowserAppCore

private func browserState(
    dataset: DatasetLoadState = .ready,
    total: Int = 1,
    visible: Int = 1,
    searching: Bool = false,
    single: Bool = false,
    selected: String? = "file",
    render: SelectedRenderState<String> = .idle
) -> BrowserContentState<String> {
    BrowserContentProjection.resolve(
        datasetState: dataset,
        totalFileCount: total,
        visibleFileCount: visible,
        searchIsActive: searching,
        isSingleMode: single,
        selectedFileID: selected,
        renderState: render
    )
}

@Test
func datasetLifecycleHasPriorityOverDerivedEmptyStates() {
    #expect(
        browserState(
            dataset: .idle,
            total: 0,
            visible: 0
        ) == .openFolder
    )
    #expect(
        browserState(
            dataset: .loading,
            total: 0,
            visible: 0
        ) == .loadingFolder
    )
    #expect(
        browserState(
            dataset: .failed(message: "Permission denied"),
            total: 0,
            visible: 0
        ) == .folderFailed(message: "Permission denied")
    )
    #expect(
        browserState(total: 0, visible: 0) == .emptyFolder
    )
}

@Test
func visibleScopeDistinguishesSearchFromAnEmptyTagOrView() {
    #expect(
        browserState(
            total: 4,
            visible: 0,
            searching: true
        ) == .noSearchResults
    )
    #expect(
        browserState(
            total: 4,
            visible: 0,
            searching: false
        ) == .noVisibleFiles
    )
    #expect(
        browserState(
            total: 4,
            visible: 2,
            single: false
        ) == .gridReady
    )
}

@Test
func singleModeRequiresASelectionAndMatchingRenderIdentity() {
    #expect(
        browserState(
            single: true,
            selected: nil
        ) == .noSelection
    )
    #expect(
        browserState(
            single: true,
            render: .loading(fileID: "file")
        ) == .renderLoading(fileID: "file")
    )
    #expect(
        browserState(
            single: true,
            render: .ready(fileID: "file")
        ) == .renderReady(fileID: "file")
    )
    #expect(
        browserState(
            single: true,
            render: .failed(
                fileID: "file",
                message: "Corrupt payload"
            )
        ) == .renderFailed(
            fileID: "file",
            message: "Corrupt payload"
        )
    )
    #expect(
        browserState(
            single: true,
            render: .failed(
                fileID: "old-file",
                message: "Stale failure"
            )
        ) == .renderLoading(fileID: "file")
    )
}
