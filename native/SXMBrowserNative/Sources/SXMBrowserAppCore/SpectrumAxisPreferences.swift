import Foundation
import SXMBrowserCore

public enum SpectrumAxis: String, Equatable, Sendable {
    case x
    case y
}

public struct SpectrumAxisRuntimeGroup: Equatable, Sendable {
    public let id: String
    public let sxmID: UUID
    public let kind: SpectroscopyKind
    public let experimentIdentity: String
    public let schemaFingerprint: String
    public let availableColumns: [String]
    public let preferredX: String
    public let preferredY: String

    public init(
        id: String,
        sxmID: UUID,
        kind: SpectroscopyKind,
        experimentIdentity: String? = nil,
        schemaFingerprint: String,
        availableColumns: [String],
        preferredX: String,
        preferredY: String
    ) {
        self.id = id
        self.sxmID = sxmID
        self.kind = kind
        self.experimentIdentity = SpectroscopyExperimentIdentity.make(
            experiment: experimentIdentity,
            fallbackKind: kind
        )
        self.schemaFingerprint = schemaFingerprint
        self.availableColumns = availableColumns
        self.preferredX = preferredX
        self.preferredY = preferredY
    }

    public init(_ group: SpectroscopyGroup) {
        self.init(
            id: group.id,
            sxmID: group.sxmID,
            kind: group.kind,
            experimentIdentity: group.experimentIdentity,
            schemaFingerprint: group.columnSchema.fingerprint,
            availableColumns: group.availableColumns,
            preferredX: group.xLabel,
            preferredY: group.yLabel
        )
    }
}

public enum SpectrumAxisPreferenceRestoreReason:
    Equatable, Sendable
{
    case missingSXMPath
    case groupUnavailable
    case experimentUnavailable(availableIdentities: [String])
    case ambiguousExperiment(availableIdentities: [String])
    case incompatibleSchema(availableFingerprints: [String])
    case missingColumn(axis: SpectrumAxis, column: String)
    case ambiguousColumn(
        axis: SpectrumAxis,
        column: String,
        matches: [String]
    )
}

public struct SpectrumAxisPreferenceRestoreIssue:
    Equatable, Sendable
{
    public let key: SpectrumAxisPreferenceKeyV1
    public let groupID: String?
    public let reason: SpectrumAxisPreferenceRestoreReason

    public init(
        key: SpectrumAxisPreferenceKeyV1,
        groupID: String?,
        reason: SpectrumAxisPreferenceRestoreReason
    ) {
        self.key = key
        self.groupID = groupID
        self.reason = reason
    }
}

extension SpectrumAxisPreferenceRestoreIssue: LocalizedError {
    public var errorDescription: String? {
        let prefix = "Axis preference \(key.stableIdentifier)"
        switch reason {
        case .missingSXMPath:
            return "\(prefix) refers to an SXM file that is not currently "
                + "available."
        case .groupUnavailable:
            return "\(prefix) has no compatible spectroscopy group in the "
                + "current dataset."
        case .experimentUnavailable(let available):
            let list = available.isEmpty
                ? "none"
                : available.joined(separator: ", ")
            return "\(prefix) does not match the available experiment "
                + "identities (\(list))."
        case .ambiguousExperiment(let available):
            return "\(prefix) is a legacy preference that matches multiple "
                + "experiment identities ("
                + available.joined(separator: ", ")
                + "); it was not applied."
        case .incompatibleSchema(let available):
            let list = available.isEmpty
                ? "none"
                : available.joined(separator: ", ")
            return "\(prefix) does not match the available column schemas "
                + "(\(list))."
        case .missingColumn(let axis, let column):
            return "\(prefix) cannot restore the \(axis.rawValue.uppercased()) "
                + "column “\(column)” because it is missing."
        case .ambiguousColumn(let axis, let column, let matches):
            return "\(prefix) cannot restore the \(axis.rawValue.uppercased()) "
                + "column “\(column)” because it matches "
                + "\(matches.joined(separator: ", "))."
        }
    }
}

public struct SpectrumAxisPreferenceProjection:
    Equatable, Sendable
{
    public let axisState: SpectroscopyAxisState
    public let issues: [SpectrumAxisPreferenceRestoreIssue]
    public let retainedPreferences: [SpectrumAxisPreferenceV1]

    public init(
        preferences: [SpectrumAxisPreferenceV1],
        groups: [SpectrumAxisRuntimeGroup],
        pathIndex: DatasetPathIndex
    ) {
        let orderedGroups = groups.sorted { $0.id < $1.id }
        var selections: [String: AxisSelection] = [:]
        for group in orderedGroups {
            if let fallback = safeDefaultSelection(for: group) {
                selections[group.id] = fallback
            }
        }

        var groupByKey: [
            SpectrumAxisPreferenceKeyV1: SpectrumAxisRuntimeGroup
        ] = [:]
        for group in orderedGroups {
            guard let sxmPath = pathIndex.sxmPath(for: group.sxmID),
                  let key = try? SpectrumAxisPreferenceKeyV1(
                      sxmPath: sxmPath,
                      kind: group.kind,
                      experimentIdentity: group.experimentIdentity,
                      schemaFingerprint: group.schemaFingerprint
                  ) else {
                continue
            }
            if groupByKey[key] == nil {
                groupByKey[key] = group
            }
        }

        let orderedPreferences = preferences.sorted {
            $0.key.stableIdentifier < $1.key.stableIdentifier
        }
        let explicitKeys = Set(
            orderedPreferences.compactMap { preference in
                preference.key.experimentIdentity == nil
                    ? nil
                    : preference.key
            }
        )
        var restoreIssues: [SpectrumAxisPreferenceRestoreIssue] = []
        var retainedByKey: [
            SpectrumAxisPreferenceKeyV1: SpectrumAxisPreferenceV1
        ] = [:]
        for preference in orderedPreferences {
            let resolution = resolvedRuntimeGroup(
                for: preference.key,
                exactGroups: groupByKey,
                groups: orderedGroups,
                pathIndex: pathIndex
            )
            guard let group = resolution.group,
                  let resolvedKey = resolution.resolvedKey else {
                restoreIssues.append(
                    resolution.issue
                        ?? unmatchedIssue(
                            for: preference.key,
                            groups: orderedGroups,
                            pathIndex: pathIndex
                        )
                )
                retainedByKey[preference.key] = preference
                continue
            }

            let retainedPreference: SpectrumAxisPreferenceV1
            if resolvedKey == preference.key {
                retainedPreference = preference
            } else {
                retainedPreference = (
                    try? SpectrumAxisPreferenceV1(
                        key: resolvedKey,
                        selection: preference.selection
                    )
                ) ?? preference
            }
            if !explicitKeys.contains(resolvedKey)
                || preference.key.experimentIdentity != nil {
                retainedByKey[resolvedKey] = retainedPreference
            }

            if preference.key.experimentIdentity == nil,
               explicitKeys.contains(resolvedKey) {
                continue
            }
            let resolved = resolveSelection(
                preference.selection,
                in: group,
                key: preference.key
            )
            if resolved.issues.isEmpty, let selection = resolved.selection {
                selections[group.id] = selection
            } else {
                restoreIssues.append(contentsOf: resolved.issues)
            }
        }

        axisState = SpectroscopyAxisState(
            selectionsByGroupID: selections
        )
        issues = restoreIssues
        retainedPreferences = retainedByKey.values.sorted {
            $0.key.stableIdentifier < $1.key.stableIdentifier
        }
    }

    public static func safeDefaults(
        for groups: [SpectrumAxisRuntimeGroup]
    ) -> SpectroscopyAxisState {
        var selections: [String: AxisSelection] = [:]
        for group in groups.sorted(by: { $0.id < $1.id }) {
            selections[group.id] = safeDefaultSelection(for: group)
        }
        return SpectroscopyAxisState(
            selectionsByGroupID: selections
        )
    }
}

public enum SpectrumAxisPreferenceUpdatePlanError:
    Error, Equatable, Sendable
{
    case SXMNotIndexed(UUID)
    case missingColumn(axis: SpectrumAxis, column: String)
    case ambiguousColumn(
        axis: SpectrumAxis,
        column: String,
        matches: [String]
    )
}

extension SpectrumAxisPreferenceUpdatePlanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .SXMNotIndexed(let id):
            "The SXM file \(id.uuidString) is not in the active dataset."
        case .missingColumn(let axis, let column):
            "The \(axis.rawValue.uppercased()) column “\(column)” is not "
                + "available in this spectroscopy group."
        case .ambiguousColumn(let axis, let column, let matches):
            "The \(axis.rawValue.uppercased()) column “\(column)” matches "
                + "multiple columns: \(matches.joined(separator: ", "))."
        }
    }
}

public struct SpectrumAxisPreferenceUpdatePlan:
    Equatable, Sendable
{
    public let key: SpectrumAxisPreferenceKeyV1
    public let groupID: String
    public let selection: AxisSelection

    public init(
        group: SpectrumAxisRuntimeGroup,
        changing axis: SpectrumAxis,
        to column: String,
        currentSelection: AxisSelection,
        pathIndex: DatasetPathIndex
    ) throws {
        guard let sxmPath = pathIndex.sxmPath(for: group.sxmID) else {
            throw SpectrumAxisPreferenceUpdatePlanError.SXMNotIndexed(
                group.sxmID
            )
        }
        let candidate: AxisSelection
        switch axis {
        case .x:
            candidate = AxisSelection(
                xColumn: column,
                yColumn: currentSelection.yColumn
            )
        case .y:
            candidate = AxisSelection(
                xColumn: currentSelection.xColumn,
                yColumn: column
            )
        }
        let resolved = try validatedSelection(candidate, in: group)

        key = try SpectrumAxisPreferenceKeyV1(
            sxmPath: sxmPath,
            kind: group.kind,
            experimentIdentity: group.experimentIdentity,
            schemaFingerprint: group.schemaFingerprint
        )
        groupID = group.id
        selection = resolved
    }

    public func applying(
        to existing: [SpectrumAxisPreferenceV1]
    ) throws -> [SpectrumAxisPreferenceV1] {
        var updated = existing.filter { $0.key != key }
        updated.append(
            try SpectrumAxisPreferenceV1(
                key: key,
                selection: selection
            )
        )
        return updated.sorted {
            $0.key.stableIdentifier < $1.key.stableIdentifier
        }
    }
}

private enum ColumnResolution {
    case unique(String)
    case missing
    case ambiguous([String])
}

private func resolveColumn(
    _ requested: String,
    in availableColumns: [String]
) -> ColumnResolution {
    let exactMatches = availableColumns.filter { $0 == requested }
    if exactMatches.count == 1 {
        return .unique(exactMatches[0])
    }
    if exactMatches.count > 1 {
        return .ambiguous(exactMatches)
    }

    let normalized = SpectroscopyColumnSchema.normalize(requested)
    let normalizedMatches = availableColumns.filter {
        SpectroscopyColumnSchema.normalize($0) == normalized
    }
    switch normalizedMatches.count {
    case 0:
        return .missing
    case 1:
        return .unique(normalizedMatches[0])
    default:
        return .ambiguous(normalizedMatches)
    }
}

private func safeDefaultSelection(
    for group: SpectrumAxisRuntimeGroup
) -> AxisSelection? {
    guard let first = group.availableColumns.first else { return nil }
    let xColumn: String
    if case .unique(let resolved) = resolveColumn(
        group.preferredX,
        in: group.availableColumns
    ) {
        xColumn = resolved
    } else {
        xColumn = first
    }

    let yColumn: String
    if case .unique(let resolved) = resolveColumn(
        group.preferredY,
        in: group.availableColumns
    ) {
        yColumn = resolved
    } else {
        yColumn = group.availableColumns.dropFirst().first ?? xColumn
    }
    return AxisSelection(xColumn: xColumn, yColumn: yColumn)
}

private func resolveSelection(
    _ selection: AxisSelection,
    in group: SpectrumAxisRuntimeGroup,
    key: SpectrumAxisPreferenceKeyV1
) -> (
    selection: AxisSelection?,
    issues: [SpectrumAxisPreferenceRestoreIssue]
) {
    var issues: [SpectrumAxisPreferenceRestoreIssue] = []
    let xColumn = restoredColumn(
        selection.xColumn,
        axis: .x,
        group: group,
        key: key,
        issues: &issues
    )
    let yColumn = restoredColumn(
        selection.yColumn,
        axis: .y,
        group: group,
        key: key,
        issues: &issues
    )
    guard issues.isEmpty, let xColumn, let yColumn else {
        return (nil, issues)
    }
    return (
        AxisSelection(xColumn: xColumn, yColumn: yColumn),
        []
    )
}

private func restoredColumn(
    _ column: String,
    axis: SpectrumAxis,
    group: SpectrumAxisRuntimeGroup,
    key: SpectrumAxisPreferenceKeyV1,
    issues: inout [SpectrumAxisPreferenceRestoreIssue]
) -> String? {
    switch resolveColumn(column, in: group.availableColumns) {
    case .unique(let resolved):
        return resolved
    case .missing:
        issues.append(
            SpectrumAxisPreferenceRestoreIssue(
                key: key,
                groupID: group.id,
                reason: .missingColumn(axis: axis, column: column)
            )
        )
    case .ambiguous(let matches):
        issues.append(
            SpectrumAxisPreferenceRestoreIssue(
                key: key,
                groupID: group.id,
                reason: .ambiguousColumn(
                    axis: axis,
                    column: column,
                    matches: matches
                )
            )
        )
    }
    return nil
}

private struct RuntimeGroupResolution {
    let group: SpectrumAxisRuntimeGroup?
    let resolvedKey: SpectrumAxisPreferenceKeyV1?
    let issue: SpectrumAxisPreferenceRestoreIssue?
}

private func resolvedRuntimeGroup(
    for key: SpectrumAxisPreferenceKeyV1,
    exactGroups: [
        SpectrumAxisPreferenceKeyV1: SpectrumAxisRuntimeGroup
    ],
    groups: [SpectrumAxisRuntimeGroup],
    pathIndex: DatasetPathIndex
) -> RuntimeGroupResolution {
    if key.experimentIdentity != nil {
        if let group = exactGroups[key] {
            return RuntimeGroupResolution(
                group: group,
                resolvedKey: key,
                issue: nil
            )
        }
        return RuntimeGroupResolution(
            group: nil,
            resolvedKey: nil,
            issue: unmatchedIssue(
                for: key,
                groups: groups,
                pathIndex: pathIndex
            )
        )
    }

    guard let sxmID = pathIndex.sxmID(for: key.sxmPath) else {
        return RuntimeGroupResolution(
            group: nil,
            resolvedKey: nil,
            issue: SpectrumAxisPreferenceRestoreIssue(
                key: key,
                groupID: nil,
                reason: .missingSXMPath
            )
        )
    }
    let candidates = groups.filter {
        $0.sxmID == sxmID
            && $0.kind.rawValue == key.kind.rawValue
            && $0.schemaFingerprint == key.schemaFingerprint
    }
    guard candidates.count == 1, let group = candidates.first else {
        if candidates.count > 1 {
            let identities = Array(
                Set(candidates.map(\.experimentIdentity))
            ).sorted()
            return RuntimeGroupResolution(
                group: nil,
                resolvedKey: nil,
                issue: SpectrumAxisPreferenceRestoreIssue(
                    key: key,
                    groupID: nil,
                    reason: .ambiguousExperiment(
                        availableIdentities: identities
                    )
                )
            )
        }
        return RuntimeGroupResolution(
            group: nil,
            resolvedKey: nil,
            issue: unmatchedIssue(
                for: key,
                groups: groups,
                pathIndex: pathIndex
            )
        )
    }

    let upgradedKey = try? SpectrumAxisPreferenceKeyV1(
        sxmPath: key.sxmPath,
        kind: key.kind,
        experimentIdentity: group.experimentIdentity,
        schemaFingerprint: key.schemaFingerprint
    )
    return RuntimeGroupResolution(
        group: group,
        resolvedKey: upgradedKey,
        issue: nil
    )
}

private func unmatchedIssue(
    for key: SpectrumAxisPreferenceKeyV1,
    groups: [SpectrumAxisRuntimeGroup],
    pathIndex: DatasetPathIndex
) -> SpectrumAxisPreferenceRestoreIssue {
    guard let sxmID = pathIndex.sxmID(for: key.sxmPath) else {
        return SpectrumAxisPreferenceRestoreIssue(
            key: key,
            groupID: nil,
            reason: .missingSXMPath
        )
    }
    let matchingKind = groups.filter {
        $0.sxmID == sxmID && $0.kind.rawValue == key.kind.rawValue
    }
    guard !matchingKind.isEmpty else {
        return SpectrumAxisPreferenceRestoreIssue(
            key: key,
            groupID: nil,
            reason: .groupUnavailable
        )
    }
    let matchingExperiment: [SpectrumAxisRuntimeGroup]
    if let experimentIdentity = key.experimentIdentity {
        matchingExperiment = matchingKind.filter {
            $0.experimentIdentity == experimentIdentity
        }
        if matchingExperiment.isEmpty {
            let identities = Array(
                Set(matchingKind.map(\.experimentIdentity))
            ).sorted()
            return SpectrumAxisPreferenceRestoreIssue(
                key: key,
                groupID: nil,
                reason: .experimentUnavailable(
                    availableIdentities: identities
                )
            )
        }
    } else {
        matchingExperiment = matchingKind
    }
    let fingerprints = Array(
        Set(matchingExperiment.map(\.schemaFingerprint))
    ).sorted()
    return SpectrumAxisPreferenceRestoreIssue(
        key: key,
        groupID: nil,
        reason: .incompatibleSchema(
            availableFingerprints: fingerprints
        )
    )
}

private func validatedSelection(
    _ selection: AxisSelection,
    in group: SpectrumAxisRuntimeGroup
) throws -> AxisSelection {
    let xColumn = try updatedColumn(
        selection.xColumn,
        axis: .x,
        group: group
    )
    let yColumn = try updatedColumn(
        selection.yColumn,
        axis: .y,
        group: group
    )
    return AxisSelection(xColumn: xColumn, yColumn: yColumn)
}

private func updatedColumn(
    _ column: String,
    axis: SpectrumAxis,
    group: SpectrumAxisRuntimeGroup
) throws -> String {
    switch resolveColumn(column, in: group.availableColumns) {
    case .unique(let resolved):
        return resolved
    case .missing:
        throw SpectrumAxisPreferenceUpdatePlanError.missingColumn(
            axis: axis,
            column: column
        )
    case .ambiguous(let matches):
        throw SpectrumAxisPreferenceUpdatePlanError.ambiguousColumn(
            axis: axis,
            column: column,
            matches: matches
        )
    }
}
