import AppKit
import Foundation
import SXMBrowserAppCore
import SXMBrowserCore

public enum BrowserMode: String, CaseIterable, Identifiable, Sendable {
    case grid
    case single

    public var id: String { rawValue }
    public var label: String { self == .grid ? "Grid" : "Single" }
}

public enum SortMode: String, CaseIterable, Identifiable, Sendable {
    case name
    case modifiedTime
    case recordedTime

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .name: "File name"
        case .modifiedTime: "Modified time"
        case .recordedTime: "Recorded time"
        }
    }

    public var sortCriterion: FileSortCriterion {
        switch self {
        case .name: .name
        case .modifiedTime: .modifiedTime
        case .recordedTime: .recordedTime
        }
    }
}

public enum SidebarMode: String, CaseIterable, Identifiable, Sendable {
    case all
    case tag

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: "All"
        case .tag: "Tag"
        }
    }
}

public enum GridDisplayItem: Identifiable {
    case sxm(SXMMetadata)
    case spectroscopy(PresentedSpectroscopyGroup)

    public var id: String {
        switch self {
        case .sxm(let file): "sxm-\(file.id.uuidString)"
        case .spectroscopy(let presentation):
            "spectroscopy-\(presentation.id)"
        }
    }
}

public enum ScalePreset: String, CaseIterable, Identifiable, Sendable {
    case full
    case percentile
    case sigma
    case manual

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .full: "Full"
        case .percentile: "1-99%"
        case .sigma: "2.5σ"
        case .manual: "Manual"
        }
    }
}

public enum MetadataImportWorkflowPhase: Equatable {
    case loading
    case preview
    case applying
    case failed(String)
    case completed(String)
}

public struct MetadataImportWorkflow: Identifiable, Equatable {
    public let id: UUID
    public let sourceURL: URL
    public let sessionIdentity: DatasetSessionIdentity
    public var inventory: DatasetMetadataImportInventory?
    public var fileSignature: DatasetInventorySignature?
    public var plan: DatasetMetadataImportPlan?
    public var phase: MetadataImportWorkflowPhase

    public init(
        id: UUID,
        sourceURL: URL,
        sessionIdentity: DatasetSessionIdentity,
        inventory: DatasetMetadataImportInventory? = nil,
        fileSignature: DatasetInventorySignature? = nil,
        plan: DatasetMetadataImportPlan? = nil,
        phase: MetadataImportWorkflowPhase
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sessionIdentity = sessionIdentity
        self.inventory = inventory
        self.fileSignature = fileSignature
        self.plan = plan
        self.phase = phase
    }

    public var sourceFilename: String {
        sourceURL.lastPathComponent
    }
}

internal enum MetadataTransferWorkflowError: LocalizedError {
    case inventoryUnavailable
    case sxmPathUnavailable(String)
    case datPathUnavailable(String)
    case automaticParentPathUnavailable(String)
    case inventoryFileAttributesUnavailable(String)
    case inventoryFileIsNotRegular(String)
    case inventoryChanged
    case sessionChanged

    var errorDescription: String? {
        switch self {
        case .inventoryUnavailable:
            "The current dataset inventory is unavailable. Reopen the folder and try again."
        case .sxmPathUnavailable(let filename):
            "The SXM file “\(filename)” has no stable dataset-relative path."
        case .datPathUnavailable(let filename):
            "The DAT file “\(filename)” has no stable dataset-relative path."
        case .automaticParentPathUnavailable(let filename):
            "The automatic SXM parent for “\(filename)” has no stable dataset-relative path."
        case .inventoryFileAttributesUnavailable(let filename):
            "Could not read size or modification time for “\(filename)”."
        case .inventoryFileIsNotRegular(let filename):
            "The dataset entry “\(filename)” is not a regular file."
        case .inventoryChanged:
            "Dataset files changed after the preview. Start the import again."
        case .sessionChanged:
            "The open dataset changed. Start the metadata operation again."
        }
    }
}

internal enum MissingActiveTagResolution {
    case firstAvailable
    case preferred(UUID?)
}

internal enum BrowserDefaults {
    static let sortMode = "native.sortMode"
    static let sortAscending = "native.sortAscending"
    static let sidebarWidth = "native.sidebarWidth"
    static let inspectorWidth = "native.inspectorWidth"
    static let sidebarVisible = "native.sidebarVisible"
    static let inspectorVisible = "native.inspectorVisible"
    static let stmPreviewPalette = "native.stmPreviewPalette"
    static let lastFolder = "native.lastFolder"
    static let histogramBins = "native.histogramBins"
    static let gridDensity = "native.gridDensity"
    static let gridColumns = "native.gridColumns"
    static let showsGridSpectroscopyCards =
        "native.showsGridSpectroscopyCards"
    static let singleSpectroscopyDrawerExpanded =
        "native.singleSpectroscopyDrawerExpanded"
    static let singleSpectroscopyDrawerHeight =
        "native.singleSpectroscopyDrawerHeight"
    static let expandedTagIDsByDataset =
        "native.expandedTagIDsByDataset"

    static func loadSortMode() -> SortMode {
        if let raw = UserDefaults.standard.string(forKey: sortMode),
           let mode = SortMode(rawValue: raw) {
            return mode
        }
        return .name
    }

    static func loadGridDensity() -> GridDensity {
        if let rawValue = UserDefaults.standard.string(forKey: gridDensity),
           let density = GridDensity(rawValue: rawValue) {
            return density
        }

        guard UserDefaults.standard.object(forKey: gridColumns) != nil else {
            return .comfortable
        }
        let density = GridDensity.migrating(
            legacyColumnCount: UserDefaults.standard.integer(forKey: gridColumns)
        )
        UserDefaults.standard.set(density.rawValue, forKey: gridDensity)
        return density
    }

    static func loadCGFloat(
        _ key: String,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return fallback
        }
        let value = CGFloat(UserDefaults.standard.double(forKey: key))
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    static func loadBool(_ key: String, fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return fallback
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func loadPalette(
        _ key: String,
        fallback: PaletteName
    ) -> PaletteName {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let palette = PaletteName(rawValue: raw) else {
            return fallback
        }
        return palette
    }

    static func loadInt(
        _ key: String,
        fallback: Int,
        range: ClosedRange<Int>
    ) -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return fallback
        }
        let value = UserDefaults.standard.integer(forKey: key)
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
