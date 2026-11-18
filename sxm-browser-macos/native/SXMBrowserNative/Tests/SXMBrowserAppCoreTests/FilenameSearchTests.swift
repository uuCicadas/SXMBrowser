import Foundation
import Testing
@testable import SXMBrowserAppCore

private let searchCandidates = [
    FilenameSearchCandidate(
        id: "first",
        sxmFilename: "Au1110419.sxm",
        associatedDATFilenames: ["BiasSweep_A.dat"]
    ),
    FilenameSearchCandidate(
        id: "second",
        sxmFilename: "Au1110420.sxm",
        associatedDATFilenames: ["CurrentCurve_B.dat"]
    ),
    FilenameSearchCandidate(
        id: "third",
        sxmFilename: "Reference.sxm",
        associatedDATFilenames: []
    ),
]

@Test
func filenameSearchPreservesScopeOrderAndMatchesSXMOrAssociatedDAT() {
    let all = FilenameSearchProjection(
        query: " \n ",
        candidates: searchCandidates
    )
    #expect(all.matchingIDs == ["first", "second", "third"])
    #expect(all.matchedCount == 3)
    #expect(all.scopedCount == 3)

    let sxm = FilenameSearchProjection(
        query: "AU1110420",
        candidates: searchCandidates
    )
    #expect(sxm.matchingIDs == ["second"])

    let dat = FilenameSearchProjection(
        query: "biassweep_a",
        candidates: searchCandidates
    )
    #expect(dat.matchingIDs == ["first"])

    let missing = FilenameSearchProjection(
        query: "unassociated.dat",
        candidates: searchCandidates
    )
    #expect(missing.matchingIDs.isEmpty)
}

@Test
func filenameSearchRequestGateRejectsLateDebouncedRequestsAndCancel() {
    var gate = FilenameSearchRequestGate()
    let first = gate.begin(
        query: "A",
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )
    let second = gate.begin(
        query: "Au",
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )

    #expect(!gate.accepts(first))
    #expect(gate.accepts(second))

    gate.cancel()
    #expect(!gate.accepts(second))
}
