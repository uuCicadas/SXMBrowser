import Foundation
import Testing
@testable import SXMBrowserAppCore

@Test
func tagPresentationFiltersStaleStableIDs() throws {
    let firstID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    let secondID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
    let staleID = UUID(
        uuidString: "33333333-3333-3333-3333-333333333333"
    )!
    let tags = [
        try DatasetTagV1(id: firstID, name: "First"),
        try DatasetTagV1(id: secondID, name: "Second"),
    ]

    #expect(
        TagPresentationProjection.reconciledActiveTagID(
            secondID,
            tags: tags
        ) == secondID
    )
    #expect(
        TagPresentationProjection.reconciledActiveTagID(
            staleID,
            tags: tags
        ) == nil
    )
    #expect(
        TagPresentationProjection.filteredExpandedTagIDs(
            [firstID, staleID],
            tags: tags
        ) == [firstID]
    )
}

@Test
func emptyTagPresentationClearsActiveAndExpandedState() {
    let tagID = UUID()

    #expect(
        TagPresentationProjection.reconciledActiveTagID(
            tagID,
            tags: []
        ) == nil
    )
    #expect(
        TagPresentationProjection.filteredExpandedTagIDs(
            [tagID],
            tags: []
        ).isEmpty
    )
}

@Test
func deletingActiveTagChoosesOnlyItsOrderedSuccessor() throws {
    let firstID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    let secondID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
    let thirdID = UUID(
        uuidString: "33333333-3333-3333-3333-333333333333"
    )!
    let missingID = UUID(
        uuidString: "44444444-4444-4444-4444-444444444444"
    )!
    let tags = [
        try DatasetTagV1(id: firstID, name: "First"),
        try DatasetTagV1(id: secondID, name: "Second"),
        try DatasetTagV1(id: thirdID, name: "Third"),
    ]

    #expect(
        TagPresentationProjection.successorTagID(
            afterDeleting: firstID,
            from: tags
        ) == secondID
    )
    #expect(
        TagPresentationProjection.successorTagID(
            afterDeleting: secondID,
            from: tags
        ) == thirdID
    )
    #expect(
        TagPresentationProjection.successorTagID(
            afterDeleting: thirdID,
            from: tags
        ) == nil
    )
    #expect(
        TagPresentationProjection.successorTagID(
            afterDeleting: missingID,
            from: tags
        ) == nil
    )
}
