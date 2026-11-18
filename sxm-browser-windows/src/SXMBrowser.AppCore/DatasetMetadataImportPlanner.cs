using System;
using System.Collections.Generic;
using System.Linq;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public sealed record DatasetMetadataImportDatFile(
    DatasetRelativePath Path,
    SpectroscopyKind Kind,
    string? Experiment,
    string ExperimentIdentity,
    string SchemaFingerprint,
    IReadOnlyList<string> Columns,
    DatasetRelativePath? AutomaticParentSxmPath)
{
    public DatasetMetadataImportDatFile(
        DatasetRelativePath path,
        SpectroscopyKind kind,
        string? experiment,
        string schemaFingerprint,
        IReadOnlyList<string> columns,
        DatasetRelativePath? automaticParentSxmPath)
        : this(
            path,
            kind,
            experiment,
            SpectroscopyExperimentIdentity.Make(experiment, kind),
            schemaFingerprint,
            columns,
            automaticParentSxmPath)
    {
    }
}

public sealed class DatasetMetadataImportInventory : IEquatable<DatasetMetadataImportInventory>
{
    public Guid RevisionId { get; }
    public Guid SessionId { get; }
    public Guid DatasetId { get; }
    public IReadOnlyList<DatasetRelativePath> SxmPaths { get; }
    public IReadOnlyList<DatasetMetadataImportDatFile> DatFiles { get; }

    public DatasetMetadataImportInventory(
        Guid revisionId,
        Guid sessionId,
        Guid datasetId,
        IEnumerable<DatasetRelativePath> sxmPaths,
        IEnumerable<DatasetMetadataImportDatFile> datFiles)
    {
        var seenSxm = new HashSet<DatasetRelativePath>();
        var sxmList = new List<DatasetRelativePath>();
        foreach (DatasetRelativePath p in sxmPaths)
        {
            p.Validated(DatasetFileKind.Sxm);
            if (!seenSxm.Add(p))
            {
                throw new InvalidOperationException($"SXM inventory path \u201C{p.RawValue}\u201D occurs more than once.");
            }
            sxmList.Add(p);
        }

        var seenDat = new HashSet<DatasetRelativePath>();
        var datList = new List<DatasetMetadataImportDatFile>();
        foreach (DatasetMetadataImportDatFile file in datFiles)
        {
            file.Path.Validated(DatasetFileKind.Dat);
            if (!seenDat.Add(file.Path))
            {
                throw new InvalidOperationException($"DAT inventory path \u201C{file.Path.RawValue}\u201D occurs more than once.");
            }
            if (file.AutomaticParentSxmPath is { } parent)
            {
                parent.Validated(DatasetFileKind.Sxm);
                if (!seenSxm.Contains(parent))
                {
                    throw new InvalidOperationException(
                        $"DAT file \u201C{file.Path.RawValue}\u201D refers to missing automatic parent \u201C{parent.RawValue}\u201D.");
                }
            }

            string expectedFp = new SpectroscopyColumnSchema(file.Columns).Fingerprint;
            if (!string.Equals(file.SchemaFingerprint, expectedFp, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    $"DAT file \u201C{file.Path.RawValue}\u201D has schema fingerprint \u201C{file.SchemaFingerprint}\u201D; expected \u201C{expectedFp}\u201D.");
            }

            var colsByNorm = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            foreach (string col in file.Columns)
            {
                string norm = SpectroscopyColumnSchema.Normalize(col);
                if (!colsByNorm.TryGetValue(norm, out List<string>? bucket))
                {
                    bucket = [];
                    colsByNorm[norm] = bucket;
                }
                bucket.Add(col);
            }
            var ambiguous = colsByNorm.Where(kv => kv.Value.Count > 1)
                .OrderBy(kv => kv.Key, StringComparer.Ordinal)
                .FirstOrDefault();
            if (ambiguous.Key is not null)
            {
                throw new InvalidOperationException(
                    $"DAT file \u201C{file.Path.RawValue}\u201D has ambiguous normalized column \u201C{ambiguous.Key}\u201D: {string.Join(", ", ambiguous.Value.OrderBy(c => c, StringComparer.Ordinal))}");
            }

            datList.Add(file);
        }

        RevisionId = revisionId;
        SessionId = sessionId;
        DatasetId = datasetId;
        SxmPaths = sxmList.OrderBy(p => p).ToArray();
        DatFiles = datList.OrderBy(f => f.Path).ToArray();
    }

    public bool Equals(DatasetMetadataImportInventory? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return RevisionId == other.RevisionId
            && SessionId == other.SessionId
            && DatasetId == other.DatasetId
            && SxmPaths.SequenceEqual(other.SxmPaths)
            && DatFiles.Count == other.DatFiles.Count
            && DatFiles.Zip(other.DatFiles).All(pair =>
                pair.First.Path.Equals(pair.Second.Path)
                && pair.First.Kind == pair.Second.Kind
                && string.Equals(pair.First.ExperimentIdentity, pair.Second.ExperimentIdentity, StringComparison.Ordinal)
                && string.Equals(pair.First.SchemaFingerprint, pair.Second.SchemaFingerprint, StringComparison.Ordinal)
                && pair.First.Columns.SequenceEqual(pair.Second.Columns, StringComparer.Ordinal)
                && Equals(pair.First.AutomaticParentSxmPath, pair.Second.AutomaticParentSxmPath));
    }

    public override bool Equals(object? obj) => Equals(obj as DatasetMetadataImportInventory);
    public override int GetHashCode() => HashCode.Combine(RevisionId, SessionId, DatasetId);
}

public enum DatasetMetadataImportConflictPolicy
{
    KeepDestination,
    UseImported,
    RequireDecision
}

public sealed record DatasetMetadataImportPolicy(
    DatasetMetadataImportConflictPolicy TagIdentity = DatasetMetadataImportConflictPolicy.RequireDecision,
    DatasetMetadataImportConflictPolicy Association = DatasetMetadataImportConflictPolicy.RequireDecision,
    DatasetMetadataImportConflictPolicy Axis = DatasetMetadataImportConflictPolicy.RequireDecision)
{
    public static readonly DatasetMetadataImportPolicy SafeDefault = new(
        DatasetMetadataImportConflictPolicy.KeepDestination,
        DatasetMetadataImportConflictPolicy.KeepDestination,
        DatasetMetadataImportConflictPolicy.KeepDestination);

    public static readonly DatasetMetadataImportPolicy RequireDecisions = new();
}

public enum DatasetMetadataImportConflictResolution
{
    KeptDestination,
    UsedImported,
    Unresolved
}

public enum DatasetMetadataTagIdentityConflictKind
{
    SameNameDifferentUuid,
    SameUuidDifferentName,
    UuidAndNameMatchDifferentDestinationTags
}

public abstract record DatasetMetadataImportIssue
{
    public sealed record MissingTagMember(Guid TagId, DatasetRelativePath SxmPath) : DatasetMetadataImportIssue;

    public sealed record TagIdentityConflict(
        DatasetMetadataTagIdentityConflictKind Kind,
        Guid ImportedTagId,
        string ImportedName,
        Guid? UuidMatchedTagId,
        Guid? NameMatchedTagId,
        DatasetMetadataImportConflictResolution Resolution) : DatasetMetadataImportIssue;

    public sealed record AssociationDatMissing(DatasetRelativePath DatPath) : DatasetMetadataImportIssue;
    public sealed record AssociationSxmMissing(DatasetRelativePath DatPath, DatasetRelativePath SxmPath) : DatasetMetadataImportIssue;

    public sealed record AssociationConflict(
        DatasetRelativePath DatPath,
        DatasetRelativePath DestinationSxmPath,
        DatasetRelativePath ImportedSxmPath,
        DatasetMetadataImportConflictResolution Resolution) : DatasetMetadataImportIssue;

    public sealed record HiddenDatMissing(DatasetRelativePath DatPath) : DatasetMetadataImportIssue;

    public sealed record AxisGroupUnavailable(
        SpectrumAxisPreferenceKeyV1 Key,
        IReadOnlyList<string> AvailableFingerprints) : DatasetMetadataImportIssue;

    public sealed record AxisExperimentAmbiguous(
        SpectrumAxisPreferenceKeyV1 Key,
        IReadOnlyList<string> AvailableIdentities) : DatasetMetadataImportIssue;

    public sealed record AxisColumnMissing(
        SpectrumAxisPreferenceKeyV1 Key,
        SpectrumAxis Axis,
        string Column) : DatasetMetadataImportIssue;

    public sealed record AxisColumnAmbiguous(
        SpectrumAxisPreferenceKeyV1 Key,
        SpectrumAxis Axis,
        string Column,
        IReadOnlyList<string> Matches) : DatasetMetadataImportIssue;

    public sealed record AxisConflict(
        SpectrumAxisPreferenceKeyV1 Key,
        AxisSelection Destination,
        AxisSelection Imported,
        DatasetMetadataImportConflictResolution Resolution) : DatasetMetadataImportIssue;

    public bool IsUnresolvedConflict => this switch
    {
        TagIdentityConflict t => t.Resolution == DatasetMetadataImportConflictResolution.Unresolved,
        AssociationConflict a => a.Resolution == DatasetMetadataImportConflictResolution.Unresolved,
        AxisConflict ax => ax.Resolution == DatasetMetadataImportConflictResolution.Unresolved,
        _ => false
    };

    public bool IsResolvedConflict => this switch
    {
        TagIdentityConflict t => t.Resolution != DatasetMetadataImportConflictResolution.Unresolved,
        AssociationConflict a => a.Resolution != DatasetMetadataImportConflictResolution.Unresolved,
        AxisConflict ax => ax.Resolution != DatasetMetadataImportConflictResolution.Unresolved,
        _ => false
    };

    public bool IsSkippedItem => this switch
    {
        MissingTagMember or AssociationDatMissing or AssociationSxmMissing or HiddenDatMissing
            or AxisGroupUnavailable or AxisExperimentAmbiguous or AxisColumnMissing or AxisColumnAmbiguous => true,
        _ => false
    };
}

public abstract record DatasetMetadataImportAction
{
    public sealed record AddTag(DatasetTagV1 Tag) : DatasetMetadataImportAction;
    public sealed record MergeTag(Guid ImportedTagId, Guid DestinationTagId, IReadOnlyList<DatasetRelativePath> AddedSxmPaths) : DatasetMetadataImportAction;
    public sealed record RenameTag(Guid TagId, string From, string To) : DatasetMetadataImportAction;
    public sealed record AddManualAssociation(DatasetManualAssociationV1 Association) : DatasetMetadataImportAction;
    public sealed record ReplaceManualAssociation(DatasetRelativePath DatPath, DatasetRelativePath From, DatasetRelativePath To) : DatasetMetadataImportAction;
    public sealed record HideDat(DatasetRelativePath DatPath) : DatasetMetadataImportAction;
    public sealed record AddAxisPreference(SpectrumAxisPreferenceV1 Preference) : DatasetMetadataImportAction;
    public sealed record ReplaceAxisPreference(SpectrumAxisPreferenceKeyV1 Key, AxisSelection From, AxisSelection To) : DatasetMetadataImportAction;

    public bool IsTagAction => this is AddTag or MergeTag or RenameTag;
    public bool IsAssociationAction => this is AddManualAssociation or ReplaceManualAssociation;
    public bool IsHiddenAction => this is HideDat;
    public bool IsAxisAction => this is AddAxisPreference or ReplaceAxisPreference;
}

public sealed record DatasetMetadataImportPreview(
    IReadOnlyList<DatasetTagV1> Tags,
    IReadOnlyList<DatasetManualAssociationV1> ManualAssociations,
    IReadOnlyList<DatasetRelativePath> HiddenDATPaths,
    IReadOnlyList<SpectrumAxisPreferenceV1> SpectrumAxisPreferences);

public sealed record DatasetMetadataImportSummary(
    int ActionCount,
    int TagActionCount,
    int AssociationActionCount,
    int HiddenActionCount,
    int AxisActionCount,
    int SkippedItemCount,
    int ResolvedConflictCount,
    int UnresolvedConflictCount)
{
    internal static DatasetMetadataImportSummary Create(
        IReadOnlyList<DatasetMetadataImportAction> actions,
        IReadOnlyList<DatasetMetadataImportIssue> issues) => new(
            actions.Count,
            actions.Count(a => a.IsTagAction),
            actions.Count(a => a.IsAssociationAction),
            actions.Count(a => a.IsHiddenAction),
            actions.Count(a => a.IsAxisAction),
            issues.Count(i => i.IsSkippedItem),
            issues.Count(i => i.IsResolvedConflict),
            issues.Count(i => i.IsUnresolvedConflict));
}

public sealed class DatasetMetadataImportPlan
{
    private readonly DatasetRecordV1 _baselineRecord;
    private readonly DatasetMetadataImportInventory _baselineInventory;

    public DatasetMetadataImportPreview Preview { get; }
    public DatasetMetadataImportSummary Summary { get; }
    public IReadOnlyList<DatasetMetadataImportIssue> Issues { get; }
    public IReadOnlyList<DatasetMetadataImportAction> Actions { get; }
    public bool HasChanges { get; }
    public bool CanApply { get; }

    internal DatasetMetadataImportPlan(
        DatasetRecordV1 baselineRecord,
        DatasetMetadataImportInventory baselineInventory,
        DatasetMetadataImportPreview preview,
        IReadOnlyList<DatasetMetadataImportIssue> issues,
        IReadOnlyList<DatasetMetadataImportAction> actions)
    {
        _baselineRecord = baselineRecord.Clone();
        _baselineInventory = baselineInventory;
        Preview = preview;
        Issues = issues;
        Actions = actions;
        Summary = DatasetMetadataImportSummary.Create(actions, issues);
        HasChanges =
            !preview.Tags.SequenceEqual(baselineRecord.Tags)
            || !preview.ManualAssociations.SequenceEqual(baselineRecord.ManualAssociations)
            || !preview.HiddenDATPaths.SequenceEqual(baselineRecord.HiddenDATPaths)
            || !preview.SpectrumAxisPreferences.SequenceEqual(baselineRecord.SpectrumAxisPreferences);
        CanApply = !issues.Any(i => i.IsUnresolvedConflict);
    }

    public DatasetRecordV1 Applying(
        DatasetRecordV1 currentRecord,
        DatasetMetadataImportInventory currentInventory,
        DateTimeOffset updatedAt)
    {
        if (currentRecord.Id != _baselineRecord.Id || currentInventory.DatasetId != _baselineRecord.Id)
        {
            throw new InvalidOperationException(
                $"The import expected dataset {_baselineRecord.Id}, but current record is {currentRecord.Id} and inventory is {currentInventory.DatasetId}.");
        }
        if (!currentRecord.Equals(_baselineRecord))
        {
            throw new InvalidOperationException("Dataset metadata changed after the import preview was made.");
        }
        if (!currentInventory.Equals(_baselineInventory))
        {
            throw new InvalidOperationException("Dataset files changed after the import preview was made.");
        }
        int unresolved = Summary.UnresolvedConflictCount;
        if (unresolved > 0)
        {
            throw new InvalidOperationException(
                $"The metadata import has {unresolved} unresolved conflict{(unresolved == 1 ? "" : "s")}.");
        }
        if (!HasChanges)
        {
            return currentRecord;
        }

        return new DatasetRecordV1(
            id: currentRecord.Id,
            folderBookmark: currentRecord.FolderBookmark,
            lastKnownPath: currentRecord.LastKnownPath,
            tags: Preview.Tags,
            manualAssociations: Preview.ManualAssociations,
            hiddenDATPaths: Preview.HiddenDATPaths,
            spectrumAxisPreferences: Preview.SpectrumAxisPreferences,
            updatedAt: updatedAt);
    }
}

public sealed class DatasetMetadataImportPlanner
{
    private sealed record SimulatedAxisGroup(SpectrumAxisPreferenceKeyV1 Key, IReadOnlyList<string> ColumnCandidates);

    public DatasetMetadataImportPlan Plan(
        DatasetMetadataTransferV1 transfer,
        DatasetRecordV1 destination,
        DatasetMetadataImportInventory inventory,
        DatasetMetadataImportPolicy? policy = null)
    {
        policy ??= DatasetMetadataImportPolicy.SafeDefault;

        if (destination.Id != inventory.DatasetId)
        {
            throw new InvalidOperationException(
                $"Cannot plan metadata import for dataset {destination.Id}: inventory belongs to {inventory.DatasetId}.");
        }

        var issues = new List<DatasetMetadataImportIssue>();
        var actions = new List<DatasetMetadataImportAction>();
        var availableSxm = new HashSet<DatasetRelativePath>(inventory.SxmPaths);
        var availableDat = new HashSet<DatasetRelativePath>(inventory.DatFiles.Select(f => f.Path));

        List<DatasetTagV1> tags = MergeTags(
            destination.Tags,
            transfer.Tags,
            availableSxm,
            policy.TagIdentity,
            issues,
            actions);

        List<DatasetManualAssociationV1> associations = MergeAssociations(
            destination.ManualAssociations,
            transfer.ManualAssociations,
            availableSxm,
            availableDat,
            policy.Association,
            issues,
            actions);

        List<DatasetRelativePath> hiddenDat = MergeHiddenPaths(
            destination.HiddenDATPaths,
            transfer.HiddenDATPaths,
            availableDat,
            issues,
            actions);

        List<SpectrumAxisPreferenceV1> axisPrefs = MergeAxisPreferences(
            destination.SpectrumAxisPreferences,
            transfer.SpectrumAxisPreferences,
            associations,
            inventory,
            policy.Axis,
            issues,
            actions);

        return new DatasetMetadataImportPlan(
            destination,
            inventory,
            new DatasetMetadataImportPreview(tags, associations, hiddenDat, axisPrefs),
            issues,
            actions);
    }

    private static List<DatasetTagV1> MergeTags(
        IReadOnlyList<DatasetTagV1> destination,
        IReadOnlyList<DatasetTagV1> imported,
        HashSet<DatasetRelativePath> availableSxm,
        DatasetMetadataImportConflictPolicy policy,
        List<DatasetMetadataImportIssue> issues,
        List<DatasetMetadataImportAction> actions)
    {
        var result = destination.ToList();

        foreach (DatasetTagV1 importedTag in imported)
        {
            var availableMembers = new List<DatasetRelativePath>();
            foreach (DatasetRelativePath path in importedTag.SxmPaths)
            {
                if (availableSxm.Contains(path))
                {
                    availableMembers.Add(path);
                }
                else
                {
                    issues.Add(new DatasetMetadataImportIssue.MissingTagMember(importedTag.Id, path));
                }
            }

            int idIndex = result.FindIndex(t => t.Id == importedTag.Id);
            string importedNameKey = MetadataCanonical.CanonicalTagComparisonKey(importedTag.Name);
            int nameIndex = result.FindIndex(t =>
                string.Equals(MetadataCanonical.CanonicalTagComparisonKey(t.Name), importedNameKey, StringComparison.Ordinal));

            if (idIndex < 0 && nameIndex < 0)
            {
                var added = new DatasetTagV1(importedTag.Id, importedTag.Name, availableMembers);
                result.Add(added);
                actions.Add(new DatasetMetadataImportAction.AddTag(added));
                continue;
            }

            int targetIndex;
            string resultingName;

            if (idIndex >= 0 && nameIndex >= 0 && idIndex == nameIndex)
            {
                targetIndex = idIndex;
                resultingName = result[idIndex].Name;
            }
            else if (idIndex < 0 && nameIndex >= 0)
            {
                targetIndex = nameIndex;
                resultingName = result[nameIndex].Name;
                issues.Add(new DatasetMetadataImportIssue.TagIdentityConflict(
                    DatasetMetadataTagIdentityConflictKind.SameNameDifferentUuid,
                    importedTag.Id,
                    importedTag.Name,
                    null,
                    result[nameIndex].Id,
                    DatasetMetadataImportConflictResolution.KeptDestination));
            }
            else if (idIndex >= 0 && nameIndex < 0)
            {
                targetIndex = idIndex;
                var resolution = ConflictResolution(policy);
                issues.Add(new DatasetMetadataImportIssue.TagIdentityConflict(
                    DatasetMetadataTagIdentityConflictKind.SameUuidDifferentName,
                    importedTag.Id,
                    importedTag.Name,
                    result[idIndex].Id,
                    null,
                    resolution));
                resultingName = policy == DatasetMetadataImportConflictPolicy.UseImported
                    ? importedTag.Name
                    : result[idIndex].Name;
            }
            else
            {
                var resolution = ConflictResolution(policy);
                issues.Add(new DatasetMetadataImportIssue.TagIdentityConflict(
                    DatasetMetadataTagIdentityConflictKind.UuidAndNameMatchDifferentDestinationTags,
                    importedTag.Id,
                    importedTag.Name,
                    result[idIndex].Id,
                    result[nameIndex].Id,
                    resolution));
                targetIndex = policy == DatasetMetadataImportConflictPolicy.UseImported ? nameIndex : idIndex;
                resultingName = result[targetIndex].Name;
            }

            DatasetTagV1 target = result[targetIndex];
            if (!string.Equals(target.Name, resultingName, StringComparison.Ordinal))
            {
                actions.Add(new DatasetMetadataImportAction.RenameTag(target.Id, target.Name, resultingName));
            }

            var existingMembers = new HashSet<DatasetRelativePath>(target.SxmPaths);
            var addedMembers = availableMembers.Where(m => !existingMembers.Contains(m)).ToArray();
            if (addedMembers.Length > 0)
            {
                actions.Add(new DatasetMetadataImportAction.MergeTag(importedTag.Id, target.Id, addedMembers));
            }

            result[targetIndex] = new DatasetTagV1(
                target.Id,
                resultingName,
                target.SxmPaths.Concat(addedMembers));
        }

        return result;
    }

    private static List<DatasetManualAssociationV1> MergeAssociations(
        IReadOnlyList<DatasetManualAssociationV1> destination,
        IReadOnlyList<DatasetManualAssociationV1> imported,
        HashSet<DatasetRelativePath> availableSxm,
        HashSet<DatasetRelativePath> availableDat,
        DatasetMetadataImportConflictPolicy policy,
        List<DatasetMetadataImportIssue> issues,
        List<DatasetMetadataImportAction> actions)
    {
        var result = destination.ToList();

        foreach (DatasetManualAssociationV1 assoc in imported)
        {
            bool available = true;
            if (!availableDat.Contains(assoc.DatPath))
            {
                issues.Add(new DatasetMetadataImportIssue.AssociationDatMissing(assoc.DatPath));
                available = false;
            }
            if (!availableSxm.Contains(assoc.SxmPath))
            {
                issues.Add(new DatasetMetadataImportIssue.AssociationSxmMissing(assoc.DatPath, assoc.SxmPath));
                available = false;
            }
            if (!available) continue;

            int existingIdx = result.FindIndex(a => a.DatPath.Equals(assoc.DatPath));
            if (existingIdx < 0)
            {
                result.Add(assoc);
                actions.Add(new DatasetMetadataImportAction.AddManualAssociation(assoc));
                continue;
            }

            DatasetManualAssociationV1 existing = result[existingIdx];
            if (existing.SxmPath.Equals(assoc.SxmPath)) continue;

            issues.Add(new DatasetMetadataImportIssue.AssociationConflict(
                assoc.DatPath,
                existing.SxmPath,
                assoc.SxmPath,
                ConflictResolution(policy)));

            if (policy == DatasetMetadataImportConflictPolicy.UseImported)
            {
                result[existingIdx] = assoc;
                actions.Add(new DatasetMetadataImportAction.ReplaceManualAssociation(
                    assoc.DatPath,
                    existing.SxmPath,
                    assoc.SxmPath));
            }
        }

        return result;
    }

    private static List<DatasetRelativePath> MergeHiddenPaths(
        IReadOnlyList<DatasetRelativePath> destination,
        IReadOnlyList<DatasetRelativePath> imported,
        HashSet<DatasetRelativePath> availableDat,
        List<DatasetMetadataImportIssue> issues,
        List<DatasetMetadataImportAction> actions)
    {
        var result = destination.ToList();
        var seen = new HashSet<DatasetRelativePath>(destination);

        foreach (DatasetRelativePath path in imported)
        {
            if (!availableDat.Contains(path))
            {
                issues.Add(new DatasetMetadataImportIssue.HiddenDatMissing(path));
                continue;
            }
            if (seen.Add(path))
            {
                result.Add(path);
                actions.Add(new DatasetMetadataImportAction.HideDat(path));
            }
        }
        return result;
    }

    private static List<SpectrumAxisPreferenceV1> MergeAxisPreferences(
        IReadOnlyList<SpectrumAxisPreferenceV1> destination,
        IReadOnlyList<SpectrumAxisPreferenceV1> imported,
        IReadOnlyList<DatasetManualAssociationV1> associations,
        DatasetMetadataImportInventory inventory,
        DatasetMetadataImportConflictPolicy policy,
        List<DatasetMetadataImportIssue> issues,
        List<DatasetMetadataImportAction> actions)
    {
        var result = destination.ToList();
        Dictionary<SpectrumAxisPreferenceKeyV1, SimulatedAxisGroup> groups =
            BuildSimulatedAxisGroups(inventory, associations);

        foreach (SpectrumAxisPreferenceV1 pref in imported)
        {
            SpectrumAxisPreferenceKeyV1 reqKey = pref.Key;
            SpectrumAxisPreferenceKeyV1 key;
            SimulatedAxisGroup group;

            if (reqKey.ExperimentIdentity is null)
            {
                var candidates = groups.Values.Where(g =>
                    g.Key.SxmPath.Equals(reqKey.SxmPath)
                    && g.Key.Kind == reqKey.Kind
                    && string.Equals(g.Key.SchemaFingerprint, reqKey.SchemaFingerprint, StringComparison.Ordinal))
                    .ToList();

                if (candidates.Count > 1)
                {
                    issues.Add(new DatasetMetadataImportIssue.AxisExperimentAmbiguous(
                        reqKey,
                        candidates.Select(c => c.Key.ExperimentIdentity!).Distinct(StringComparer.Ordinal).OrderBy(s => s, StringComparer.Ordinal).ToArray()));
                    continue;
                }
                if (candidates.Count == 0)
                {
                    string[] fps = groups.Keys
                        .Where(k => k.SxmPath.Equals(reqKey.SxmPath) && k.Kind == reqKey.Kind)
                        .Select(k => k.SchemaFingerprint)
                        .OrderBy(s => s, StringComparer.Ordinal)
                        .ToArray();
                    issues.Add(new DatasetMetadataImportIssue.AxisGroupUnavailable(reqKey, fps));
                    continue;
                }

                key = candidates[0].Key;
                group = candidates[0];
            }
            else if (groups.TryGetValue(reqKey, out SimulatedAxisGroup? exactGroup))
            {
                key = reqKey;
                group = exactGroup;
            }
            else
            {
                string[] fps = groups.Keys
                    .Where(k => k.SxmPath.Equals(reqKey.SxmPath)
                        && k.Kind == reqKey.Kind
                        && string.Equals(k.ExperimentIdentity, reqKey.ExperimentIdentity, StringComparison.Ordinal))
                    .Select(k => k.SchemaFingerprint)
                    .OrderBy(s => s, StringComparer.Ordinal)
                    .ToArray();
                issues.Add(new DatasetMetadataImportIssue.AxisGroupUnavailable(reqKey, fps));
                continue;
            }

            var selectionIssues = new List<DatasetMetadataImportIssue>();
            string? xCol = ResolveImportColumn(pref.Selection.XColumn, SpectrumAxis.X, group, selectionIssues);
            string? yCol = ResolveImportColumn(pref.Selection.YColumn, SpectrumAxis.Y, group, selectionIssues);
            if (selectionIssues.Count > 0 || xCol is null || yCol is null)
            {
                issues.AddRange(selectionIssues);
                continue;
            }

            var resolved = new SpectrumAxisPreferenceV1(key, new AxisSelection(xCol, yCol));
            int existingIdx = result.FindIndex(p => p.Key.Equals(key));
            if (existingIdx < 0)
            {
                result.Add(resolved);
                actions.Add(new DatasetMetadataImportAction.AddAxisPreference(resolved));
                continue;
            }

            SpectrumAxisPreferenceV1 existing = result[existingIdx];
            if (existing.Selection.Equals(resolved.Selection)) continue;

            issues.Add(new DatasetMetadataImportIssue.AxisConflict(
                key,
                existing.Selection,
                resolved.Selection,
                ConflictResolution(policy)));

            if (policy == DatasetMetadataImportConflictPolicy.UseImported)
            {
                result[existingIdx] = resolved;
                actions.Add(new DatasetMetadataImportAction.ReplaceAxisPreference(
                    key,
                    existing.Selection,
                    resolved.Selection));
            }
        }

        return result;
    }

    private static Dictionary<SpectrumAxisPreferenceKeyV1, SimulatedAxisGroup> BuildSimulatedAxisGroups(
        DatasetMetadataImportInventory inventory,
        IReadOnlyList<DatasetManualAssociationV1> associations)
    {
        var availableSxm = new HashSet<DatasetRelativePath>(inventory.SxmPaths);
        var manualTargetByDat = new Dictionary<DatasetRelativePath, DatasetRelativePath>();
        foreach (DatasetManualAssociationV1 a in associations)
        {
            manualTargetByDat[a.DatPath] = a.SxmPath;
        }

        var groups = new Dictionary<SpectrumAxisPreferenceKeyV1, SimulatedAxisGroup>();
        foreach (DatasetMetadataImportDatFile file in inventory.DatFiles)
        {
            DatasetRelativePath? parent;
            if (manualTargetByDat.TryGetValue(file.Path, out DatasetRelativePath? manualTarget))
            {
                parent = availableSxm.Contains(manualTarget) ? manualTarget : null;
            }
            else
            {
                parent = file.AutomaticParentSxmPath;
            }
            if (parent is null) continue;

            var key = new SpectrumAxisPreferenceKeyV1(
                parent,
                file.Kind,
                file.ExperimentIdentity,
                file.SchemaFingerprint);
            if (!groups.ContainsKey(key))
            {
                groups[key] = new SimulatedAxisGroup(key, file.Columns);
            }
        }
        return groups;
    }

    private static string? ResolveImportColumn(
        string requested,
        SpectrumAxis axis,
        SimulatedAxisGroup group,
        List<DatasetMetadataImportIssue> issues)
    {
        IReadOnlyList<string> candidates = group.ColumnCandidates;
        var exact = candidates.Where(c => string.Equals(c, requested, StringComparison.Ordinal)).ToArray();
        if (exact.Length == 1) return exact[0];
        if (exact.Length > 1)
        {
            issues.Add(new DatasetMetadataImportIssue.AxisColumnAmbiguous(
                group.Key, axis, requested, exact.OrderBy(c => c, StringComparer.Ordinal).ToArray()));
            return null;
        }

        string norm = SpectroscopyColumnSchema.Normalize(requested);
        var normMatches = candidates
            .Where(c => string.Equals(SpectroscopyColumnSchema.Normalize(c), norm, StringComparison.Ordinal))
            .ToArray();
        if (normMatches.Length == 1) return normMatches[0];
        if (normMatches.Length == 0)
        {
            issues.Add(new DatasetMetadataImportIssue.AxisColumnMissing(group.Key, axis, requested));
            return null;
        }

        issues.Add(new DatasetMetadataImportIssue.AxisColumnAmbiguous(
            group.Key, axis, requested, normMatches.OrderBy(c => c, StringComparer.Ordinal).ToArray()));
        return null;
    }

    private static DatasetMetadataImportConflictResolution ConflictResolution(
        DatasetMetadataImportConflictPolicy policy) => policy switch
    {
        DatasetMetadataImportConflictPolicy.KeepDestination => DatasetMetadataImportConflictResolution.KeptDestination,
        DatasetMetadataImportConflictPolicy.UseImported => DatasetMetadataImportConflictResolution.UsedImported,
        _ => DatasetMetadataImportConflictResolution.Unresolved
    };
}
