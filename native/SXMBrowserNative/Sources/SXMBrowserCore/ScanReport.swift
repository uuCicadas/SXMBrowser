import Foundation

public enum ScanStage: String, Codable, Sendable {
    case sxmMetadata = "sxm-metadata"
    case spectroscopyFile = "spectroscopy-file"
    case spectroscopyRows = "spectroscopy-rows"
}

public struct ScanIssue: Identifiable, Codable, Hashable, Sendable {
    public let file: URL
    public let stage: ScanStage
    public let reason: String
    public let badLineCount: Int?

    public init(
        file: URL,
        stage: ScanStage,
        reason: String,
        badLineCount: Int? = nil
    ) {
        self.file = file
        self.stage = stage
        self.reason = reason
        self.badLineCount = badLineCount
    }

    public var id: String {
        [
            file.standardizedFileURL.path,
            stage.rawValue,
            reason,
            badLineCount.map(String.init) ?? "",
        ].joined(separator: "\u{1f}")
    }
}

public struct ScanReport<Item: Sendable>: Sendable {
    public let items: [Item]
    public let issues: [ScanIssue]

    public init(items: [Item], issues: [ScanIssue] = []) {
        self.items = items
        self.issues = issues
    }
}

extension ScanReport: Equatable where Item: Equatable {}
extension ScanReport: Codable where Item: Codable {}
