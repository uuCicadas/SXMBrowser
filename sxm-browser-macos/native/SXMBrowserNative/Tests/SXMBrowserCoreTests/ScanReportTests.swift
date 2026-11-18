import Foundation
import Testing
@testable import SXMBrowserCore

private func makeScanReportTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sxm-scan-report-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func writeScanSXM(named filename: String, to directory: URL, valid: Bool) throws {
    let body: String
    if valid {
        body = """
        :NANONIS_VERSION:
        2
        :SCANIT_TYPE:
        FLOAT MSBFIRST
        :SCAN_PIXELS:
        1 1
        :DATA_INFO:
        Channel\tName\tUnit\tDirection
        0\tZ\tm\tforward
        :SCANIT_END:

        """
    } else {
        body = "This is not an SXM file."
    }
    var data = Data(body.utf8)
    if valid {
        data.append(contentsOf: [0x1a, 0x04])
    }
    try data.write(to: directory.appendingPathComponent(filename))
}

private func writeScanDAT(
    named filename: String,
    to directory: URL,
    rows: [String]?,
    experiment: String = "Bias Spectroscopy"
) throws {
    let url = directory.appendingPathComponent(filename)
    guard let rows else {
        try Data("Experiment\t\(experiment)\n".utf8).write(to: url)
        return
    }
    let text = """
    Experiment\t\(experiment)
    [DATA]
    Bias (V)\tCurrent (A)
    \(rows.joined(separator: "\n"))
    """
    try Data(text.utf8).write(to: url)
}

@Test
func sxmFolderScanReturnsSortedItemsAndFileIssues() throws {
    let directory = try makeScanReportTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeScanSXM(named: "b-valid.sxm", to: directory, valid: true)
    try writeScanSXM(named: "A-valid.sxm", to: directory, valid: true)
    try writeScanSXM(named: "c-broken.sxm", to: directory, valid: false)

    let report = try SXMParser().scanFolder(directory)

    #expect(report.items.map(\.filename) == ["A-valid.sxm", "b-valid.sxm"])
    #expect(report.issues.count == 1)
    #expect(report.issues[0].file.lastPathComponent == "c-broken.sxm")
    #expect(report.issues[0].stage == .sxmMetadata)
    #expect(!report.issues[0].reason.isEmpty)
    #expect(report.issues[0].badLineCount == nil)
}

@Test
func spectroscopyScanKeepsUsableFilesAndReportsBadRows() throws {
    let directory = try makeScanReportTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeScanDAT(
        named: "b-partial.dat",
        to: directory,
        rows: ["0\t1", "bad row", "1\t2", "2\tnot-a-number"]
    )
    try writeScanDAT(
        named: "A-valid.dat",
        to: directory,
        rows: ["0\t3", "1\t4"]
    )
    try writeScanDAT(named: "c-invalid.dat", to: directory, rows: nil)
    try writeScanDAT(
        named: "d-too-few.dat",
        to: directory,
        rows: ["0\t1", "broken"]
    )

    let report = try SpectroscopyParser().scanFolder(directory)

    #expect(report.items.map(\.filename) == ["A-valid.dat", "b-partial.dat"])
    #expect(report.issues.count == 3)
    #expect(report.issues[0].file.lastPathComponent == "b-partial.dat")
    #expect(report.issues[0].stage == .spectroscopyRows)
    #expect(report.issues[0].badLineCount == 2)
    #expect(report.issues[1].file.lastPathComponent == "c-invalid.dat")
    #expect(report.issues[1].stage == .spectroscopyFile)
    #expect(report.issues[1].badLineCount == nil)
    #expect(report.issues[2].file.lastPathComponent == "d-too-few.dat")
    #expect(report.issues[2].stage == .spectroscopyFile)
    #expect(report.issues[2].badLineCount == 1)
}

@Test
func folderEnumerationErrorsAreNotConvertedIntoScanIssues() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-scan-folder-\(UUID().uuidString)", isDirectory: true)
    var sxmThrew = false
    var spectroscopyThrew = false

    do {
        _ = try SXMParser().scanFolder(missing)
    } catch {
        sxmThrew = true
    }
    do {
        _ = try SpectroscopyParser().scanFolder(missing)
    } catch {
        spectroscopyThrew = true
    }

    #expect(sxmThrew)
    #expect(spectroscopyThrew)
}

@Test
func scanIssueRoundTripsForExportableDiagnostics() throws {
    let issue = ScanIssue(
        file: URL(fileURLWithPath: "/tmp/broken.dat"),
        stage: .spectroscopyRows,
        reason: "Ignored malformed rows.",
        badLineCount: 3
    )

    let data = try JSONEncoder().encode(issue)
    let decoded = try JSONDecoder().decode(ScanIssue.self, from: data)

    #expect(decoded == issue)
}

@Test
func folderScansPropagateCancellation() async throws {
    let directory = try makeScanReportTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sxmWasCancelled = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try SXMParser().scanFolder(directory)
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }.value
    let spectroscopyWasCancelled = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try SpectroscopyParser().scanFolder(directory)
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }.value

    #expect(sxmWasCancelled)
    #expect(spectroscopyWasCancelled)
}
