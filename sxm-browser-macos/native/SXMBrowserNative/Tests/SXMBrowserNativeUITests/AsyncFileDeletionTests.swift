import Foundation
import Testing
@testable import SXMBrowserNativeUI

private final class DeletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var offMainThreadResults: [Bool] = []
    private var failingURLs: Set<URL> = []
    private var gate: DispatchSemaphore?

    init(failingURLs: Set<URL> = [], blockWithGate: Bool = false) {
        self.failingURLs = failingURLs
        if blockWithGate {
            self.gate = DispatchSemaphore(value: 0)
        }
    }

    func trash(_ url: URL) throws {
        lock.lock()
        offMainThreadResults.append(!Thread.isMainThread)
        let semaphore = gate
        let shouldFail = failingURLs.contains(url)
        lock.unlock()

        semaphore?.wait()
        if shouldFail {
            throw NSError(
                domain: "AsyncFileDeletionTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Simulated failure"]
            )
        }
    }

    func releaseGate() {
        lock.lock()
        let semaphore = gate
        lock.unlock()
        semaphore?.signal()
    }

    var allRanOffMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !offMainThreadResults.isEmpty && offMainThreadResults.allSatisfy { $0 }
    }
}

@MainActor
@Test
func performDeleteFilesRunsOffMainThreadManagesBusyLockAndReconcilesState() async {
    let model = AppModel()
    let f1 = makeTestSXM(filename: "d1.sxm", modifiedOffset: 10)
    let f2 = makeTestSXM(filename: "d2.sxm", modifiedOffset: 20)
    let f3 = makeTestSXM(filename: "d3.sxm", modifiedOffset: 30)
    model.dataset.files = [f1, f2, f3]
    model.select(f1)

    let probe = DeletionProbe(blockWithGate: true)
    model.confirmDeletion = { _ in true }
    model.trashFile = { url in try probe.trash(url) }
    var presentedAlerts: [([String], [String])] = []
    model.presentDeletionResultAlert = { trashed, failed in
        presentedAlerts.append((trashed, failed))
    }

    let task = Task { @MainActor in
        await model.performDeleteFiles([f1])
    }

    for _ in 0..<100 where !model.dataset.isDeletingFiles {
        await Task.yield()
    }
    #expect(model.dataset.isDeletingFiles)
    #expect(model.isMetadataBusy)

    probe.releaseGate()
    await task.value

    #expect(!model.dataset.isDeletingFiles)
    #expect(!model.isMetadataBusy)
    #expect(probe.allRanOffMainThread)
    #expect(model.dataset.files.map(\.id) == [f2.id, f3.id])
    #expect(model.selectedID == f2.id)
    #expect(presentedAlerts.isEmpty)
}

@MainActor
@Test
func performDeleteFilesHandlesPartialFailureAndReportsExactResults() async {
    let model = AppModel()
    let f1 = makeTestSXM(filename: "ok1.sxm", modifiedOffset: 10)
    let f2 = makeTestSXM(filename: "fail2.sxm", modifiedOffset: 20)
    let f3 = makeTestSXM(filename: "ok3.sxm", modifiedOffset: 30)
    model.dataset.files = [f1, f2, f3]
    model.select(f1)

    let probe = DeletionProbe(failingURLs: [f2.path])
    model.confirmDeletion = { _ in true }
    model.trashFile = { url in try probe.trash(url) }
    var presentedAlerts: [([String], [String])] = []
    model.presentDeletionResultAlert = { trashed, failed in
        presentedAlerts.append((trashed, failed))
    }

    await model.performDeleteFiles([f1, f2, f3])

    #expect(probe.allRanOffMainThread)
    #expect(!model.isMetadataBusy)
    #expect(model.dataset.files.map(\.filename) == ["fail2.sxm"])
    #expect(presentedAlerts.count == 1)
    #expect(presentedAlerts[0].0 == ["ok1.sxm", "ok3.sxm"])
    #expect(presentedAlerts[0].1 == ["fail2.sxm"])
}
