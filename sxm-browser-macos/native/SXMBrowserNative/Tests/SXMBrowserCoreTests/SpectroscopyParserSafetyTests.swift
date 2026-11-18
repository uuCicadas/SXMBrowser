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

@Test
func duplicateDatColumnsPreserveNumberedChannelValues() throws {
    let url = try makeDATFixture(
        columns: ["Bias", "Current", "Current", "Current (2)", "Current"],
        rows: ["0\t1\t2\t3\t4", "1\t5\t6\t7\t8"]
    )
    defer { try? FileManager.default.removeItem(at: url) }

    let curve = try SpectroscopyParser().loadFile(url).curve

    #expect(curve.columns == ["Bias", "Current", "Current (3)", "Current (2)", "Current (4)"])
    #expect(curve.valuesByColumn["Current"] == [1, 5])
    #expect(curve.valuesByColumn["Current (3)"] == [2, 6])
    #expect(curve.valuesByColumn["Current (2)"] == [3, 7])
    #expect(curve.valuesByColumn["Current (4)"] == [4, 8])
}

@Test
func datRejectsOversizedAndBinaryFilesWithoutFullRead() throws {
    let oversizedURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("spectroscopy-oversized-\(UUID().uuidString).dat")
    FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: oversizedURL) }

    let oversizedHandle = try FileHandle(forWritingTo: oversizedURL)
    try oversizedHandle.truncate(atOffset: SpectroscopyParser.maximumFileByteCount + 1)
    try oversizedHandle.close()

    var caughtOversized = false
    do {
        _ = try SpectroscopyParser().loadFile(oversizedURL)
    } catch SpectroscopyParserError.fileTooLarge(_, let byteCount, let maximumByteCount) {
        caughtOversized = byteCount == SpectroscopyParser.maximumFileByteCount + 1
            && maximumByteCount == SpectroscopyParser.maximumFileByteCount
    }
    #expect(caughtOversized)

    let binaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("spectroscopy-binary-\(UUID().uuidString).dat")
    try Data([0x01, 0x00, 0x02, 0x03]).write(to: binaryURL)
    defer { try? FileManager.default.removeItem(at: binaryURL) }

    var caughtBinary = false
    do {
        _ = try SpectroscopyParser().loadFile(binaryURL)
    } catch SpectroscopyParserError.missingData {
        caughtBinary = true
    }
    #expect(caughtBinary)
}
