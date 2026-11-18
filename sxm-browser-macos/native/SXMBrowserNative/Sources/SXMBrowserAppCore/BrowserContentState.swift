public enum DatasetLoadState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case failed(message: String)

    public var isLoading: Bool {
        self == .loading
    }
}

public enum SelectedRenderState<ID: Hashable & Sendable>:
    Sendable,
    Equatable {
    case idle
    case loading(fileID: ID)
    case ready(fileID: ID)
    case failed(fileID: ID, message: String)
}

public enum BrowserContentState<ID: Hashable & Sendable>:
    Sendable,
    Equatable {
    case openFolder
    case loadingFolder
    case folderFailed(message: String)
    case emptyFolder
    case noSearchResults
    case noVisibleFiles
    case gridReady
    case noSelection
    case renderLoading(fileID: ID)
    case renderReady(fileID: ID)
    case renderFailed(fileID: ID, message: String)
}

public enum BrowserContentProjection {
    public static func resolve<ID: Hashable & Sendable>(
        datasetState: DatasetLoadState,
        totalFileCount: Int,
        visibleFileCount: Int,
        searchIsActive: Bool,
        isSingleMode: Bool,
        selectedFileID: ID?,
        renderState: SelectedRenderState<ID>
    ) -> BrowserContentState<ID> {
        switch datasetState {
        case .idle:
            return .openFolder
        case .loading:
            return .loadingFolder
        case .failed(let message):
            return .folderFailed(message: message)
        case .ready:
            break
        }

        guard totalFileCount > 0 else {
            return .emptyFolder
        }
        guard visibleFileCount > 0 else {
            return searchIsActive
                ? .noSearchResults
                : .noVisibleFiles
        }
        guard isSingleMode else {
            return .gridReady
        }
        guard let selectedFileID else {
            return .noSelection
        }

        switch renderState {
        case .ready(let fileID) where fileID == selectedFileID:
            return .renderReady(fileID: selectedFileID)
        case .failed(let fileID, let message)
            where fileID == selectedFileID:
            return .renderFailed(
                fileID: selectedFileID,
                message: message
            )
        case .idle, .loading, .ready, .failed:
            return .renderLoading(fileID: selectedFileID)
        }
    }
}
