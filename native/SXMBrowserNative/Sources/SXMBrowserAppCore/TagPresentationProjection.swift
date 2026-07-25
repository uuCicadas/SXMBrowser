import Foundation

public enum TagPresentationProjection {
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
