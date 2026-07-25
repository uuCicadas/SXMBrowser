import Foundation

public struct HiddenSpectrumProjection: Equatable, Sendable {
    public let persistedDATPaths: [DatasetRelativePath]
    public let hiddenDATIDs: Set<UUID>
    public let missingDATPaths: [DatasetRelativePath]

    public init(
        hiddenDATPaths: [DatasetRelativePath],
        pathIndex: DatasetPathIndex
    ) {
        let persisted = Array(Set(hiddenDATPaths)).sorted()
        var hiddenIDs: Set<UUID> = []
        var missingPaths: [DatasetRelativePath] = []

        for path in persisted {
            if let id = pathIndex.datID(for: path) {
                hiddenIDs.insert(id)
            } else {
                missingPaths.append(path)
            }
        }

        persistedDATPaths = persisted
        hiddenDATIDs = hiddenIDs
        missingDATPaths = missingPaths
    }
}

public enum HiddenSpectrumUpdatePlanError:
    Error, Equatable, Sendable
{
    case DATNotIndexed(UUID)
}

extension HiddenSpectrumUpdatePlanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .DATNotIndexed(let id):
            "The spectroscopy file \(id.uuidString) is not in the "
                + "active dataset."
        }
    }
}

public struct HiddenSpectrumUpdatePlan: Equatable, Sendable {
    public let datPath: DatasetRelativePath
    public let visible: Bool

    public init(
        datID: UUID,
        visible: Bool,
        pathIndex: DatasetPathIndex
    ) throws {
        guard let path = pathIndex.datPath(for: datID) else {
            throw HiddenSpectrumUpdatePlanError.DATNotIndexed(datID)
        }
        datPath = path
        self.visible = visible
    }

    public func applying(
        to existing: [DatasetRelativePath]
    ) throws -> [DatasetRelativePath] {
        var updated = Set(
            try existing.map { try $0.validated(for: .dat) }
        )
        if visible {
            updated.remove(datPath)
        } else {
            updated.insert(datPath)
        }
        return updated.sorted()
    }
}
