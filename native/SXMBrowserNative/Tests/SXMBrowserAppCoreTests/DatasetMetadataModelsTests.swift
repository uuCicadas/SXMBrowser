import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private let sampleFingerprint = "0123456789abcdef"

private func capturedMetadataError<T>(
    _ operation: () throws -> T
) -> DatasetMetadataValidationError? {
    do {
        _ = try operation()
        return nil
    } catch let error as DatasetMetadataValidationError {
        return error
    } catch {
        return nil
    }
}

private func makeDatasetRecord(
    id: UUID = UUID(),
    tags: [DatasetTagV1] = [],
    manualAssociations: [DatasetManualAssociationV1] = [],
    hiddenDATPaths: [DatasetRelativePath] = [],
    spectrumAxisPreferences: [SpectrumAxisPreferenceV1] = []
) throws -> DatasetRecordV1 {
    try DatasetRecordV1(
        id: id,
        folderBookmark: Data([0x01, 0x02]),
        lastKnownPath: "/Users/researcher/STM Dataset",
        tags: tags,
        manualAssociations: manualAssociations,
        hiddenDATPaths: hiddenDATPaths,
        spectrumAxisPreferences: spectrumAxisPreferences,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test
func relativePathsNormalizeUnicodeAndValidateFileKinds() throws {
    let decomposed = "nested/Cafe\u{301}.SXM"
    let path = try DatasetRelativePath.sxm(decomposed)

    #expect(path.rawValue == "nested/Café.SXM")
    #expect(path.pathExtension == "SXM")
    #expect(try path.validated(for: .sxm) == path)
    #expect(
        capturedMetadataError {
            try path.validated(for: .dat)
        } == .unexpectedFileExtension(
            path: "nested/Café.SXM",
            expected: .dat,
            actual: "SXM"
        )
    )
}

@Test(
    arguments: [
        ("", DatasetRelativePathInvalidReason.empty),
        ("/absolute/file.sxm", .absolute),
        ("folder/\0file.sxm", .containsNUL),
        ("folder\\file.sxm", .containsBackslash),
        ("folder//file.sxm", .emptyComponent),
        ("folder/", .emptyComponent),
        ("./file.sxm", .dotComponent),
        ("folder/../file.sxm", .parentComponent),
    ]
)
func invalidRelativePathComponentsAreRejected(
    rawValue: String,
    reason: DatasetRelativePathInvalidReason
) {
    #expect(
        capturedMetadataError {
            try DatasetRelativePath(rawValue)
        } == .invalidRelativePath(
            rawValue: rawValue,
            reason: reason
        )
    )
}

@Test
func recordCanonicalizationDeduplicatesStableArrays() throws {
    let firstSXM = try DatasetRelativePath.sxm("set/a.sxm")
    let secondSXM = try DatasetRelativePath.sxm("set/b.sxm")
    let firstDAT = try DatasetRelativePath.dat("set/a001.dat")
    let secondDAT = try DatasetRelativePath.dat("set/b001.dat")
    let tag = try DatasetTagV1(
        name: "  Primary  ",
        sxmPaths: [firstSXM, firstSXM, secondSXM, firstSXM]
    )
    let association = try DatasetManualAssociationV1(
        datPath: firstDAT,
        sxmPath: firstSXM
    )
    let preference = try SpectrumAxisPreferenceV1(
        sxmPath: firstSXM.rawValue,
        kind: .bias,
        schemaFingerprint: sampleFingerprint,
        selection: AxisSelection(
            xColumn: " Bias (V) ",
            yColumn: " Current (A) "
        )
    )

    let record = try makeDatasetRecord(
        tags: [tag],
        manualAssociations: [association, association],
        hiddenDATPaths: [firstDAT, secondDAT, firstDAT],
        spectrumAxisPreferences: [preference, preference]
    )

    #expect(record.tags[0].name == "Primary")
    #expect(record.tags[0].sxmPaths == [firstSXM, secondSXM])
    #expect(record.manualAssociations == [association])
    #expect(record.hiddenDATPaths == [firstDAT, secondDAT])
    #expect(record.spectrumAxisPreferences == [preference])
    #expect(preference.selection == AxisSelection(
        xColumn: "Bias (V)",
        yColumn: "Current (A)"
    ))
}

@Test
func documentAndRecordInvariantsRejectInvalidIdentityState() throws {
    let datasetID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    let missingID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
    let record = try makeDatasetRecord(id: datasetID)

    #expect(
        capturedMetadataError {
            try DatasetMetadataDocumentV1(
                schemaVersion: 2,
                datasets: [record]
            )
        } == .unsupportedSchemaVersion(2)
    )
    #expect(
        capturedMetadataError {
            try DatasetMetadataDocumentV1(
                lastOpenedDatasetID: missingID,
                datasets: [record]
            )
        } == .lastOpenedDatasetMissing(missingID)
    )
    #expect(
        capturedMetadataError {
            try DatasetMetadataDocumentV1(
                datasets: [record, record]
            )
        } == .duplicateDatasetID(datasetID)
    )
    #expect(
        capturedMetadataError {
            try DatasetRecordV1(
                folderBookmark: Data(),
                lastKnownPath: "/dataset",
                updatedAt: .now
            )
        } == .emptyFolderBookmark
    )
    #expect(
        capturedMetadataError {
            try DatasetRecordV1(
                lastKnownPath: "relative/dataset",
                updatedAt: .now
            )
        } == .invalidLastKnownPath("relative/dataset")
    )
}

@Test
func recordRejectsDuplicateTagIDsAndCaseInsensitiveNames() throws {
    let repeatedID = UUID(
        uuidString: "33333333-3333-3333-3333-333333333333"
    )!
    let first = try DatasetTagV1(id: repeatedID, name: "Surface")
    let repeated = try DatasetTagV1(id: repeatedID, name: "Other")
    let caseCollision = try DatasetTagV1(name: "  sUrFaCe ")

    #expect(
        capturedMetadataError {
            try makeDatasetRecord(tags: [first, repeated])
        } == .duplicateTagID(repeatedID)
    )
    #expect(
        capturedMetadataError {
            try makeDatasetRecord(tags: [first, caseCollision])
        } == .duplicateTagName("sUrFaCe")
    )
}

@Test
func metadataCodableRoundTripIsCanonicalAndDeterministic() throws {
    let datasetID = UUID(
        uuidString: "44444444-4444-4444-4444-444444444444"
    )!
    let tagID = UUID(
        uuidString: "55555555-5555-5555-5555-555555555555"
    )!
    let tag = try DatasetTagV1(
        id: tagID,
        name: "Keep",
        sxmPathStrings: ["images/a.sxm", "images/a.sxm"]
    )
    let association = try DatasetManualAssociationV1(
        datPath: "spectra/a001.dat",
        sxmPath: "images/a.sxm"
    )
    let preference = try SpectrumAxisPreferenceV1(
        sxmPath: "images/a.sxm",
        kind: .bias,
        schemaFingerprint: " 0123456789ABCDEF ",
        selection: AxisSelection(
            xColumn: "Bias (V)",
            yColumn: "Current (A)"
        )
    )
    let record = try makeDatasetRecord(
        id: datasetID,
        tags: [tag],
        manualAssociations: [association],
        hiddenDATPaths: [try DatasetRelativePath.dat("spectra/a002.dat")],
        spectrumAxisPreferences: [preference]
    )
    let document = try DatasetMetadataDocumentV1(
        lastOpenedDatasetID: datasetID,
        datasets: [record]
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let firstEncoding = try encoder.encode(document)
    let decoded = try JSONDecoder.configuredForMetadataTests()
        .decode(DatasetMetadataDocumentV1.self, from: firstEncoding)
    let secondEncoding = try encoder.encode(decoded)

    #expect(decoded == document)
    #expect(firstEncoding == secondEncoding)
    #expect(decoded.datasets[0].tags[0].sxmPaths.count == 1)
    #expect(
        decoded.datasets[0]
            .spectrumAxisPreferences[0]
            .key.schemaFingerprint == sampleFingerprint
    )
}

@Test
func decodingRunsSchemaAndPathValidation() throws {
    let invalidSchema = Data(
        """
        {"schemaVersion":99,"datasets":[]}
        """.utf8
    )
    #expect(throws: DatasetMetadataValidationError.self) {
        try JSONDecoder().decode(
            DatasetMetadataDocumentV1.self,
            from: invalidSchema
        )
    }

    let invalidRelativePath = Data("\"../escape.sxm\"".utf8)
    #expect(throws: DatasetMetadataValidationError.self) {
        try JSONDecoder().decode(
            DatasetRelativePath.self,
            from: invalidRelativePath
        )
    }
}

@Test
func tagCRUDTrimsNamesPreservesIDsAndSupportsOrdering() throws {
    let alphaID = UUID(
        uuidString: "66666666-6666-6666-6666-666666666666"
    )!
    let betaID = UUID(
        uuidString: "77777777-7777-7777-7777-777777777777"
    )!
    let gammaID = UUID(
        uuidString: "88888888-8888-8888-8888-888888888888"
    )!
    var record = try makeDatasetRecord()

    let beta = try record.createTag(id: betaID, name: "  Beta ")
    _ = try record.createTag(id: gammaID, name: "Gamma")
    _ = try record.createTag(id: alphaID, name: "Alpha")
    #expect(beta.id == betaID)
    #expect(beta.name == "Beta")

    try record.renameTag(id: betaID, to: "  Delta ")
    #expect(record.tags[0].id == betaID)
    #expect(record.tags[0].name == "Delta")

    #expect(
        capturedMetadataError {
            try record.renameTag(id: gammaID, to: " alpha ")
        } == .duplicateTagName("alpha")
    )

    try record.moveTag(id: alphaID, to: 0)
    #expect(record.tags.map(\.id) == [alphaID, betaID, gammaID])

    record.sortTagsByName()
    #expect(record.tags.map(\.name) == ["Alpha", "Delta", "Gamma"])

    let deleted = record.deleteTag(id: betaID)
    #expect(deleted?.id == betaID)
    #expect(record.tags.map(\.id) == [alphaID, gammaID])
    #expect(record.deleteTag(id: betaID) == nil)
}

@Test
func tagMembershipReplacementValidatesExtensionsAndDeduplicates() throws {
    let tagID = UUID(
        uuidString: "99999999-9999-9999-9999-999999999999"
    )!
    var record = try makeDatasetRecord(
        tags: [try DatasetTagV1(id: tagID, name: "Member")]
    )
    let first = try DatasetRelativePath.sxm("a.sxm")
    let second = try DatasetRelativePath.sxm("b.sxm")

    try record.replaceTagMembers(
        id: tagID,
        with: [first, first, second]
    )
    #expect(record.tags[0].sxmPaths == [first, second])

    let datPath = try DatasetRelativePath.dat("not-an-image.dat")
    #expect(
        capturedMetadataError {
            try record.replaceTagMembers(id: tagID, with: [datPath])
        } == .unexpectedFileExtension(
            path: datPath.rawValue,
            expected: .sxm,
            actual: "dat"
        )
    )
    #expect(record.tags[0].sxmPaths == [first, second])
}

@Test
func associationAndAxisPreferenceKeysRejectConflicts() throws {
    let datPath = try DatasetRelativePath.dat("spectra/a001.dat")
    let firstSXM = try DatasetRelativePath.sxm("images/a.sxm")
    let secondSXM = try DatasetRelativePath.sxm("images/b.sxm")
    let firstAssociation = try DatasetManualAssociationV1(
        datPath: datPath,
        sxmPath: firstSXM
    )
    let conflictingAssociation = try DatasetManualAssociationV1(
        datPath: datPath,
        sxmPath: secondSXM
    )

    #expect(
        capturedMetadataError {
            try makeDatasetRecord(
                manualAssociations: [
                    firstAssociation,
                    conflictingAssociation,
                ]
            )
        } == .conflictingManualAssociation(datPath)
    )

    let firstPreference = try SpectrumAxisPreferenceV1(
        sxmPath: firstSXM.rawValue,
        kind: .z,
        schemaFingerprint: sampleFingerprint,
        selection: AxisSelection(xColumn: "Z (m)", yColumn: "Current (A)")
    )
    let conflictingPreference = try SpectrumAxisPreferenceV1(
        key: firstPreference.key,
        selection: AxisSelection(xColumn: "Z (m)", yColumn: "Phase (deg)")
    )
    #expect(
        capturedMetadataError {
            try makeDatasetRecord(
                spectrumAxisPreferences: [
                    firstPreference,
                    conflictingPreference,
                ]
            )
        } == .conflictingAxisPreference(firstPreference.key)
    )
}

@Test
func associationAndAxisInputsRequireTypedPathsAndValidColumns() throws {
    #expect(
        capturedMetadataError {
            try DatasetManualAssociationV1(
                datPath: "image.sxm",
                sxmPath: "spectrum.dat"
            )
        } == .unexpectedFileExtension(
            path: "image.sxm",
            expected: .dat,
            actual: "sxm"
        )
    )
    #expect(
        capturedMetadataError {
            try SpectrumAxisPreferenceKeyV1(
                sxmPath: "image.sxm",
                kind: .bias,
                schemaFingerprint: "not-a-fingerprint"
            )
        } == .invalidSchemaFingerprint("not-a-fingerprint")
    )

    let key = try SpectrumAxisPreferenceKeyV1(
        sxmPath: "image.sxm",
        kind: .bias,
        schemaFingerprint: sampleFingerprint
    )
    #expect(
        capturedMetadataError {
            try SpectrumAxisPreferenceV1(
                key: key,
                selection: AxisSelection(
                    xColumn: " ",
                    yColumn: "Current (A)"
                )
            )
        } == .invalidAxisColumn
    )
}

@Test
func recordMutationAPIsValidateAtomicallyAndAdvanceUpdateTime() throws {
    let datasetID = UUID(
        uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )!
    let firstDate = Date(timeIntervalSince1970: 1_700_000_100)
    let secondDate = Date(timeIntervalSince1970: 1_700_000_200)
    let thirdDate = Date(timeIntervalSince1970: 1_700_000_300)
    let fourthDate = Date(timeIntervalSince1970: 1_700_000_400)
    var record = try makeDatasetRecord(id: datasetID)

    try record.updateFolderIdentity(
        folderBookmark: Data([0xaa]),
        lastKnownPath: "/Volumes/Data/Cafe\u{301}",
        updatedAt: firstDate
    )
    #expect(record.id == datasetID)
    #expect(record.folderBookmark == Data([0xaa]))
    #expect(record.lastKnownPath == "/Volumes/Data/Café")
    #expect(record.updatedAt == firstDate)

    #expect(throws: DatasetMetadataValidationError.self) {
        try record.updateFolderIdentity(
            folderBookmark: Data(),
            lastKnownPath: "/Should Not Apply",
            updatedAt: secondDate
        )
    }
    #expect(record.folderBookmark == Data([0xaa]))
    #expect(record.lastKnownPath == "/Volumes/Data/Café")
    #expect(record.updatedAt == firstDate)

    let datPath = try DatasetRelativePath.dat("spectra/one.dat")
    let sxmPath = try DatasetRelativePath.sxm("images/one.sxm")
    let association = try DatasetManualAssociationV1(
        datPath: datPath,
        sxmPath: sxmPath
    )
    try record.replaceManualAssociations(
        with: [association, association],
        updatedAt: secondDate
    )
    #expect(record.manualAssociations == [association])
    #expect(record.updatedAt == secondDate)

    try record.replaceHiddenDATPaths(
        with: [datPath, datPath],
        updatedAt: thirdDate
    )
    #expect(record.hiddenDATPaths == [datPath])
    #expect(record.updatedAt == thirdDate)

    let preference = try SpectrumAxisPreferenceV1(
        sxmPath: sxmPath.rawValue,
        kind: .bias,
        schemaFingerprint: sampleFingerprint,
        selection: AxisSelection(
            xColumn: "Bias (V)",
            yColumn: "Current (A)"
        )
    )
    try record.replaceSpectrumAxisPreferences(
        with: [preference, preference],
        updatedAt: fourthDate
    )
    #expect(record.spectrumAxisPreferences == [preference])
    #expect(record.updatedAt == fourthDate)

    #expect(throws: DatasetMetadataValidationError.self) {
        try record.replaceHiddenDATPaths(
            with: [sxmPath],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }
    #expect(record.hiddenDATPaths == [datPath])
    #expect(record.updatedAt == fourthDate)
}

@Test
func documentMutationAPIsPreserveIdentityAndLastOpenedInvariant() throws {
    let firstID = UUID(
        uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )!
    let secondID = UUID(
        uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc"
    )!
    let missingID = UUID(
        uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd"
    )!
    let first = try makeDatasetRecord(id: firstID)
    let second = try makeDatasetRecord(id: secondID)
    var document = try DatasetMetadataDocumentV1(datasets: [first])

    document.upsertDataset(second)
    #expect(document.datasets.map(\.id) == [firstID, secondID])
    try document.setLastOpenedDatasetID(secondID)
    #expect(document.lastOpenedDatasetID == secondID)

    var replacement = second
    try replacement.updateFolderIdentity(
        folderBookmark: nil,
        lastKnownPath: "/Volumes/Reopened",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_600)
    )
    document.upsertDataset(replacement)
    #expect(document.datasets.map(\.id) == [firstID, secondID])
    #expect(document.datasets[1].lastKnownPath == "/Volumes/Reopened")

    let missing = try makeDatasetRecord(id: missingID)
    #expect(
        capturedMetadataError {
            try document.replaceDataset(missing)
        } == .datasetNotFound(missingID)
    )
    #expect(
        capturedMetadataError {
            try document.setLastOpenedDatasetID(missingID)
        } == .lastOpenedDatasetMissing(missingID)
    )
    #expect(document.lastOpenedDatasetID == secondID)

    let removed = document.removeDataset(id: secondID)
    #expect(removed?.id == secondID)
    #expect(document.datasets.map(\.id) == [firstID])
    #expect(document.lastOpenedDatasetID == nil)
    #expect(document.removeDataset(id: secondID) == nil)
}

private extension JSONDecoder {
    static func configuredForMetadataTests() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
