using System;
using System.Collections.Generic;
using System.Linq;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public enum SpectrumAxis
{
    X,
    Y
}

public sealed record SpectrumAxisRuntimeGroup(
    string Id,
    Guid SxmId,
    SpectroscopyKind Kind,
    string ExperimentIdentity,
    string SchemaFingerprint,
    IReadOnlyList<string> AvailableColumns,
    string PreferredX,
    string PreferredY)
{
    public SpectrumAxisRuntimeGroup(SpectroscopyGroup group)
        : this(
            group.Id,
            group.SxmId,
            group.Kind,
            group.ExperimentIdentity,
            group.ColumnSchema.Fingerprint,
            group.AvailableColumns,
            group.XLabel,
            group.YLabel)
    {
    }
}

public abstract record SpectrumAxisPreferenceRestoreReason
{
    public sealed record MissingSxmPath : SpectrumAxisPreferenceRestoreReason;
    public sealed record GroupUnavailable : SpectrumAxisPreferenceRestoreReason;
    public sealed record ExperimentUnavailable(IReadOnlyList<string> AvailableIdentities) : SpectrumAxisPreferenceRestoreReason;
    public sealed record AmbiguousExperiment(IReadOnlyList<string> AvailableIdentities) : SpectrumAxisPreferenceRestoreReason;
    public sealed record IncompatibleSchema(IReadOnlyList<string> AvailableFingerprints) : SpectrumAxisPreferenceRestoreReason;
    public sealed record MissingColumn(SpectrumAxis Axis, string Column) : SpectrumAxisPreferenceRestoreReason;
    public sealed record AmbiguousColumn(SpectrumAxis Axis, string Column, IReadOnlyList<string> Matches) : SpectrumAxisPreferenceRestoreReason;
}

public sealed record SpectrumAxisPreferenceRestoreIssue(
    SpectrumAxisPreferenceKeyV1 Key,
    string? GroupId,
    SpectrumAxisPreferenceRestoreReason Reason)
{
    public string Description
    {
        get
        {
            string prefix = $"Axis preference {Key.StableIdentifier}";
            return Reason switch
            {
                SpectrumAxisPreferenceRestoreReason.MissingSxmPath =>
                    $"{prefix} refers to an SXM file that is not currently available.",
                SpectrumAxisPreferenceRestoreReason.GroupUnavailable =>
                    $"{prefix} has no compatible spectroscopy group in the current dataset.",
                SpectrumAxisPreferenceRestoreReason.ExperimentUnavailable e =>
                    $"{prefix} does not match the available experiment identities ({(e.AvailableIdentities.Count == 0 ? "none" : string.Join(", ", e.AvailableIdentities))}).",
                SpectrumAxisPreferenceRestoreReason.AmbiguousExperiment e =>
                    $"{prefix} is a legacy preference that matches multiple experiment identities ({string.Join(", ", e.AvailableIdentities)}); it was not applied.",
                SpectrumAxisPreferenceRestoreReason.IncompatibleSchema s =>
                    $"{prefix} does not match the available column schemas ({(s.AvailableFingerprints.Count == 0 ? "none" : string.Join(", ", s.AvailableFingerprints))}).",
                SpectrumAxisPreferenceRestoreReason.MissingColumn m =>
                    $"{prefix} cannot restore the {m.Axis.ToString().ToUpperInvariant()} column \u201C{m.Column}\u201D because it is missing.",
                SpectrumAxisPreferenceRestoreReason.AmbiguousColumn a =>
                    $"{prefix} cannot restore the {a.Axis.ToString().ToUpperInvariant()} column \u201C{a.Column}\u201D because it matches {string.Join(", ", a.Matches)}.",
                _ => prefix
            };
        }
    }
}

public sealed class SpectrumAxisPreferenceProjection
{
    public SpectroscopyAxisState AxisState { get; }
    public IReadOnlyList<SpectrumAxisPreferenceRestoreIssue> Issues { get; }
    public IReadOnlyList<SpectrumAxisPreferenceV1> RetainedPreferences { get; }

    public SpectrumAxisPreferenceProjection(
        IEnumerable<SpectrumAxisPreferenceV1> preferences,
        IEnumerable<SpectrumAxisRuntimeGroup> groups,
        DatasetPathIndex pathIndex)
    {
        var orderedGroups = groups.OrderBy(g => g.Id, StringComparer.Ordinal).ToList();
        var selections = new Dictionary<string, AxisSelection>(StringComparer.Ordinal);
        foreach (SpectrumAxisRuntimeGroup g in orderedGroups)
        {
            if (SafeDefaultSelection(g) is { } fallback)
            {
                selections[g.Id] = fallback;
            }
        }

        var groupByKey = new Dictionary<SpectrumAxisPreferenceKeyV1, SpectrumAxisRuntimeGroup>();
        foreach (SpectrumAxisRuntimeGroup g in orderedGroups)
        {
            if (pathIndex.SxmPath(g.SxmId) is not { } sxmPath) continue;
            try
            {
                var key = new SpectrumAxisPreferenceKeyV1(sxmPath, g.Kind, g.ExperimentIdentity, g.SchemaFingerprint);
                groupByKey.TryAdd(key, g);
            }
            catch
            {
            }
        }

        var orderedPrefs = preferences
            .OrderBy(p => p.Key.StableIdentifier, StringComparer.Ordinal)
            .ToList();
        var explicitKeys = new HashSet<SpectrumAxisPreferenceKeyV1>(
            orderedPrefs.Where(p => p.Key.ExperimentIdentity is not null).Select(p => p.Key));

        var restoreIssues = new List<SpectrumAxisPreferenceRestoreIssue>();
        var retainedByKey = new Dictionary<SpectrumAxisPreferenceKeyV1, SpectrumAxisPreferenceV1>();

        foreach (SpectrumAxisPreferenceV1 pref in orderedPrefs)
        {
            (SpectrumAxisRuntimeGroup? group, SpectrumAxisPreferenceKeyV1? resolvedKey, SpectrumAxisPreferenceRestoreIssue? issue) =
                ResolveRuntimeGroup(pref.Key, groupByKey, orderedGroups, pathIndex);

            if (group is null || resolvedKey is null)
            {
                restoreIssues.Add(issue ?? UnmatchedIssue(pref.Key, orderedGroups, pathIndex));
                retainedByKey[pref.Key] = pref;
                continue;
            }

            SpectrumAxisPreferenceV1 retained = resolvedKey.Equals(pref.Key)
                ? pref
                : new SpectrumAxisPreferenceV1(resolvedKey, pref.Selection);

            if (!explicitKeys.Contains(resolvedKey) || pref.Key.ExperimentIdentity is not null)
            {
                retainedByKey[resolvedKey] = retained;
            }

            if (pref.Key.ExperimentIdentity is null && explicitKeys.Contains(resolvedKey))
            {
                continue;
            }

            (AxisSelection? sel, List<SpectrumAxisPreferenceRestoreIssue> selIssues) =
                ResolveSelection(pref.Selection, group, pref.Key);
            if (selIssues.Count == 0 && sel is not null)
            {
                selections[group.Id] = sel;
            }
            else
            {
                restoreIssues.AddRange(selIssues);
            }
        }

        AxisState = new SpectroscopyAxisState(selections);
        Issues = restoreIssues;
        RetainedPreferences = retainedByKey.Values
            .OrderBy(p => p.Key.StableIdentifier, StringComparer.Ordinal)
            .ToArray();
    }

    public static SpectroscopyAxisState SafeDefaults(IEnumerable<SpectrumAxisRuntimeGroup> groups)
    {
        var selections = new Dictionary<string, AxisSelection>(StringComparer.Ordinal);
        foreach (SpectrumAxisRuntimeGroup g in groups.OrderBy(g => g.Id, StringComparer.Ordinal))
        {
            if (SafeDefaultSelection(g) is { } fallback)
            {
                selections[g.Id] = fallback;
            }
        }
        return new SpectroscopyAxisState(selections);
    }

    internal static AxisSelection? SafeDefaultSelection(SpectrumAxisRuntimeGroup group)
    {
        if (group.AvailableColumns.Count == 0) return null;
        string first = group.AvailableColumns[0];
        string xCol = ResolveColumn(group.PreferredX, group.AvailableColumns, out string? xUnique) == ColStatus.Unique
            ? xUnique!
            : first;
        string yCol = ResolveColumn(group.PreferredY, group.AvailableColumns, out string? yUnique) == ColStatus.Unique
            ? yUnique!
            : (group.AvailableColumns.Count > 1 ? group.AvailableColumns[1] : xCol);
        return new AxisSelection(xCol, yCol);
    }

    private enum ColStatus { Unique, Missing, Ambiguous }

    private static ColStatus ResolveColumn(
        string requested,
        IReadOnlyList<string> available,
        out string? resolved,
        out string[] matches)
    {
        var exact = available.Where(c => string.Equals(c, requested, StringComparison.Ordinal)).ToArray();
        if (exact.Length == 1)
        {
            resolved = exact[0];
            matches = exact;
            return ColStatus.Unique;
        }
        if (exact.Length > 1)
        {
            resolved = null;
            matches = exact;
            return ColStatus.Ambiguous;
        }

        string norm = SpectroscopyColumnSchema.Normalize(requested);
        var normMatches = available
            .Where(c => string.Equals(SpectroscopyColumnSchema.Normalize(c), norm, StringComparison.Ordinal))
            .ToArray();
        if (normMatches.Length == 1)
        {
            resolved = normMatches[0];
            matches = normMatches;
            return ColStatus.Unique;
        }
        if (normMatches.Length == 0)
        {
            resolved = null;
            matches = Array.Empty<string>();
            return ColStatus.Missing;
        }
        resolved = null;
        matches = normMatches;
        return ColStatus.Ambiguous;
    }

    private static ColStatus ResolveColumn(string requested, IReadOnlyList<string> available, out string? resolved)
        => ResolveColumn(requested, available, out resolved, out _);

    private static (AxisSelection?, List<SpectrumAxisPreferenceRestoreIssue>) ResolveSelection(
        AxisSelection selection,
        SpectrumAxisRuntimeGroup group,
        SpectrumAxisPreferenceKeyV1 key)
    {
        var issues = new List<SpectrumAxisPreferenceRestoreIssue>();
        string? xCol = RestoreCol(selection.XColumn, SpectrumAxis.X, group, key, issues);
        string? yCol = RestoreCol(selection.YColumn, SpectrumAxis.Y, group, key, issues);
        if (issues.Count > 0 || xCol is null || yCol is null)
        {
            return (null, issues);
        }
        return (new AxisSelection(xCol, yCol), issues);
    }

    private static string? RestoreCol(
        string column,
        SpectrumAxis axis,
        SpectrumAxisRuntimeGroup group,
        SpectrumAxisPreferenceKeyV1 key,
        List<SpectrumAxisPreferenceRestoreIssue> issues)
    {
        ColStatus status = ResolveColumn(column, group.AvailableColumns, out string? resolved, out string[] matches);
        switch (status)
        {
            case ColStatus.Unique:
                return resolved;
            case ColStatus.Missing:
                issues.Add(new SpectrumAxisPreferenceRestoreIssue(
                    key, group.Id, new SpectrumAxisPreferenceRestoreReason.MissingColumn(axis, column)));
                return null;
            default:
                issues.Add(new SpectrumAxisPreferenceRestoreIssue(
                    key, group.Id, new SpectrumAxisPreferenceRestoreReason.AmbiguousColumn(axis, column, matches)));
                return null;
        }
    }

    private static (SpectrumAxisRuntimeGroup?, SpectrumAxisPreferenceKeyV1?, SpectrumAxisPreferenceRestoreIssue?)
        ResolveRuntimeGroup(
            SpectrumAxisPreferenceKeyV1 key,
            Dictionary<SpectrumAxisPreferenceKeyV1, SpectrumAxisRuntimeGroup> exactGroups,
            List<SpectrumAxisRuntimeGroup> groups,
            DatasetPathIndex pathIndex)
    {
        if (key.ExperimentIdentity is not null)
        {
            if (exactGroups.TryGetValue(key, out SpectrumAxisRuntimeGroup? g))
            {
                return (g, key, null);
            }
            return (null, null, UnmatchedIssue(key, groups, pathIndex));
        }

        if (pathIndex.SxmId(key.SxmPath) is not { } sxmId)
        {
            return (null, null, new SpectrumAxisPreferenceRestoreIssue(
                key, null, new SpectrumAxisPreferenceRestoreReason.MissingSxmPath()));
        }

        var candidates = groups.Where(g =>
            g.SxmId == sxmId
            && g.Kind == key.Kind
            && string.Equals(g.SchemaFingerprint, key.SchemaFingerprint, StringComparison.Ordinal))
            .ToList();
        if (candidates.Count == 1)
        {
            var g = candidates[0];
            var upgradedKey = new SpectrumAxisPreferenceKeyV1(
                key.SxmPath, key.Kind, g.ExperimentIdentity, key.SchemaFingerprint);
            return (g, upgradedKey, null);
        }
        if (candidates.Count > 1)
        {
            string[] identities = candidates
                .Select(c => c.ExperimentIdentity)
                .Distinct(StringComparer.Ordinal)
                .OrderBy(s => s, StringComparer.Ordinal)
                .ToArray();
            return (null, null, new SpectrumAxisPreferenceRestoreIssue(
                key, null, new SpectrumAxisPreferenceRestoreReason.AmbiguousExperiment(identities)));
        }

        return (null, null, UnmatchedIssue(key, groups, pathIndex));
    }

    private static SpectrumAxisPreferenceRestoreIssue UnmatchedIssue(
        SpectrumAxisPreferenceKeyV1 key,
        List<SpectrumAxisRuntimeGroup> groups,
        DatasetPathIndex pathIndex)
    {
        if (pathIndex.SxmId(key.SxmPath) is not { } sxmId)
        {
            return new SpectrumAxisPreferenceRestoreIssue(
                key, null, new SpectrumAxisPreferenceRestoreReason.MissingSxmPath());
        }

        var matchingKind = groups.Where(g => g.SxmId == sxmId && g.Kind == key.Kind).ToList();
        if (matchingKind.Count == 0)
        {
            return new SpectrumAxisPreferenceRestoreIssue(
                key, null, new SpectrumAxisPreferenceRestoreReason.GroupUnavailable());
        }

        List<SpectrumAxisRuntimeGroup> matchingExp;
        if (key.ExperimentIdentity is { } expId)
        {
            matchingExp = matchingKind
                .Where(g => string.Equals(g.ExperimentIdentity, expId, StringComparison.Ordinal))
                .ToList();
            if (matchingExp.Count == 0)
            {
                string[] identities = matchingKind
                    .Select(g => g.ExperimentIdentity)
                    .Distinct(StringComparer.Ordinal)
                    .OrderBy(s => s, StringComparer.Ordinal)
                    .ToArray();
                return new SpectrumAxisPreferenceRestoreIssue(
                    key, null, new SpectrumAxisPreferenceRestoreReason.ExperimentUnavailable(identities));
            }
        }
        else
        {
            matchingExp = matchingKind;
        }

        string[] fps = matchingExp
            .Select(g => g.SchemaFingerprint)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(s => s, StringComparer.Ordinal)
            .ToArray();
        return new SpectrumAxisPreferenceRestoreIssue(
            key, null, new SpectrumAxisPreferenceRestoreReason.IncompatibleSchema(fps));
    }
}

public sealed class SpectrumAxisPreferenceUpdatePlan
{
    public SpectrumAxisPreferenceKeyV1 Key { get; }
    public string GroupId { get; }
    public AxisSelection Selection { get; }

    public SpectrumAxisPreferenceUpdatePlan(
        SpectrumAxisRuntimeGroup group,
        SpectrumAxis changingAxis,
        string toColumn,
        AxisSelection currentSelection,
        DatasetPathIndex pathIndex)
    {
        DatasetRelativePath sxmPath = pathIndex.SxmPath(group.SxmId)
            ?? throw new InvalidOperationException($"The SXM file {group.SxmId} is not in the active dataset.");

        AxisSelection candidate = changingAxis == SpectrumAxis.X
            ? new AxisSelection(toColumn, currentSelection.YColumn)
            : new AxisSelection(currentSelection.XColumn, toColumn);

        string resolvedX = ValidateCol(candidate.XColumn, SpectrumAxis.X, group);
        string resolvedY = ValidateCol(candidate.YColumn, SpectrumAxis.Y, group);

        Key = new SpectrumAxisPreferenceKeyV1(
            sxmPath, group.Kind, group.ExperimentIdentity, group.SchemaFingerprint);
        GroupId = group.Id;
        Selection = new AxisSelection(resolvedX, resolvedY);
    }

    public List<SpectrumAxisPreferenceV1> Applying(IEnumerable<SpectrumAxisPreferenceV1> existing)
    {
        var updated = existing.Where(p => !p.Key.Equals(Key)).ToList();
        updated.Add(new SpectrumAxisPreferenceV1(Key, Selection));
        updated.Sort((a, b) => string.CompareOrdinal(a.Key.StableIdentifier, b.Key.StableIdentifier));
        return updated;
    }

    private static string ValidateCol(string col, SpectrumAxis axis, SpectrumAxisRuntimeGroup group)
    {
        var exact = group.AvailableColumns.Where(c => string.Equals(c, col, StringComparison.Ordinal)).ToArray();
        if (exact.Length == 1) return exact[0];
        if (exact.Length > 1)
        {
            throw new InvalidOperationException(
                $"The {axis.ToString().ToUpperInvariant()} column \u201C{col}\u201D matches multiple columns: {string.Join(", ", exact)}.");
        }
        string norm = SpectroscopyColumnSchema.Normalize(col);
        var normMatches = group.AvailableColumns
            .Where(c => string.Equals(SpectroscopyColumnSchema.Normalize(c), norm, StringComparison.Ordinal))
            .ToArray();
        if (normMatches.Length == 1) return normMatches[0];
        if (normMatches.Length == 0)
        {
            throw new InvalidOperationException(
                $"The {axis.ToString().ToUpperInvariant()} column \u201C{col}\u201D is not available in this spectroscopy group.");
        }
        throw new InvalidOperationException(
            $"The {axis.ToString().ToUpperInvariant()} column \u201C{col}\u201D matches multiple columns: {string.Join(", ", normMatches)}.");
    }
}
