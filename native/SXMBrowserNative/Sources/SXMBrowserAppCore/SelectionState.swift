public struct SelectionState<ID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var primaryID: ID?
    public private(set) var selectedIDs: Set<ID>
    public private(set) var anchorID: ID?

    public init() {
        primaryID = nil
        selectedIDs = []
        anchorID = nil
    }

    public mutating func clear() {
        primaryID = nil
        selectedIDs.removeAll()
        anchorID = nil
    }

    public mutating func selectOnly(_ id: ID, in visibleIDs: [ID]) {
        guard visibleIDs.contains(id) else { return }
        primaryID = id
        selectedIDs = [id]
        anchorID = id
    }

    public mutating func toggle(_ id: ID, in visibleIDs: [ID]) {
        let visibleSet = Set(visibleIDs)
        guard visibleSet.contains(id) else { return }

        selectedIDs.formIntersection(visibleSet)
        if selectedIDs.remove(id) != nil {
            if selectedIDs.isEmpty {
                clear()
                return
            }
            if primaryID == id || primaryID.map({ !selectedIDs.contains($0) }) == true {
                primaryID = visibleIDs.first(where: selectedIDs.contains)
            }
            if anchorID == id || anchorID.map({ !visibleSet.contains($0) }) == true {
                anchorID = primaryID
            }
        } else {
            selectedIDs.insert(id)
            primaryID = id
            anchorID = id
        }
    }

    public mutating func selectRange(to id: ID, in visibleIDs: [ID]) {
        guard let targetIndex = visibleIDs.firstIndex(of: id) else { return }
        let resolvedAnchor = anchorID.flatMap(visibleIDs.firstIndex(of:))
            ?? primaryID.flatMap(visibleIDs.firstIndex(of:))
            ?? targetIndex
        let bounds = min(resolvedAnchor, targetIndex)...max(resolvedAnchor, targetIndex)
        let anchor = visibleIDs[resolvedAnchor]

        selectedIDs = Set(bounds.map { visibleIDs[$0] })
        primaryID = id
        anchorID = anchor
    }

    public mutating func selectAll(in visibleIDs: [ID]) {
        let visibleSet = Set(visibleIDs)
        guard !visibleSet.isEmpty else {
            clear()
            return
        }

        selectedIDs = visibleSet
        if primaryID.map({ !visibleSet.contains($0) }) != false {
            primaryID = visibleIDs.first
        }
        if anchorID.map({ !visibleSet.contains($0) }) != false {
            anchorID = primaryID
        }
    }

    public mutating func step(by delta: Int, in visibleIDs: [ID]) {
        guard delta != 0, !visibleIDs.isEmpty else { return }
        guard let primaryID else {
            selectOnly(visibleIDs[0], in: visibleIDs)
            return
        }
        guard let currentIndex = visibleIDs.firstIndex(of: primaryID) else {
            reconcile(with: visibleIDs, fallbackToFirst: true)
            return
        }

        let (targetIndex, overflowed) = currentIndex.addingReportingOverflow(delta)
        guard !overflowed, visibleIDs.indices.contains(targetIndex) else { return }
        selectOnly(visibleIDs[targetIndex], in: visibleIDs)
    }

    public func canStep(by delta: Int, in visibleIDs: [ID]) -> Bool {
        guard delta != 0,
              let primaryID,
              let currentIndex = visibleIDs.firstIndex(of: primaryID) else {
            return false
        }
        let (targetIndex, overflowed) = currentIndex.addingReportingOverflow(delta)
        return !overflowed && visibleIDs.indices.contains(targetIndex)
    }

    public mutating func reconcile(
        with visibleIDs: [ID],
        fallbackToFirst: Bool
    ) {
        let visibleSet = Set(visibleIDs)
        selectedIDs.formIntersection(visibleSet)

        if selectedIDs.isEmpty {
            if fallbackToFirst, let first = visibleIDs.first {
                selectOnly(first, in: visibleIDs)
            } else {
                clear()
            }
            return
        }

        if primaryID.map({ !selectedIDs.contains($0) }) != false {
            primaryID = visibleIDs.first(where: selectedIDs.contains)
        }
        if anchorID.map({ !visibleSet.contains($0) }) != false {
            anchorID = primaryID
        }
    }

    public mutating func reconcileAfterRemoval(
        removedIDs: Set<ID>,
        oldVisibleIDs: [ID],
        newVisibleIDs: [ID]
    ) {
        let previousPrimaryID = primaryID
        let newVisibleSet = Set(newVisibleIDs)
        selectedIDs.subtract(removedIDs)
        selectedIDs.formIntersection(newVisibleSet)

        if !selectedIDs.isEmpty {
            if primaryID.map({ !selectedIDs.contains($0) }) != false {
                primaryID = newVisibleIDs.first(where: selectedIDs.contains)
            }
            if anchorID.map({ removedIDs.contains($0) || !newVisibleSet.contains($0) }) != false {
                anchorID = primaryID
            }
            return
        }

        guard let previousPrimaryID,
              let oldIndex = oldVisibleIDs.firstIndex(of: previousPrimaryID) else {
            clear()
            return
        }

        let successor = oldVisibleIDs.dropFirst(oldIndex + 1)
            .first(where: newVisibleSet.contains)
        let predecessor = oldVisibleIDs[..<oldIndex].reversed()
            .first(where: newVisibleSet.contains)

        if let replacement = successor ?? predecessor {
            selectOnly(replacement, in: newVisibleIDs)
        } else {
            clear()
        }
    }
}
