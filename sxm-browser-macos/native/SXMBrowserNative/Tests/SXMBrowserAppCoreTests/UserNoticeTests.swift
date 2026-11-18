import Foundation
import Testing
@testable import SXMBrowserAppCore

@Test
func noticePresentationReplacesEachSurfaceIndependently() {
    var presentation = NoticePresentationState()
    let banner = UserNotice(
        title: "Could not open folder",
        message: "Permission denied",
        severity: .error,
        actions: [.retryFolder]
    )
    let toast = UserNotice(
        title: "Export complete",
        message: "image.png",
        severity: .success
    )

    presentation.presentBanner(banner)
    presentation.presentToast(toast)

    #expect(presentation.banner == banner)
    #expect(presentation.toast == toast)
}

@Test
func staleDismissalCannotClearAReplacementBanner() {
    var presentation = NoticePresentationState()
    let first = UserNotice(
        title: "First",
        message: "First failure",
        severity: .error
    )
    let replacement = UserNotice(
        title: "Replacement",
        message: "New failure",
        severity: .warning
    )

    presentation.presentBanner(first)
    presentation.presentBanner(replacement)

    let dismissedStaleBanner = presentation.dismissBanner(id: first.id)
    #expect(!dismissedStaleBanner)
    #expect(presentation.banner == replacement)
    let dismissedCurrentBanner = presentation.dismissBanner(
        id: replacement.id
    )
    #expect(dismissedCurrentBanner)
    #expect(presentation.banner == nil)
}

@Test
func staleToastTimerCannotClearANewerToast() {
    var presentation = NoticePresentationState()
    let first = UserNotice(
        title: "First",
        message: "Old success",
        severity: .success
    )
    let replacement = UserNotice(
        title: "Replacement",
        message: "New success",
        severity: .success
    )

    presentation.presentToast(first)
    presentation.presentToast(replacement)

    let dismissedStaleToast = presentation.dismissToast(id: first.id)
    #expect(!dismissedStaleToast)
    #expect(presentation.toast == replacement)
    let dismissedCurrentToast = presentation.dismissToast(
        id: replacement.id
    )
    #expect(dismissedCurrentToast)
    #expect(presentation.toast == nil)
}

@Test
func clearingOneNoticeSurfacePreservesTheOther() {
    let banner = UserNotice(
        title: "Warning",
        message: "Skipped one file",
        severity: .warning,
        actions: [.showScanIssues]
    )
    let toast = UserNotice(
        title: "Saved",
        message: "Metadata exported",
        severity: .success
    )
    var presentation = NoticePresentationState(
        banner: banner,
        toast: toast
    )

    presentation.clearBanner()
    #expect(presentation.banner == nil)
    #expect(presentation.toast == toast)

    presentation.clearToast()
    #expect(presentation.toast == nil)
}

@Test
func noticeActionsRemainOrderedAndDeduplicatableByCallers() {
    let notice = UserNotice(
        title: "Render failed",
        message: "Truncated payload",
        severity: .error,
        actions: [.retryRender, .showInFinder]
    )

    #expect(notice.actions == [.retryRender, .showInFinder])
    #expect(Set(notice.actions).count == 2)
}
