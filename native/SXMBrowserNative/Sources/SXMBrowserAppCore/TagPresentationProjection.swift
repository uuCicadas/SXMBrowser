import Foundation

public enum TagPresentationProjection {
    public static func successorTagID(
        afterDeleting tagID: UUID,
        from tags: [DatasetTagV1]
    ) -> UUID? {
        guard let deletedIndex = tags.firstIndex(where: {
            $0.id == tagID
        }) else {
            return nil
        }
        let successorIndex = tags.index(after: deletedIndex)
        guard tags.indices.contains(successorIndex) else {
            return nil
        }
        return tags[successorIndex].id
    }

    public static func reconciledActiveTagID(
        _ activeTagID: UUID?,
        tags: [DatasetTagV1]
    ) -> UUID? {
        guard let activeTagID,
              tags.contains(where: { $0.id == activeTagID }) else {
            return nil
        }
        return activeTagID
    }

    public static func filteredExpandedTagIDs(
        _ expandedTagIDs: Set<UUID>,
        tags: [DatasetTagV1]
    ) -> Set<UUID> {
        let validIDs = Set(tags.map(\.id))
        return expandedTagIDs.intersection(validIDs)
    }
}
