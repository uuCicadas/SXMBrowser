import Foundation

public enum NoticeSeverity: String, Equatable, Sendable {
    case information
    case success
    case warning
    case error
}

public enum NoticeAction: String, Equatable, Hashable, Sendable {
    case retryFolder
    case retryRender
    case showInFinder
    case showScanIssues
    case showMetadataDetails
}

public struct UserNotice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String
    public let severity: NoticeSeverity
    public let actions: [NoticeAction]

    public init(
        id: UUID = UUID(),
        title: String,
        message: String,
        severity: NoticeSeverity,
        actions: [NoticeAction] = []
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.severity = severity
        self.actions = actions
    }
}

public struct NoticePresentationState: Equatable, Sendable {
    public private(set) var banner: UserNotice?
    public private(set) var toast: UserNotice?

    public init(
        banner: UserNotice? = nil,
        toast: UserNotice? = nil
    ) {
        self.banner = banner
        self.toast = toast
    }

    public mutating func presentBanner(_ notice: UserNotice) {
        banner = notice
    }

    public mutating func presentToast(_ notice: UserNotice) {
        toast = notice
    }

    @discardableResult
    public mutating func dismissBanner(id: UUID) -> Bool {
        guard banner?.id == id else { return false }
        banner = nil
        return true
    }

    @discardableResult
    public mutating func dismissToast(id: UUID) -> Bool {
        guard toast?.id == id else { return false }
        toast = nil
        return true
    }

    public mutating func clearBanner() {
        banner = nil
    }

    public mutating func clearToast() {
        toast = nil
    }

    public mutating func clear() {
        banner = nil
        toast = nil
    }
}
