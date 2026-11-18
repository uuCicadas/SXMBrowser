import Foundation
import Testing
@testable import SXMBrowserAppCore

private let firstTagID = UUID(
    uuidString: "11111111-1111-1111-1111-111111111111"
)!
private let secondTagID = UUID(
    uuidString: "22222222-2222-2222-2222-222222222222"
)!
private let thirdTagID = UUID(
    uuidString: "33333333-3333-3333-3333-333333333333"
)!

private func reorderTags() throws -> [DatasetTagV1] {
    [
        try DatasetTagV1(id: firstTagID, name: "First"),
        try DatasetTagV1(id: secondTagID, name: "Second"),
        try DatasetTagV1(id: thirdTagID, name: "Third"),
    ]
}

@Test
func tagReorderPlanMovesFirstToLastAndLastToFirst() throws {
    let tags = try reorderTags()

    #expect(
        try TagReorderPlan.make(
            sourceID: firstTagID,
            targetID: thirdTagID,
            tags: tags
        ) == .move(
            sourceID: firstTagID,
            destinationIndex: 2
        )
    )
    #expect(
        try TagReorderPlan.make(
            sourceID: thirdTagID,
            targetID: firstTagID,
            tags: tags
        ) == .move(
            sourceID: thirdTagID,
            destinationIndex: 0
        )
    )
}

@Test
func tagReorderPlanTreatsSameTagAsNoChange() throws {
    #expect(
        try TagReorderPlan.make(
            sourceID: secondTagID,
            targetID: secondTagID,
            tags: reorderTags()
        ) == .noChange
    )
}

@Test
func tagReorderPlanRejectsMissingSourceAndTarget() throws {
    let missingID = UUID(
        uuidString: "44444444-4444-4444-4444-444444444444"
    )!
    let tags = try reorderTags()

    #expect(throws: TagReorderPlanError.sourceNotFound(missingID)) {
        try TagReorderPlan.make(
            sourceID: missingID,
            targetID: firstTagID,
            tags: tags
        )
    }
    #expect(throws: TagReorderPlanError.targetNotFound(missingID)) {
        try TagReorderPlan.make(
            sourceID: firstTagID,
            targetID: missingID,
            tags: tags
        )
    }
}

@Test
func tagDropPayloadRoundTripsAndRejectsWrongTypeOrInvalidUUID() throws {
    let payload = TagDropPayload(tagID: secondTagID)
    #expect(
        try TagDropPayload(
            data: payload.encodedData,
            typeIdentifier: TagDropPayload.typeIdentifier
        ) == payload
    )

    #expect(throws: TagDropPayloadError.unsupportedType("public.text")) {
        try TagDropPayload(
            data: payload.encodedData,
            typeIdentifier: "public.text"
        )
    }
    #expect(throws: TagDropPayloadError.invalidUUID) {
        try TagDropPayload(
            data: Data("not-a-valid-uuid".utf8),
            typeIdentifier: TagDropPayload.typeIdentifier
        )
    }
}
