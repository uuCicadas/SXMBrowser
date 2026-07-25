import Foundation
import Testing
@testable import SXMBrowserCore

private func makeDATFixture(
    columns: [String] = ["Bias (V)", "Current (A)"],
    rows: [String]
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("spectroscopy-parser-\(UUID().uuidString).dat")
    let text = """
    Experiment\tBias Spectroscopy
    [DATA]
    \(columns.joined(separator: "\t"))
    \(rows.joined(separator: "\n"))
    """
    try Data(text.utf8).write(to: url)
    return url
}

@Test
func datLoadsWithExactlyTwoCompleteFiniteRows() throws {
    let url = try makeDATFixture(rows: ["0\t1", "1\t2"])
    defer { try? FileManager.default.removeItem(at: url) }

    let file = try SpectroscopyParser().loadFile(url)

    #expect(file.curve.x == [0, 1])
    #expect(file.curve.y == [1, 2])
}

@Test
func datRejectsTooFewValidRowsAndReportsEveryBadLine() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spectroscopy-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeDATFixture(
        rows: [
            "0\t1",
            "1",
            "2\tnot-a-number",
            "3\tNaN",
            "4\tInfinity",
            "5\t6\textra",
        ]
    )
    let url = directory.appendingPathComponent("invalid.dat")
    try FileManager.default.moveItem(at: source, to: url)

    let report = try SpectroscopyParser().scanFolder(directory)

    #expect(report.items.isEmpty)
    #expect(report.issues.count == 1)
    #expect(report.issues[0].file.lastPathComponent == url.lastPathComponent)
    #expect(report.issues[0].badLineCount == 5)
    #expect(report.issues[0].reason.contains("at least 2"))
}

@Test
func datLoadsValidRowsWhileCountingMalformedRows() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spectroscopy-partial-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeDATFixture(
        rows: [
            "0\t1",
            "1\t2",
            "2\tNaN",
            "3\t4\textra",
        ]
    )
    let url = directory.appendingPathComponent("partial.dat")
    try FileManager.default.moveItem(at: source, to: url)

    let report = try SpectroscopyParser().scanFolder(directory)

    #expect(report.items.count == 1)
    #expect(report.items[0].curve.x == [0, 1])
    #expect(report.issues.count == 1)
    #expect(report.issues[0].badLineCount == 2)
}

@Test
func duplicateDatColumnNamesAreMadeUnambiguous() throws {
    let url = try makeDATFixture(
        columns: ["Bias", "Current", "Current"],
        rows: ["0\t1\t2", "1\t3\t4"]
    )
    defer { try? FileManager.default.removeItem(at: url) }

    let file = try SpectroscopyParser().loadFile(url)

    #expect(file.curve.columns == ["Bias", "Current", "Current (2)"])
    #expect(file.curve.valuesByColumn["Current"] == [1, 3])
    #expect(file.curve.valuesByColumn["Current (2)"] == [2, 4])
}
