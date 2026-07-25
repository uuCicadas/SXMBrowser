import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private let transferTagID = UUID(
    uuidString: "55555555-5555-5555-5555-555555555555"
)!
private let secondTransferTagID = UUID(
    uuidString: "66666666-6666-6666-6666-666666666666"
)!
private let caseSensitiveTransferTagID = UUID(
    uuidString: "abcdefab-cdef-abcd-efab-cdefabcdefab"
)!
private let transferFingerprint = "0123456789abcdef"

private func capturedTransferError<T>(
    _ operation: () throws -> T
) -> DatasetMetadataTransferError? {
    do {
        _ = try operation()
        return nil
    } catch let error as DatasetMetadataTransferError {
        return error
    } catch {
        return nil
    }
}

private func transferJSON(
    identifier: String = DatasetMetadataTransferV1.formatIdentifier,
    version: String = "1",
    tags: String = "[]",
    manualAssociations: String = "[]",
    hiddenDATPaths: String = "[]",
    spectrumAxisPreferences: String = "[]",
    extraTopLevelField: String = ""
) -> Data {
    Data(
        """
        {
          "formatIdentifier": "\(identifier)",
          "formatVersion": \(version),
          "tags": \(tags),
          "manualAssociations": \(manualAssociations),
          "hiddenDATPaths": \(hiddenDATPaths),
          "spectrumAxisPreferences": \(spectrumAxisPreferences)\(extraTopLevelField)
        }
        """.utf8
    )
}

private func makeTransferTag(
    id: UUID = transferTagID,
    name: String = "Keep",
    paths: [String] = ["images/a.sxm"]
) throws -> DatasetTagV1 {
    try DatasetTagV1(
        id: id,
        name: name,
        sxmPathStrings: paths
    )
}

private func makeAxisPreference(
    sxmPath: String = "images/a.sxm",
    kind: SpectroscopyKind = .bias,
    fingerprint: String = transferFingerprint,
    xColumn: String = "Bias (V)",
    yColumn: String = "Current (A)"
) throws -> SpectrumAxisPreferenceV1 {
    try SpectrumAxisPreferenceV1(
        sxmPath: sxmPath,
        kind: kind,
        schemaFingerprint: fingerprint,
        selection: AxisSelection(
            xColumn: xColumn,
            yColumn: yColumn
        )
    )
}

private func makeFullTransfer() throws -> DatasetMetadataTransferV1 {
    try DatasetMetadataTransferV1(
        tags: [
            makeTransferTag(
                paths: ["images/b.sxm", "images/a.sxm"]
            ),
        ],
        manualAssociations: [
            DatasetManualAssociationV1(
                datPath: "spectra/a001.dat",
                sxmPath: "images/a.sxm"
            ),
        ],
        hiddenDATPaths: [
            DatasetRelativePath.dat("spectra/a002.dat"),
        ],
        spectrumAxisPreferences: [
            makeAxisPreference(),
        ]
    )
}

private func makeTemporaryTransferDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SXM-Transfer-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

@Test
func transferExportExcludesMachineAndDatasetIdentity() throws {
    let datasetID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    let tag = try makeTransferTag(id: caseSensitiveTransferTagID)
    let record = try DatasetRecordV1(
        id: datasetID,
        folderBookmark: Data([0xde, 0xad, 0xbe, 0xef]),
        lastKnownPath: "/Users/alice/Secret Dataset",
        tags: [tag],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let data = try DatasetMetadataTransferCodec().encode(
        DatasetMetadataTransferV1(exporting: record)
    )
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(json.contains(tag.id.uuidString.lowercased()))
    #expect(!json.contains(tag.id.uuidString))
    #expect(!json.contains(datasetID.uuidString.lowercased()))
    #expect(!json.contains(datasetID.uuidString))
    #expect(!json.contains("/Users/alice/Secret Dataset"))
    #expect(!json.contains("3q2+7w=="))
    #expect(!json.contains("1700000000"))
    #expect(!json.contains("folderBookmark"))
    #expect(!json.contains("lastKnownPath"))
    #expect(!json.contains("updatedAt"))
}

@Test
func transferEncodingMatchesCompactGoldenJSONAndRoundTrips() throws {
    let codec = DatasetMetadataTransferCodec()
    let transfer = try makeFullTransfer()

    let encoded = try codec.encode(transfer)
    let expected = Data(
        """
        {"formatIdentifier":"com.sxmbrowser.dataset-metadata","formatVersion":1,"hiddenDATPaths":["spectra/a002.dat"],"manualAssociations":[{"datPath":"spectra/a001.dat","sxmPath":"images/a.sxm"}],"spectrumAxisPreferences":[{"kind":"bias","schemaFingerprint":"0123456789abcdef","sxmPath":"images/a.sxm","xColumn":"Bias (V)","yColumn":"Current (A)"}],"tags":[{"id":"55555555-5555-5555-5555-555555555555","name":"Keep","sxmPaths":["images/a.sxm","images/b.sxm"]}]}
        """.utf8
    )

    #expect(encoded == expected)
    #expect(try codec.decode(encoded) == transfer)
    #expect(try codec.encode(codec.decode(encoded)) == expected)
}

@Test
func deterministicEncodingSortsSetLikeCollectionsButPreservesTagOrder()
    throws
{
    let firstTag = try makeTransferTag(
        paths: ["images/b.sxm", "images/a.sxm"]
    )
    let secondTag = try makeTransferTag(
        id: secondTransferTagID,
        name: "Second",
        paths: ["images/d.sxm", "images/c.sxm"]
    )
    let firstAssociation = try DatasetManualAssociationV1(
        datPath: "spectra/a.dat",
        sxmPath: "images/a.sxm"
    )
    let secondAssociation = try DatasetManualAssociationV1(
        datPath: "spectra/b.dat",
        sxmPath: "images/b.sxm"
    )
    let firstHidden = try DatasetRelativePath.dat("spectra/a-hidden.dat")
    let secondHidden = try DatasetRelativePath.dat("spectra/b-hidden.dat")
    let firstAxis = try makeAxisPreference()
    let secondAxis = try makeAxisPreference(
        sxmPath: "images/b.sxm",
        kind: .z,
        xColumn: "Z (m)",
        yColumn: "Current (A)"
    )

    let first = try DatasetMetadataTransferV1(
        tags: [firstTag, secondTag],
        manualAssociations: [secondAssociation, firstAssociation],
        hiddenDATPaths: [secondHidden, firstHidden],
        spectrumAxisPreferences: [secondAxis, firstAxis]
    )
    let equivalent = try DatasetMetadataTransferV1(
        tags: [
            makeTransferTag(
                paths: ["images/a.sxm", "images/b.sxm"]
            ),
            makeTransferTag(
                id: secondTransferTagID,
                name: "Second",
                paths: ["images/c.sxm", "images/d.sxm"]
            ),
        ],
        manualAssociations: [firstAssociation, secondAssociation],
        hiddenDATPaths: [firstHidden, secondHidden],
        spectrumAxisPreferences: [firstAxis, secondAxis]
    )

    let codec = DatasetMetadataTransferCodec()
    let firstData = try codec.encode(first)
    let repeatedData = try codec.encode(first)
    let equivalentData = try codec.encode(equivalent)
    #expect(firstData == repeatedData)
    #expect(firstData == equivalentData)

    let reversedTags = try DatasetMetadataTransferV1(
        tags: [secondTag, firstTag],
        manualAssociations: [firstAssociation, secondAssociation],
        hiddenDATPaths: [firstHidden, secondHidden],
        spectrumAxisPreferences: [firstAxis, secondAxis]
    )
    #expect(try codec.decode(codec.encode(reversedTags)).tags.map(\.id)
        == [secondTransferTagID, transferTagID])
    #expect(try codec.encode(reversedTags) != firstData)
}

@Test
func decoderAcceptsJSONWhitespaceAndKeyOrderThenReencodesCanonically()
    throws
{
    let reordered = Data(
        """
        {
          "tags": [],
          "spectrumAxisPreferences": [],
          "manualAssociations": [],
          "hiddenDATPaths": [],
          "formatVersion": 1,
          "formatIdentifier": "com.sxmbrowser.dataset-metadata"
        }
        """.utf8
    )
    let codec = DatasetMetadataTransferCodec()

    let transfer = try codec.decode(reordered)
    let canonical = try codec.encode(transfer)

    #expect(
        canonical == Data(
            """
            {"formatIdentifier":"com.sxmbrowser.dataset-metadata","formatVersion":1,"hiddenDATPaths":[],"manualAssociations":[],"spectrumAxisPreferences":[],"tags":[]}
            """.utf8
        )
    )
}

@Test
func unknownFieldsAreRejectedAtEveryObjectLevel() {
    let tagID = transferTagID.uuidString.lowercased()
    let cases: [(Data, String, String)] = [
        (
            transferJSON(extraTopLevelField: #","unexpected":true"#),
            "$",
            "unexpected"
        ),
        (
            transferJSON(
                tags:
                    #"[{"id":"\#(tagID)","name":"Keep","sxmPaths":[],"unexpected":true}]"#
            ),
            "$.tags[0]",
            "unexpected"
        ),
        (
            transferJSON(
                manualAssociations:
                    #"[{"datPath":"a.dat","sxmPath":"a.sxm","unexpected":true}]"#
            ),
            "$.manualAssociations[0]",
            "unexpected"
        ),
        (
            transferJSON(
                spectrumAxisPreferences:
                    #"[{"sxmPath":"a.sxm","kind":"bias","schemaFingerprint":"0123456789abcdef","xColumn":"X","yColumn":"Y","unexpected":true}]"#
            ),
            "$.spectrumAxisPreferences[0]",
            "unexpected"
        ),
    ]

    for (data, expectedPath, expectedField) in cases {
        let error = capturedTransferError {
            try DatasetMetadataTransferCodec().decode(data)
        }
        #expect(
            error == .unknownField(
                path: expectedPath,
                field: expectedField
            )
        )
    }
}

@Test
func missingFieldsWrongTypesAndMalformedJSONAreDistinct() {
    let missingTags = Data(
        """
        {
          "formatIdentifier":"com.sxmbrowser.dataset-metadata",
          "formatVersion":1,
          "manualAssociations":[],
          "hiddenDATPaths":[],
          "spectrumAxisPreferences":[]
        }
        """.utf8
    )
    #expect(
        capturedTransferError {
            try DatasetMetadataTransferCodec().decode(missingTags)
        } == .missingField(path: "$", field: "tags")
    )

    let wrongType = transferJSON(tags: "{}")
    guard case let .typeMismatch(path, _) = capturedTransferError({
        try DatasetMetadataTransferCodec().decode(wrongType)
    }) else {
        Issue.record("Expected a type-mismatch error")
        return
    }
    #expect(path == "$.tags")

    guard case .malformedJSON = capturedTransferError({
        try DatasetMetadataTransferCodec().decode(
            Data(#"{"formatIdentifier":"unterminated"#.utf8)
        )
    }) else {
        Issue.record("Expected a malformed-JSON error")
        return
    }
}

@Test
func transferIdentifierAndVersionAreStrict() {
    #expect(
        capturedTransferError {
            try DatasetMetadataTransferCodec().decode(
                transferJSON(identifier: "other-format")
            )
        } == .invalidFormatIdentifier("other-format")
    )
    #expect(
        capturedTransferError {
            try DatasetMetadataTransferCodec().decode(
                transferJSON(version: "2")
            )
        } == .unsupportedFormatVersion(2)
    )

    guard case let .typeMismatch(path, _) = capturedTransferError({
        try DatasetMetadataTransferCodec().decode(
            transferJSON(version: #""1""#)
        )
    }) else {
        Issue.record("Expected a type-mismatch error")
        return
    }
    #expect(path == "$.formatVersion")
}

@Test
func tagUUIDRequiresLowercaseCanonicalForm() {
    let uppercase = caseSensitiveTransferTagID.uuidString
    let invalid = "not-a-uuid"
    let braced =
        "{\(caseSensitiveTransferTagID.uuidString.lowercased())}"

    let uppercaseError = capturedTransferError {
        try DatasetMetadataTransferCodec().decode(
            transferJSON(
                tags:
                    #"[{"id":"\#(uppercase)","name":"Keep","sxmPaths":[]}]"#
            )
        )
    }
    #expect(
        uppercaseError == .nonCanonicalUUID(
            path: "$.tags[0].id",
            value: uppercase
        )
    )

    #expect(
        capturedTransferError {
            try DatasetMetadataTransferCodec().decode(
                transferJSON(
                    tags:
                        #"[{"id":"\#(invalid)","name":"Keep","sxmPaths":[]}]"#
                )
            )
        } == .invalidUUID(path: "$.tags[0].id", value: invalid)
    )

    let bracedError = capturedTransferError {
        try DatasetMetadataTransferCodec().decode(
            transferJSON(
                tags:
                    #"[{"id":"\#(braced)","name":"Keep","sxmPaths":[]}]"#
            )
        )
    }
    #expect(
        bracedError == .invalidUUID(
            path: "$.tags[0].id",
            value: braced
        )
    )
}

@Test
func canonicalStringValuesAreRequiredInsteadOfSilentlyCleaned() {
    let tagID = transferTagID.uuidString.lowercased()
    let cases: [(Data, String)] = [
        (
            transferJSON(
                tags:
                    #"[{"id":"\#(tagID)","name":" Keep ","sxmPaths":[]}]"#
            ),
            "$.tags[0].name"
        ),
        (
            transferJSON(
                tags:
                    #"[{"id":"\#(tagID)","name":"Caf\u0065\u0301","sxmPaths":[]}]"#
            ),
            "$.tags[0].name"
        ),
        (
            transferJSON(
                tags:
                    #"[{"id":"\#(tagID)","name":"Keep","sxmPaths":["Caf\u0065\u0301.sxm"]}]"#
            ),
            "$.tags[0].sxmPaths[0]"
        ),
        (
            transferJSON(
                spectrumAxisPreferences:
                    #"[{"sxmPath":"a.sxm","kind":"bias","schemaFingerprint":"0123456789ABCDEF","xColumn":"X","yColumn":"Y"}]"#
            ),
            "$.spectrumAxisPreferences[0].schemaFingerprint"
        ),
        (
            transferJSON(
                spectrumAxisPreferences:
                    #"[{"sxmPath":"a.sxm","kind":"bias","schemaFingerprint":"0123456789abcdef","xColumn":" X ","yColumn":"Y"}]"#
            ),
            "$.spectrumAxisPreferences[0].xColumn"
        ),
        (
            transferJSON(
                spectrumAxisPreferences:
                    #"[{"sxmPath":"a.sxm","kind":"bias","schemaFingerprint":"0123456789abcdef","xColumn":"X","yColumn":"Caf\u0065\u0301"}]"#
            ),
            "$.spectrumAxisPreferences[0].yColumn"
        ),
    ]

    for (data, expectedPath) in cases {
        guard case let .nonCanonicalValue(path, _) =
            capturedTransferError({
                try DatasetMetadataTransferCodec().decode(data)
            })
        else {
            Issue.record(
                "Expected a non-canonical value at \(expectedPath)"
            )
            continue
        }
        #expect(path == expectedPath)
    }

    #expect(
        capturedTransferError {
            try DatasetMetadataTransferCodec().decode(
                transferJSON(
                    spectrumAxisPreferences:
                        #"[{"sxmPath":"a.sxm","kind":"unknown","schemaFingerprint":"0123456789abcdef","xColumn":"X","yColumn":"Y"}]"#
                )
            )
        } == .invalidValue(
            path: "$.spectrumAxisPreferences[0].kind",
            value: "unknown"
        )
    )
}

@Test
func invalidPathsAndAxisValuesRetainValidationDiagnostics() {
    let tagID = transferTagID.uuidString.lowercased()
    guard case let .invalidMetadata(path, error) =
        capturedTransferError({
            try DatasetMetadataTransferCodec().decode(
                transferJSON(
                    tags:
                        #"[{"id":"\#(tagID)","name":"Keep","sxmPaths":["../escape.sxm"]}]"#
                )
            )
        })
    else {
        Issue.record("Expected path validation failure")
        return
    }
    #expect(path == "$.tags[0].sxmPaths[0]")
    #expect(
        error == .invalidRelativePath(
            rawValue: "../escape.sxm",
            reason: .parentComponent
        )
    )

    guard case let .invalidMetadata(fingerprintPath, fingerprintError) =
        capturedTransferError({
            try DatasetMetadataTransferCodec().decode(
                transferJSON(
                    spectrumAxisPreferences:
                        #"[{"sxmPath":"a.sxm","kind":"bias","schemaFingerprint":"bad","xColumn":"X","yColumn":"Y"}]"#
                )
            )
        })
    else {
        Issue.record("Expected fingerprint validation failure")
        return
    }
    #expect(
        fingerprintPath
            == "$.spectrumAxisPreferences[0].schemaFingerprint"
    )
    #expect(fingerprintError == .invalidSchemaFingerprint("bad"))
}

@Test
func duplicateTagIDsNamesAndMembersAreRejected() {
    let firstID = transferTagID.uuidString.lowercased()
    let secondID = secondTransferTagID.uuidString.lowercased()
    let duplicateIDTags =
        #"[{"id":"\#(firstID)","name":"One","sxmPaths":[]},{"id":"\#(firstID)","name":"Two","sxmPaths":[]}]"#
    let duplicateNameTags =
        #"[{"id":"\#(firstID)","name":"Surface","sxmPaths":[]},{"id":"\#(secondID)","name":"sUrFaCe","sxmPaths":[]}]"#
    let duplicateMembers =
        #"[{"id":"\#(firstID)","name":"One","sxmPaths":["a.sxm","a.sxm"]}]"#

    for tags in [duplicateIDTags, duplicateNameTags, duplicateMembers] {
        guard case .duplicateEntry = capturedTransferError({
            try DatasetMetadataTransferCodec().decode(
                transferJSON(tags: tags)
            )
        }) else {
            Issue.record("Expected duplicate tag metadata to be rejected")
            continue
        }
    }
}

@Test
func duplicateAndConflictingAssociationsAreRejected() {
    let duplicate =
        #"[{"datPath":"a.dat","sxmPath":"a.sxm"},{"datPath":"a.dat","sxmPath":"a.sxm"}]"#
    let conflict =
        #"[{"datPath":"a.dat","sxmPath":"a.sxm"},{"datPath":"a.dat","sxmPath":"b.sxm"}]"#

    guard case .duplicateEntry = capturedTransferError({
        try DatasetMetadataTransferCodec().decode(
            transferJSON(manualAssociations: duplicate)
        )
    }) else {
        Issue.record("Expected duplicate association")
        return
    }
    guard case .conflictingEntry = capturedTransferError({
        try DatasetMetadataTransferCodec().decode(
            transferJSON(manualAssociations: conflict)
        )
    }) else {
        Issue.record("Expected conflicting association")
        return
    }
}

@Test
func duplicateHiddenPathsAndAxisPreferencesAreRejected() {
    guard case .duplicateEntry = capturedTransferError({
        try DatasetMetadataTransferCodec().decode(
            transferJSON(hiddenDATPaths: #"["a.dat","a.dat"]"#)
        )
    }) else {
        Issue.record("Expected duplicate hidden DAT path")
        return
    }

    let firstAxis =
        #"{"sxmPath":"a.sxm","kind":"bias","schemaFingerprint":"0123456789abcdef","xColumn":"X","yColumn":"Y"}"#
    let duplicateAxis = "[\(firstAxis),\(firstAxis)]"
    let conflictingAxis =
        #"[\#(firstAxis),{"sxmPath":"a.sxm","kind":"bias","schemaFingerprint":"0123456789abcdef","xColumn":"X","yColumn":"Other"}]"#

    guard case .duplicateEntry = capturedTransferError({
        try DatasetMetadataTransferCodec().decode(
            transferJSON(
                spectrumAxisPreferences: duplicateAxis
            )
        )
    }) else {
        Issue.record("Expected duplicate axis preference")
        return
    }
    guard case .conflictingEntry = capturedTransferError({
        try DatasetMetadataTransferCodec().decode(
            transferJSON(
                spectrumAxisPreferences: conflictingAxis
            )
        )
    }) else {
        Issue.record("Expected conflicting axis preference")
        return
    }
}

@Test
func dataAndEncodingByteLimitsAreEnforced() throws {
    let codec = DatasetMetadataTransferCodec()
    let limit = DatasetMetadataTransferCodec.maximumByteCount

    #expect(
        capturedTransferError {
            try codec.decode(Data())
        } == .emptyPayload
    )
    #expect(
        capturedTransferError {
            try codec.decode(Data(repeating: 0x20, count: limit + 1))
        } == .payloadTooLarge(actual: limit + 1, maximum: limit)
    )

    guard case .malformedJSON = capturedTransferError({
        try codec.decode(Data(repeating: 0x20, count: limit))
    }) else {
        Issue.record("The exact byte limit must reach JSON decoding")
        return
    }

    let oversizedTag = try DatasetTagV1(
        id: transferTagID,
        name: String(repeating: "a", count: limit)
    )
    let oversizedTransfer = try DatasetMetadataTransferV1(
        tags: [oversizedTag],
        manualAssociations: [],
        hiddenDATPaths: [],
        spectrumAxisPreferences: []
    )
    guard case let .payloadTooLarge(actual, maximum) =
        capturedTransferError({
            try codec.encode(oversizedTransfer)
        })
    else {
        Issue.record("Expected oversized encoding to be rejected")
        return
    }
    #expect(actual > limit)
    #expect(maximum == limit)
}

@Test
func boundedFileDecodeValidatesURLKindExistenceAndSize() throws {
    let codec = DatasetMetadataTransferCodec()
    let directory = try makeTemporaryTransferDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(
        capturedTransferError {
            try codec.decode(
                contentsOf: URL(string: "https://example.invalid/a.json")!
            )
        } == .unsupportedFileURL(
            URL(string: "https://example.invalid/a.json")!
        )
    )
    #expect(
        capturedTransferError {
            try codec.decode(contentsOf: directory)
        } == .notRegularFile(directory.standardizedFileURL)
    )

    let missing = directory.appendingPathComponent("missing.json")
    guard case let .fileReadFailed(fileURL, _) =
        capturedTransferError({
            try codec.decode(contentsOf: missing)
        })
    else {
        Issue.record("Expected missing-file read failure")
        return
    }
    #expect(fileURL == missing.standardizedFileURL)

    let empty = directory.appendingPathComponent("empty.json")
    try Data().write(to: empty)
    #expect(
        capturedTransferError {
            try codec.decode(contentsOf: empty)
        } == .emptyPayload
    )

    let oversized = directory.appendingPathComponent("oversized.json")
    let limit = DatasetMetadataTransferCodec.maximumByteCount
    try Data(repeating: 0x20, count: limit + 1).write(to: oversized)
    #expect(
        capturedTransferError {
            try codec.decode(contentsOf: oversized)
        } == .payloadTooLarge(actual: limit + 1, maximum: limit)
    )

    let valid = directory.appendingPathComponent("valid.json")
    let expected = try makeFullTransfer()
    try codec.encode(expected).write(to: valid)
    #expect(try codec.decode(contentsOf: valid) == expected)
}

@Test
func codecHasNoSharedEncoderOrDecoderState() async throws {
    let codec = DatasetMetadataTransferCodec()
    let transfer = try makeFullTransfer()
    let expected = try codec.encode(transfer)

    let results = try await withThrowingTaskGroup(
        of: Data.self,
        returning: [Data].self
    ) { group in
        for _ in 0..<50 {
            group.addTask {
                let encoded = try codec.encode(transfer)
                let decoded = try codec.decode(encoded)
                return try codec.encode(decoded)
            }
        }

        var collected: [Data] = []
        for try await data in group {
            collected.append(data)
        }
        return collected
    }

    #expect(results.count == 50)
    #expect(results.allSatisfy { $0 == expected })
}
