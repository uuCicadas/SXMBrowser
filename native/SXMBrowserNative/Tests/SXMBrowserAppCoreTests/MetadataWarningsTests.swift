import Testing
@testable import SXMBrowserAppCore

@Test
func metadataWarningsNormalizeNewlinesWhitespaceAndUnicode() {
    var warnings = MetadataWarningCollection()

    let appendedMultiline =
        warnings.append("  First\r\nsecond\rthird  ")
    #expect(appendedMultiline)
    #expect(warnings.messages == ["First\nsecond\nthird"])
    let appendedDecomposed = warnings.append("Cafe\u{301}")
    #expect(appendedDecomposed)
    let appendedPrecomposed = warnings.append("Café")
    #expect(!appendedPrecomposed)
    #expect(warnings.messages == ["First\nsecond\nthird", "Café"])
}

@Test
func metadataWarningsIgnoreEmptyAndDeduplicateInFirstSeenOrder() {
    var warnings = MetadataWarningCollection()

    let appendedNil = warnings.append(nil)
    #expect(!appendedNil)
    let appendedWhitespace = warnings.append(" \r\n\t ")
    #expect(!appendedWhitespace)
    let appendedA = warnings.append("A")
    #expect(appendedA)
    let appendedB = warnings.append("B")
    #expect(appendedB)
    let appendedDuplicateA = warnings.append("A")
    #expect(!appendedDuplicateA)
    let appendedLowercaseA = warnings.append("a")
    #expect(appendedLowercaseA)
    #expect(warnings.messages == ["A", "B", "a"])
    #expect(warnings.detailText == "A\n\nB\n\na")
}

@Test
func metadataWarningPresentationDismissesUntilNewContentOrReset() {
    var presentation = MetadataWarningPresentationState()

    #expect(!presentation.isPresented)
    let appendedA = presentation.append("A")
    #expect(appendedA)
    #expect(presentation.isPresented)

    presentation.dismiss()
    #expect(presentation.isDismissed)
    #expect(!presentation.isPresented)
    let appendedDuplicateA = presentation.append("A")
    #expect(!appendedDuplicateA)
    #expect(!presentation.isPresented)

    let appendedB = presentation.append("B")
    #expect(appendedB)
    #expect(!presentation.isDismissed)
    #expect(presentation.isPresented)
    #expect(presentation.collection.messages == ["A", "B"])

    presentation.reset()
    #expect(presentation.collection.isEmpty)
    #expect(!presentation.isDismissed)
    #expect(!presentation.isPresented)

    presentation.reset(with: " Initial ")
    #expect(presentation.collection.messages == ["Initial"])
    #expect(presentation.isPresented)
}
