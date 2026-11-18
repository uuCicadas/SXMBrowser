public struct FileDeletionPlan<ID: Hashable & Sendable>: Equatable, Sendable {
    public let targetIDs: [ID]

    public init(visibleIDs: [ID], selectedIDs: Set<ID>) {
        var seen: Set<ID> = []
        targetIDs = visibleIDs.filter {
            selectedIDs.contains($0) && seen.insert($0).inserted
        }
    }
}
