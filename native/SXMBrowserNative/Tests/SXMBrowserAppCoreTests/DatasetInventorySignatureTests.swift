import Foundation
import Testing
@testable import SXMBrowserAppCore

private func inventoryStamp(
    _ path: String,
    byteCount: UInt64 = 100,
    modifiedAt: Date = Date(timeIntervalSinceReferenceDate: 200)
) throws -> DatasetInventoryFileStamp {
    try DatasetInventoryFileStamp(
        path: DatasetRelativePath(path),
        byteCount: byteCount,
        modifiedAt: modifiedAt
    )
}

@Test
func inventorySignatureCanonicalizesOrderAndUnicodePaths() throws {
    let signature = try DatasetInventorySignature(
        files: [
            inventoryStamp("z.dat"),
            inventoryStamp("Cafe\u{301}.sxm"),
            inventoryStamp("a.sxm"),
        ]
    )

    #expect(
        signature.files.map(\.path.rawValue)
            == ["Café.sxm", "a.sxm", "z.dat"]
    )
}

@Test
func inventorySignatureDetectsSizeAndModificationChanges() throws {
    let baseline = try DatasetInventorySignature(
        files: [inventoryStamp("a.sxm")]
    )
    let resized = try DatasetInventorySignature(
        files: [inventoryStamp("a.sxm", byteCount: 101)]
    )
    let modified = try DatasetInventorySignature(
        files: [
            inventoryStamp(
                "a.sxm",
                modifiedAt: Date(timeIntervalSinceReferenceDate: 201)
            ),
        ]
    )

    #expect(baseline != resized)
    #expect(baseline != modified)
}

@Test
func inventorySignatureRejectsUnsupportedNestedAndDuplicatePaths()
    throws
{
    #expect(throws: DatasetInventorySignatureError.self) {
        _ = try inventoryStamp("notes.txt")
    }
    #expect(throws: DatasetInventorySignatureError.self) {
        _ = try inventoryStamp("nested/a.sxm")
    }

    let duplicate = try inventoryStamp("a.sxm")
    #expect(throws: DatasetInventorySignatureError.self) {
        _ = try DatasetInventorySignature(
            files: [duplicate, duplicate]
        )
    }
    #expect(throws: DatasetInventorySignatureError.self) {
        _ = try inventoryStamp(
            "invalid.dat",
            modifiedAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )
    }
}
