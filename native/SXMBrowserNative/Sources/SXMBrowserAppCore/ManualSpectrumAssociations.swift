import Foundation

public enum ManualSpectrumAssociationResolution: Equatable, Sendable {
    case automaticAllowed
    case manual(sxmID: UUID)
    case missingManualTarget(sxmPath: DatasetRelativePath)

    public var allowsAutomaticAssociation: Bool {
        if case .automaticAllowed = self {
            return true
        }
        return false
    }
}

public struct ManualSpectrumAssociationProjection: Equatable, Sendable {
    public let targetPathByDATPath: [
        DatasetRelativePath: DatasetRelativePath
    ]
    public let resolvedSXMIDByDATID: [UUID: UUID]
    public let missingTargetPathByDATID: [
        UUID: DatasetRelativePath
    ]

    private let pathIndex: DatasetPathIndex

    public init(
        associations: [DatasetManualAssociationV1],
        pathIndex: DatasetPathIndex,
        availableSXMIDs: Set<UUID>
    ) {
        var targets: [
            DatasetRelativePath: DatasetRelativePath
        ] = [:]
        for association in associations {
            targets[association.datPath] = association.sxmPath
        }

        var resolved: [UUID: UUID] = [:]
        var missing: [UUID: DatasetRelativePath] = [:]
        for (datID, datPath) in pathIndex.datPathByID {
            guard let sxmPath = targets[datPath] else { continue }
            if let sxmID = pathIndex.sxmID(for: sxmPath),
               availableSXMIDs.contains(sxmID) {
                resolved[datID] = sxmID
            } else {
                missing[datID] = sxmPath
            }
        }

        targetPathByDATPath = targets
        resolvedSXMIDByDATID = resolved
        missingTargetPathByDATID = missing
        self.pathIndex = pathIndex
    }

    public func resolution(
        forDATID datID: UUID
    ) -> ManualSpectrumAssociationResolution {
        if let sxmID = resolvedSXMIDByDATID[datID] {
            return .manual(sxmID: sxmID)
        }
        if let sxmPath = missingTargetPathByDATID[datID] {
            return .missingManualTarget(sxmPath: sxmPath)
        }
        guard let datPath = pathIndex.datPath(for: datID),
              let sxmPath = targetPathByDATPath[datPath] else {
            return .automaticAllowed
        }
        return .missingManualTarget(sxmPath: sxmPath)
    }
}

public enum ManualAssociationUpdatePlanError:
    Error, Equatable, Sendable
{
    case emptyDATSelection
    case DATNotIndexed(UUID)
    case SXMNotIndexed(UUID)
}

extension ManualAssociationUpdatePlanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyDATSelection:
            "No spectroscopy files were selected for association."
        case .DATNotIndexed(let id):
            "The spectroscopy file \(id.uuidString) is not in the "
                + "active dataset."
        case .SXMNotIndexed(let id):
            "The SXM file \(id.uuidString) is not in the active dataset."
        }
    }
}

public struct ManualAssociationUpdatePlan: Equatable, Sendable {
    public let datPaths: [DatasetRelativePath]
    public let sxmPath: DatasetRelativePath

    public init(
        datIDs: [UUID],
        targetSXMID: UUID,
        pathIndex: DatasetPathIndex
    ) throws {
        guard !datIDs.isEmpty else {
            throw ManualAssociationUpdatePlanError.emptyDATSelection
        }
        guard let targetPath = pathIndex.sxmPath(for: targetSXMID) else {
            throw ManualAssociationUpdatePlanError.SXMNotIndexed(
                targetSXMID
            )
        }

        var paths: Set<DatasetRelativePath> = []
        for id in datIDs {
            guard let path = pathIndex.datPath(for: id) else {
                throw ManualAssociationUpdatePlanError.DATNotIndexed(id)
            }
            paths.insert(path)
        }
        datPaths = paths.sorted { $0.rawValue < $1.rawValue }
        sxmPath = targetPath
    }

    public func applying(
        to existing: [DatasetManualAssociationV1]
    ) throws -> [DatasetManualAssociationV1] {
        let replacements = Set(datPaths)
        var updated = existing.filter {
            !replacements.contains($0.datPath)
        }
        for datPath in datPaths {
            updated.append(
                try DatasetManualAssociationV1(
                    datPath: datPath,
                    sxmPath: sxmPath
                )
            )
        }
        return updated.sorted { lhs, rhs in
            if lhs.datPath.rawValue == rhs.datPath.rawValue {
                return lhs.sxmPath.rawValue < rhs.sxmPath.rawValue
            }
            return lhs.datPath.rawValue < rhs.datPath.rawValue
        }
    }
}
