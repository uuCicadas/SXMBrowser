import Foundation

public enum TagDropPayloadError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedType(String)
    case invalidUUID

    public var errorDescription: String? {
        switch self {
        case .unsupportedType:
            "The dragged item is not an SXM Browser tag."
        case .invalidUUID:
            "The dragged tag identifier is invalid."
        }
    }
}

public struct TagDropPayload: Equatable, Sendable {
    public static let typeIdentifier = "com.sxmbrowser.tag-id"

    public let tagID: UUID

    public init(tagID: UUID) {
        self.tagID = tagID
    }

    public init(data: Data, typeIdentifier: String) throws {
        guard typeIdentifier == Self.typeIdentifier else {
            throw TagDropPayloadError.unsupportedType(typeIdentifier)
        }
        guard data.count == 36,
              let value = String(data: data, encoding: .utf8),
              let tagID = UUID(uuidString: value),
              value.lowercased() == tagID.uuidString.lowercased() else {
            throw TagDropPayloadError.invalidUUID
        }
        self.tagID = tagID
    }

    public var encodedData: Data {
        Data(tagID.uuidString.lowercased().utf8)
    }
}

public enum TagReorderPlanError: Error, Equatable, LocalizedError, Sendable {
    case sourceNotFound(UUID)
    case targetNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            "The dragged tag no longer exists."
        case .targetNotFound:
            "The destination tag no longer exists."
        }
    }
}

public enum TagReorderPlan: Equatable, Sendable {
    case noChange
    case move(sourceID: UUID, destinationIndex: Int)

    public static func make(
        sourceID: UUID,
        targetID: UUID,
        tags: [DatasetTagV1]
    ) throws -> Self {
        guard tags.contains(where: { $0.id == sourceID }) else {
            throw TagReorderPlanError.sourceNotFound(sourceID)
        }
        guard let targetIndex = tags.firstIndex(where: {
            $0.id == targetID
        }) else {
            throw TagReorderPlanError.targetNotFound(targetID)
        }
        guard sourceID != targetID else {
            return .noChange
        }
        return .move(
            sourceID: sourceID,
            destinationIndex: targetIndex
        )
    }
}
