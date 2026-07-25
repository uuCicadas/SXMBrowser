public enum SelectionActionPlacement: Equatable, Sendable {
    case none
    case overflow
    case actionBar
}

public struct SelectionActionPresentation<
    ID: Hashable & Sendable
>: Equatable, Sendable {
    public let orderedIDs: [ID]
    public let placement: SelectionActionPlacement

    public init(
        visibleIDs: [ID],
        selectedIDs: Set<ID>
    ) {
        orderedIDs = FileDeletionPlan(
            visibleIDs: visibleIDs,
            selectedIDs: selectedIDs
        ).targetIDs
        switch orderedIDs.count {
        case 0:
            placement = .none
        case 1:
            placement = .overflow
        default:
            placement = .actionBar
        }
    }
}
