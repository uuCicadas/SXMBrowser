import Foundation
import Testing
@testable import SXMBrowserCore

private func groupingTestSXM() -> SXMMetadata {
    SXMMetadata(
        path: URL(fileURLWithPath: "/tmp/grouping-test.sxm"),
        filename: "grouping-test.sxm",
        header: [:],
        recordedTime: nil,
        modifiedTime: .distantPast,
        pixels: (width: 2, height: 2),
        scanRange: nil,
        scanOffset: nil,
        scanAngle: nil,
        scanDir: nil,
        zControllerOn: nil,
        channels: [],
        defaultChannel: nil
    )
}

private func groupingTestSpectrum(
    filename: String,
    kind: SpectroscopyKind,
    experiment: String? = nil,
    columns: [String],
    values: [[Double]]
) -> SpectroscopyFile {
    let valuesByColumn = Dictionary(
        uniqueKeysWithValues: zip(columns, values).map { ($0.0, $0.1) }
    )
    let curve = SpectroscopyCurve(
        filename: filename,
        modifiedTime: .distantPast,
        columns: columns,
        valuesByColumn: valuesByColumn,
        x: values[0],
        y: values[1]
    )
    return SpectroscopyFile(
        path: URL(fileURLWithPath: "/tmp/\(filename)"),
        filename: filename,
        kind: kind,
        experiment: experiment ?? kind.label,
        modifiedTime: .distantPast,
        savedTime: nil,
        position: nil,
        xLabel: columns[0],
        yLabel: columns[1],
        colorIndex: 0,
        curve: curve
    )
}

@Test
func experimentIdentityUsesNFCWhitespaceAndPOSIXCaseFolding() {
    let composed = SpectroscopyExperimentIdentity.make(
        experiment: "  CAFÉ   Sweep\tMode ",
        fallbackKind: .other
    )
    let decomposed = SpectroscopyExperimentIdentity.make(
        experiment: "cafe\u{301} sweep mode",
        fallbackKind: .other
    )

    #expect(composed == "café sweep mode")
    #expect(decomposed == composed)
    #expect(
        SpectroscopyExperimentIdentity.make(
            experiment: " \n\t ",
            fallbackKind: .bias
        ) == SpectroscopyKind.bias.rawValue
    )
    #expect(
        SpectroscopyExperimentIdentity.make(
            experiment: nil,
            fallbackKind: .other
        ) == SpectroscopyKind.other.rawValue
    )
}

@Test
func columnSchemaNormalizesCaseAndWhitespaceButPreservesOrder() {
    let first = SpectroscopyColumnSchema(
        columns: [" Bias (V) ", "Current   (A)"]
    )
    let equivalent = SpectroscopyColumnSchema(
        columns: ["bias (v)", " current (a) "]
    )
    let reordered = SpectroscopyColumnSchema(
        columns: ["Current (A)", "Bias (V)"]
    )

    #expect(first == equivalent)
    #expect(first.fingerprint == equivalent.fingerprint)
    #expect(first != reordered)
    #expect(first.fingerprint != reordered.fingerprint)
}

@Test
func compatibleGroupsPartitionByKindAndOrderedColumnSchema() throws {
    let sxm = groupingTestSXM()
    let bias = groupingTestSpectrum(
        filename: "01.dat",
        kind: .bias,
        columns: ["Bias (V)", "Current (A)"],
        values: [[0, 1], [2, 3]]
    )
    let equivalentBias = groupingTestSpectrum(
        filename: "02.dat",
        kind: .bias,
        columns: [" bias (v) ", "current   (a)"],
        values: [[4, 5], [6, 7]]
    )
    let extraColumnBias = groupingTestSpectrum(
        filename: "03.dat",
        kind: .bias,
        columns: ["Bias (V)", "Current (A)", "Frequency (Hz)"],
        values: [[0, 1], [2, 3], [4, 5]]
    )
    let zSpectrum = groupingTestSpectrum(
        filename: "04.dat",
        kind: .z,
        columns: ["Bias (V)", "Current (A)"],
        values: [[0, 1], [2, 3]]
    )

    let groups = SpectroscopyGroup.compatibleGroups(
        sxm: sxm,
        spectra: [extraColumnBias, zSpectrum, equivalentBias, bias]
    )

    #expect(groups.count == 3)
    #expect(groups[0].kind == .z)
    let twoColumnBias = try #require(
        groups.first {
            $0.kind == .bias && $0.columnSchema.normalizedColumns.count == 2
        }
    )
    #expect(twoColumnBias.spectra.map(\.filename) == ["01.dat", "02.dat"])
    #expect(twoColumnBias.availableColumns == ["Bias (V)", "Current (A)"])
}

@Test
func compatibleGroupsPartitionOtherSpectraByExperimentIdentity() throws {
    let sxm = groupingTestSXM()
    let first = groupingTestSpectrum(
        filename: "01.dat",
        kind: .other,
        experiment: "Frequency Sweep",
        columns: ["Frequency", "Current"],
        values: [[0, 1], [2, 3]]
    )
    let second = groupingTestSpectrum(
        filename: "02.dat",
        kind: .other,
        experiment: "Lock-In Sweep",
        columns: ["Frequency", "Current"],
        values: [[4, 5], [6, 7]]
    )

    let groups = SpectroscopyGroup.compatibleGroups(
        sxm: sxm,
        spectra: [second, first]
    )

    #expect(groups.count == 2)
    #expect(
        groups.map(\.experimentIdentity)
            == ["frequency sweep", "lock-in sweep"]
    )
    #expect(Set(groups.map(\.id)).count == 2)
}

@Test
func equivalentExperimentSpellingsShareOneStableGroup() throws {
    let sxm = groupingTestSXM()
    let first = groupingTestSpectrum(
        filename: "01.dat",
        kind: .other,
        experiment: "  CAFÉ   Sweep ",
        columns: ["Frequency", "Current"],
        values: [[0, 1], [2, 3]]
    )
    let equivalent = groupingTestSpectrum(
        filename: "02.dat",
        kind: .other,
        experiment: "cafe\u{301}\tsweep",
        columns: ["Frequency", "Current"],
        values: [[4, 5], [6, 7]]
    )

    let combined = try #require(
        SpectroscopyGroup.compatibleGroups(
            sxm: sxm,
            spectra: [equivalent, first]
        ).first
    )
    let firstOnly = try #require(
        SpectroscopyGroup.compatibleGroups(
            sxm: sxm,
            spectra: [first]
        ).first
    )

    #expect(combined.experimentIdentity == "café sweep")
    #expect(combined.spectra.count == 2)
    #expect(combined.id == firstOnly.id)
    #expect(combined.experiment == first.experiment)
}

@Test
func missingRequestedCurveColumnIsIncompatibleInsteadOfFallingBack() throws {
    let spectrum = groupingTestSpectrum(
        filename: "missing-column.dat",
        kind: .bias,
        columns: ["Bias (V)", "Current (A)"],
        values: [[0, 1], [2, 3]]
    )

    #expect(
        spectrum.curve.points(
            xColumn: "Bias (V)",
            yColumn: "Frequency (Hz)"
        ) == nil
    )
    let points = try #require(
        spectrum.curve.points(
            xColumn: "Bias (V)",
            yColumn: "Current (A)"
        )
    )
    #expect(points.map { $0.x } == [0, 1])
    #expect(points.map { $0.y } == [2, 3])
}

@Test
func compatibleGroupReadsEquivalentColumnLabelsBySchemaPosition() throws {
    let sxm = groupingTestSXM()
    let first = groupingTestSpectrum(
        filename: "01.dat",
        kind: .bias,
        columns: ["Bias (V)", "Current (A)"],
        values: [[0, 1], [2, 3]]
    )
    let second = groupingTestSpectrum(
        filename: "02.dat",
        kind: .bias,
        columns: [" bias (v) ", "current   (a)"],
        values: [[4, 5], [6, 7]]
    )
    let group = try #require(
        SpectroscopyGroup.compatibleGroups(
            sxm: sxm,
            spectra: [first, second]
        ).first
    )

    let points = try #require(
        group.points(
            for: second,
            xColumn: "Bias (V)",
            yColumn: "Current (A)"
        )
    )

    #expect(points.map { $0.x } == [4, 5])
    #expect(points.map { $0.y } == [6, 7])
}
