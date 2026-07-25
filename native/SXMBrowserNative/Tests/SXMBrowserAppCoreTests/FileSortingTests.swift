import Foundation
import Testing
@testable import SXMBrowserAppCore

private func sortValue(
    _ identity: String,
    name: String,
    modified: TimeInterval,
    recorded: TimeInterval?
) -> FileSortValue {
    FileSortValue(
        identity: identity,
        filename: name,
        modifiedTime: Date(timeIntervalSince1970: modified),
        recordedTime: recorded.map(Date.init(timeIntervalSince1970:))
    )
}

@Test
func recordedTimeKeepsMissingValuesLastInBothDirections() {
    let values = [
        sortValue("missing", name: "Missing", modified: 0, recorded: nil),
        sortValue("early", name: "Early", modified: 0, recorded: 10),
        sortValue("late", name: "Late", modified: 0, recorded: 20),
    ]

    let ascending = values.sorted {
        FileSortComparator.orderedBefore(
            $0,
            $1,
            criterion: .recordedTime,
            ascending: true
        )
    }
    let descending = values.sorted {
        FileSortComparator.orderedBefore(
            $0,
            $1,
            criterion: .recordedTime,
            ascending: false
        )
    }

    #expect(ascending.map(\.identity) == ["early", "late", "missing"])
    #expect(descending.map(\.identity) == ["late", "early", "missing"])
}

@Test
func comparatorIsStrictForTies() {
    let a = sortValue("a", name: "same.sxm", modified: 10, recorded: 20)
    let b = sortValue("b", name: "same.sxm", modified: 10, recorded: 20)

    #expect(
        FileSortComparator.orderedBefore(
            a,
            b,
            criterion: .modifiedTime,
            ascending: false
        )
    )
    #expect(
        !FileSortComparator.orderedBefore(
            b,
            a,
            criterion: .modifiedTime,
            ascending: false
        )
    )
    #expect(
        !FileSortComparator.orderedBefore(
            a,
            a,
            criterion: .name,
            ascending: true
        )
    )
}
