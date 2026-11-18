using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public enum DatasetFileKind
{
    Sxm,
    Dat
}

public static class DatasetFileKindExtensions
{
    public static string FileExtension(this DatasetFileKind kind) => kind switch
    {
        DatasetFileKind.Sxm => "sxm",
        DatasetFileKind.Dat => "dat",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null)
    };
}

public enum DatasetRelativePathInvalidReason
{
    Empty,
    Absolute,
    ContainsNUL,
    ContainsBackslash,
    EmptyComponent,
    DotComponent,
    ParentComponent
}

public enum DatasetMetadataValidationErrorKind
{
    InvalidRelativePath,
    UnexpectedFileExtension,
    UnsupportedSchemaVersion,
    DuplicateDatasetId,
    DatasetNotFound,
    LastOpenedDatasetMissing,
    EmptyFolderBookmark,
    InvalidLastKnownPath,
    InvalidUpdatedAt,
    InvalidTagName,
    DuplicateTagId,
    DuplicateTagName,
    TagNotFound,
    TagIndexOutOfBounds,
    ConflictingManualAssociation,
    InvalidSchemaFingerprint,
    InvalidAxisColumn,
    ConflictingAxisPreference
}

public sealed class DatasetMetadataValidationException : Exception
{
    public DatasetMetadataValidationErrorKind Kind { get; }
    public string? Detail { get; }

    public DatasetMetadataValidationException(
        DatasetMetadataValidationErrorKind kind,
        string message,
        string? detail = null)
        : base(message)
    {
        Kind = kind;
        Detail = detail;
    }
}

public sealed class DatasetRelativePath :
    IEquatable<DatasetRelativePath>,
    IComparable<DatasetRelativePath>
{
    public string RawValue { get; }

    public DatasetRelativePath(string rawValue)
    {
        string normalized = MetadataCanonical.SafeNormalizeNfc(rawValue);
        if (normalized.Length == 0)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidRelativePath,
                $"Invalid dataset-relative path \u201C{rawValue}\u201D: Empty.",
                nameof(DatasetRelativePathInvalidReason.Empty));
        }
        if (normalized.StartsWith('/'))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidRelativePath,
                $"Invalid dataset-relative path \u201C{rawValue}\u201D: Absolute.",
                nameof(DatasetRelativePathInvalidReason.Absolute));
        }
        if (normalized.Contains('\0'))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidRelativePath,
                $"Invalid dataset-relative path \u201C{rawValue}\u201D: ContainsNUL.",
                nameof(DatasetRelativePathInvalidReason.ContainsNUL));
        }
        if (normalized.Contains('\\'))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidRelativePath,
                $"Invalid dataset-relative path \u201C{rawValue}\u201D: ContainsBackslash.",
                nameof(DatasetRelativePathInvalidReason.ContainsBackslash));
        }

        string[] components = normalized.Split('/', StringSplitOptions.None);
        foreach (string component in components)
        {
            if (component.Length == 0)
            {
                throw new DatasetMetadataValidationException(
                    DatasetMetadataValidationErrorKind.InvalidRelativePath,
                    $"Invalid dataset-relative path \u201C{rawValue}\u201D: EmptyComponent.",
                    nameof(DatasetRelativePathInvalidReason.EmptyComponent));
            }
            if (component == ".")
            {
                throw new DatasetMetadataValidationException(
                    DatasetMetadataValidationErrorKind.InvalidRelativePath,
                    $"Invalid dataset-relative path \u201C{rawValue}\u201D: DotComponent.",
                    nameof(DatasetRelativePathInvalidReason.DotComponent));
            }
            if (component == "..")
            {
                throw new DatasetMetadataValidationException(
                    DatasetMetadataValidationErrorKind.InvalidRelativePath,
                    $"Invalid dataset-relative path \u201C{rawValue}\u201D: ParentComponent.",
                    nameof(DatasetRelativePathInvalidReason.ParentComponent));
            }
        }

        RawValue = normalized;
    }

    public DatasetRelativePath(string rawValue, DatasetFileKind requiring)
        : this(rawValue)
    {
        Validated(requiring);
    }

    public static DatasetRelativePath Sxm(string rawValue) => new(rawValue, DatasetFileKind.Sxm);
    public static DatasetRelativePath Dat(string rawValue) => new(rawValue, DatasetFileKind.Dat);

    public string? PathExtension
    {
        get
        {
            int lastSlash = RawValue.LastIndexOf('/');
            string filename = lastSlash >= 0 ? RawValue[(lastSlash + 1)..] : RawValue;
            int dot = filename.LastIndexOf('.');
            if (dot <= 0 || dot == filename.Length - 1)
            {
                return null;
            }
            return filename[(dot + 1)..];
        }
    }

    public DatasetRelativePath Validated(DatasetFileKind fileKind)
    {
        string? actual = PathExtension?.ToLowerInvariant();
        if (!string.Equals(actual, fileKind.FileExtension(), StringComparison.Ordinal))
        {
            string extMsg = PathExtension is not null
                ? $"a .{PathExtension} extension."
                : "no extension.";
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.UnexpectedFileExtension,
                $"Expected a .{fileKind.FileExtension()} path, but \u201C{RawValue}\u201D has {extMsg}");
        }
        return this;
    }

    public override string ToString() => RawValue;
    public int CompareTo(DatasetRelativePath? other) =>
        other is null ? 1 : string.CompareOrdinal(RawValue, other.RawValue);
    public bool Equals(DatasetRelativePath? other) =>
        other is not null && string.Equals(RawValue, other.RawValue, StringComparison.Ordinal);
    public override bool Equals(object? obj) => Equals(obj as DatasetRelativePath);
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(RawValue);
}

public sealed class DatasetTagV1 : IEquatable<DatasetTagV1>
{
    public Guid Id { get; }
    public string Name { get; }
    public IReadOnlyList<DatasetRelativePath> SxmPaths { get; }

    public DatasetTagV1(
        Guid? id,
        string name,
        IEnumerable<DatasetRelativePath>? sxmPaths = null)
    {
        Id = id ?? Guid.NewGuid();
        Name = MetadataCanonical.CanonicalTagName(name);
        SxmPaths = MetadataCanonical.OrderedUnique(
            sxmPaths ?? Array.Empty<DatasetRelativePath>(),
            p => p.Validated(DatasetFileKind.Sxm));
    }

    public DatasetTagV1(Guid? id, string name, IEnumerable<string> sxmPathStrings)
        : this(id, name, sxmPathStrings.Select(DatasetRelativePath.Sxm))
    {
    }

    public bool Equals(DatasetTagV1? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return Id == other.Id
            && string.Equals(Name, other.Name, StringComparison.Ordinal)
            && SxmPaths.SequenceEqual(other.SxmPaths);
    }

    public override bool Equals(object? obj) => Equals(obj as DatasetTagV1);
    public override int GetHashCode() => HashCode.Combine(Id, Name, SxmPaths.Count);
}

public sealed record DatasetManualAssociationV1
{
    public DatasetRelativePath DatPath { get; }
    public DatasetRelativePath SxmPath { get; }

    public DatasetManualAssociationV1(DatasetRelativePath datPath, DatasetRelativePath sxmPath)
    {
        DatPath = datPath.Validated(DatasetFileKind.Dat);
        SxmPath = sxmPath.Validated(DatasetFileKind.Sxm);
    }

    public DatasetManualAssociationV1(string datPath, string sxmPath)
        : this(DatasetRelativePath.Dat(datPath), DatasetRelativePath.Sxm(sxmPath))
    {
    }
}

public sealed class SpectrumAxisPreferenceKeyV1 : IEquatable<SpectrumAxisPreferenceKeyV1>
{
    public DatasetRelativePath SxmPath { get; }
    public SpectroscopyKind Kind { get; }
    public string? ExperimentIdentity { get; }
    public string SchemaFingerprint { get; }

    public SpectrumAxisPreferenceKeyV1(
        DatasetRelativePath sxmPath,
        SpectroscopyKind kind,
        string? experimentIdentity,
        string schemaFingerprint)
    {
        SxmPath = sxmPath.Validated(DatasetFileKind.Sxm);
        Kind = kind;
        ExperimentIdentity = experimentIdentity is null
            ? null
            : SpectroscopyExperimentIdentity.Make(experimentIdentity, kind);
        SchemaFingerprint = MetadataCanonical.CanonicalSchemaFingerprint(schemaFingerprint);
    }

    public SpectrumAxisPreferenceKeyV1(
        string sxmPath,
        SpectroscopyKind kind,
        string? experimentIdentity,
        string schemaFingerprint)
        : this(DatasetRelativePath.Sxm(sxmPath), kind, experimentIdentity, schemaFingerprint)
    {
    }

    public string StableIdentifier
    {
        get
        {
            if (ExperimentIdentity is null)
            {
                return $"{SxmPath.RawValue}|{Kind.ToRawValue()}|{SchemaFingerprint}";
            }
            return $"{SxmPath.RawValue}|{Kind.ToRawValue()}|{Encoding.UTF8.GetByteCount(ExperimentIdentity)}:{ExperimentIdentity}|{SchemaFingerprint}";
        }
    }

    public bool Equals(SpectrumAxisPreferenceKeyV1? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return SxmPath.Equals(other.SxmPath)
            && Kind == other.Kind
            && string.Equals(ExperimentIdentity, other.ExperimentIdentity, StringComparison.Ordinal)
            && string.Equals(SchemaFingerprint, other.SchemaFingerprint, StringComparison.Ordinal);
    }

    public override bool Equals(object? obj) => Equals(obj as SpectrumAxisPreferenceKeyV1);

    public override int GetHashCode() =>
        HashCode.Combine(SxmPath, Kind, ExperimentIdentity, SchemaFingerprint);
}

public sealed record SpectrumAxisPreferenceV1
{
    public SpectrumAxisPreferenceKeyV1 Key { get; }
    public AxisSelection Selection { get; }

    public SpectrumAxisPreferenceV1(SpectrumAxisPreferenceKeyV1 key, AxisSelection selection)
    {
        Key = key;
        Selection = new AxisSelection(
            MetadataCanonical.CanonicalAxisColumn(selection.XColumn),
            MetadataCanonical.CanonicalAxisColumn(selection.YColumn));
    }

    public SpectrumAxisPreferenceV1(
        string sxmPath,
        SpectroscopyKind kind,
        string? experimentIdentity,
        string schemaFingerprint,
        AxisSelection selection)
        : this(
            new SpectrumAxisPreferenceKeyV1(sxmPath, kind, experimentIdentity, schemaFingerprint),
            selection)
    {
    }
}

public sealed class DatasetRecordV1 : IEquatable<DatasetRecordV1>
{
    public Guid Id { get; }
    public byte[]? FolderBookmark { get; private set; }
    public string LastKnownPath { get; private set; }
    public List<DatasetTagV1> Tags { get; private set; }
    public List<DatasetManualAssociationV1> ManualAssociations { get; private set; }
    public List<DatasetRelativePath> HiddenDATPaths { get; private set; }
    public List<SpectrumAxisPreferenceV1> SpectrumAxisPreferences { get; private set; }
    public DateTimeOffset UpdatedAt { get; private set; }

    public DatasetRecordV1(
        Guid? id = null,
        byte[]? folderBookmark = null,
        string lastKnownPath = "/",
        IEnumerable<DatasetTagV1>? tags = null,
        IEnumerable<DatasetManualAssociationV1>? manualAssociations = null,
        IEnumerable<DatasetRelativePath>? hiddenDATPaths = null,
        IEnumerable<SpectrumAxisPreferenceV1>? spectrumAxisPreferences = null,
        DateTimeOffset? updatedAt = null)
    {
        if (folderBookmark is not null && folderBookmark.Length == 0)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.EmptyFolderBookmark,
                "A stored folder bookmark cannot be empty.");
        }
        string canonicalPath = MetadataCanonical.CanonicalDatasetFolderPath(lastKnownPath);
        DateTimeOffset ts = updatedAt ?? DateTimeOffset.UtcNow;

        Id = id ?? Guid.NewGuid();
        FolderBookmark = folderBookmark is null ? null : (byte[])folderBookmark.Clone();
        LastKnownPath = canonicalPath;
        Tags = ValidateTags(tags ?? Array.Empty<DatasetTagV1>());
        ManualAssociations = CanonicalAssociations(
            manualAssociations ?? Array.Empty<DatasetManualAssociationV1>());
        HiddenDATPaths = MetadataCanonical.OrderedUnique(
            hiddenDATPaths ?? Array.Empty<DatasetRelativePath>(),
            p => p.Validated(DatasetFileKind.Dat)).ToList();
        SpectrumAxisPreferences = CanonicalAxisPreferences(
            spectrumAxisPreferences ?? Array.Empty<SpectrumAxisPreferenceV1>());
        UpdatedAt = ts;
    }

    public DatasetRecordV1 Clone() => new(
        id: Id,
        folderBookmark: FolderBookmark,
        lastKnownPath: LastKnownPath,
        tags: Tags,
        manualAssociations: ManualAssociations,
        hiddenDATPaths: HiddenDATPaths,
        spectrumAxisPreferences: SpectrumAxisPreferences,
        updatedAt: UpdatedAt);

    public void UpdateFolderIdentity(byte[]? folderBookmark, string lastKnownPath, DateTimeOffset updatedAt)
    {
        if (folderBookmark is not null && folderBookmark.Length == 0)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.EmptyFolderBookmark,
                "A stored folder bookmark cannot be empty.");
        }
        LastKnownPath = MetadataCanonical.CanonicalDatasetFolderPath(lastKnownPath);
        FolderBookmark = folderBookmark is null ? null : (byte[])folderBookmark.Clone();
        UpdatedAt = updatedAt;
    }

    public void MarkUpdated(DateTimeOffset updatedAt)
    {
        UpdatedAt = updatedAt;
    }

    public void ReplaceManualAssociations(
        IEnumerable<DatasetManualAssociationV1> associations,
        DateTimeOffset updatedAt)
    {
        ManualAssociations = CanonicalAssociations(associations);
        UpdatedAt = updatedAt;
    }

    public void ReplaceHiddenDATPaths(
        IEnumerable<DatasetRelativePath> paths,
        DateTimeOffset updatedAt)
    {
        HiddenDATPaths = MetadataCanonical.OrderedUnique(
            paths,
            p => p.Validated(DatasetFileKind.Dat)).ToList();
        UpdatedAt = updatedAt;
    }

    public void ReplaceSpectrumAxisPreferences(
        IEnumerable<SpectrumAxisPreferenceV1> preferences,
        DateTimeOffset updatedAt)
    {
        SpectrumAxisPreferences = CanonicalAxisPreferences(preferences);
        UpdatedAt = updatedAt;
    }

    public DatasetTagV1 CreateTag(
        Guid? id,
        string name,
        IEnumerable<DatasetRelativePath>? sxmPaths = null)
    {
        Guid tagId = id ?? Guid.NewGuid();
        if (Tags.Any(t => t.Id == tagId))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.DuplicateTagId,
                $"Tag ID {tagId.ToString("D").ToUpperInvariant()} occurs more than once.");
        }
        var tag = new DatasetTagV1(tagId, name, sxmPaths);
        EnsureUniqueTagName(tag.Name, excludingId: null);
        Tags.Add(tag);
        return tag;
    }

    public void RenameTag(Guid id, string name)
    {
        int index = Tags.FindIndex(t => t.Id == id);
        if (index < 0)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.TagNotFound,
                $"Tag {id.ToString("D").ToUpperInvariant()} does not exist.");
        }
        var renamed = new DatasetTagV1(Tags[index].Id, name, Tags[index].SxmPaths);
        EnsureUniqueTagName(renamed.Name, excludingId: id);
        Tags[index] = renamed;
    }

    public DatasetTagV1? DeleteTag(Guid id)
    {
        int index = Tags.FindIndex(t => t.Id == id);
        if (index < 0) return null;
        DatasetTagV1 removed = Tags[index];
        Tags.RemoveAt(index);
        return removed;
    }

    public void ReplaceTagMembers(Guid id, IEnumerable<DatasetRelativePath> sxmPaths)
    {
        int index = Tags.FindIndex(t => t.Id == id);
        if (index < 0)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.TagNotFound,
                $"Tag {id.ToString("D").ToUpperInvariant()} does not exist.");
        }
        Tags[index] = new DatasetTagV1(Tags[index].Id, Tags[index].Name, sxmPaths);
    }

    public DatasetTagV1 MergeTag(
        Guid? id,
        string name,
        IEnumerable<DatasetRelativePath> sxmPaths)
    {
        Guid candidateId = id ?? Guid.NewGuid();
        var candidate = new DatasetTagV1(candidateId, name, sxmPaths);
        string comparisonKey = MetadataCanonical.CanonicalTagComparisonKey(candidate.Name);

        int existingIndex = Tags.FindIndex(t =>
            string.Equals(
                MetadataCanonical.CanonicalTagComparisonKey(t.Name),
                comparisonKey,
                StringComparison.Ordinal));
        if (existingIndex >= 0)
        {
            DatasetTagV1 existing = Tags[existingIndex];
            var merged = new DatasetTagV1(
                existing.Id,
                existing.Name,
                existing.SxmPaths.Concat(candidate.SxmPaths));
            Tags[existingIndex] = merged;
            return merged;
        }

        if (Tags.Any(t => t.Id == candidate.Id))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.DuplicateTagId,
                $"Tag ID {candidate.Id.ToString("D").ToUpperInvariant()} occurs more than once.");
        }
        Tags.Add(candidate);
        return candidate;
    }

    public void MoveTag(Guid id, int destinationIndex)
    {
        int sourceIndex = Tags.FindIndex(t => t.Id == id);
        if (sourceIndex < 0)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.TagNotFound,
                $"Tag {id.ToString("D").ToUpperInvariant()} does not exist.");
        }
        if (destinationIndex < 0 || destinationIndex >= Tags.Count)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.TagIndexOutOfBounds,
                $"Tag position {destinationIndex} is outside the valid range.");
        }
        if (sourceIndex == destinationIndex) return;
        DatasetTagV1 tag = Tags[sourceIndex];
        Tags.RemoveAt(sourceIndex);
        Tags.Insert(destinationIndex, tag);
    }

    public void SortTagsByName()
    {
        Tags.Sort((lhs, rhs) =>
        {
            string lk = MetadataCanonical.CanonicalTagComparisonKey(lhs.Name);
            string rk = MetadataCanonical.CanonicalTagComparisonKey(rhs.Name);
            int cmp = string.CompareOrdinal(lk, rk);
            if (cmp != 0) return cmp;
            return string.CompareOrdinal(
                lhs.Id.ToString("D").ToUpperInvariant(),
                rhs.Id.ToString("D").ToUpperInvariant());
        });
    }

    private void EnsureUniqueTagName(string name, Guid? excludingId)
    {
        string key = MetadataCanonical.CanonicalTagComparisonKey(name);
        if (Tags.Any(t =>
            t.Id != excludingId
            && string.Equals(MetadataCanonical.CanonicalTagComparisonKey(t.Name), key, StringComparison.Ordinal)))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.DuplicateTagName,
                $"Tag name \u201C{name}\u201D conflicts with an existing tag.");
        }
    }

    private static List<DatasetTagV1> ValidateTags(IEnumerable<DatasetTagV1> tags)
    {
        var seenIds = new HashSet<Guid>();
        var seenNames = new HashSet<string>(StringComparer.Ordinal);
        var list = new List<DatasetTagV1>();
        foreach (DatasetTagV1 tag in tags)
        {
            if (!seenIds.Add(tag.Id))
            {
                throw new DatasetMetadataValidationException(
                    DatasetMetadataValidationErrorKind.DuplicateTagId,
                    $"Tag ID {tag.Id.ToString("D").ToUpperInvariant()} occurs more than once.");
            }
            string key = MetadataCanonical.CanonicalTagComparisonKey(tag.Name);
            if (!seenNames.Add(key))
            {
                throw new DatasetMetadataValidationException(
                    DatasetMetadataValidationErrorKind.DuplicateTagName,
                    $"Tag name \u201C{tag.Name}\u201D conflicts with an existing tag.");
            }
            list.Add(tag);
        }
        return list;
    }

    private static List<DatasetManualAssociationV1> CanonicalAssociations(
        IEnumerable<DatasetManualAssociationV1> associations)
    {
        var targetByDat = new Dictionary<DatasetRelativePath, DatasetRelativePath>();
        var result = new List<DatasetManualAssociationV1>();
        foreach (DatasetManualAssociationV1 assoc in associations)
        {
            assoc.DatPath.Validated(DatasetFileKind.Dat);
            assoc.SxmPath.Validated(DatasetFileKind.Sxm);
            if (targetByDat.TryGetValue(assoc.DatPath, out DatasetRelativePath? existing))
            {
                if (!existing.Equals(assoc.SxmPath))
                {
                    throw new DatasetMetadataValidationException(
                        DatasetMetadataValidationErrorKind.ConflictingManualAssociation,
                        $"DAT file \u201C{assoc.DatPath.RawValue}\u201D has multiple manual SXM associations.");
                }
                continue;
            }
            targetByDat[assoc.DatPath] = assoc.SxmPath;
            result.Add(assoc);
        }
        return result;
    }

    private static List<SpectrumAxisPreferenceV1> CanonicalAxisPreferences(
        IEnumerable<SpectrumAxisPreferenceV1> preferences)
    {
        var selectionByKey = new Dictionary<SpectrumAxisPreferenceKeyV1, AxisSelection>();
        var result = new List<SpectrumAxisPreferenceV1>();
        foreach (SpectrumAxisPreferenceV1 pref in preferences)
        {
            if (selectionByKey.TryGetValue(pref.Key, out AxisSelection? existing))
            {
                if (!existing.Equals(pref.Selection))
                {
                    throw new DatasetMetadataValidationException(
                        DatasetMetadataValidationErrorKind.ConflictingAxisPreference,
                        $"Spectrum group \u201C{pref.Key.StableIdentifier}\u201D has conflicting axis preferences.");
                }
                continue;
            }
            selectionByKey[pref.Key] = pref.Selection;
            result.Add(pref);
        }
        return result;
    }

    public bool Equals(DatasetRecordV1? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        bool bookmarkEq = FolderBookmark is null && other.FolderBookmark is null
            || (FolderBookmark is not null && other.FolderBookmark is not null
                && FolderBookmark.AsSpan().SequenceEqual(other.FolderBookmark));
        return Id == other.Id
            && bookmarkEq
            && string.Equals(LastKnownPath, other.LastKnownPath, StringComparison.Ordinal)
            && Tags.SequenceEqual(other.Tags)
            && ManualAssociations.SequenceEqual(other.ManualAssociations)
            && HiddenDATPaths.SequenceEqual(other.HiddenDATPaths)
            && SpectrumAxisPreferences.SequenceEqual(other.SpectrumAxisPreferences)
            && UpdatedAt.ToUnixTimeMilliseconds() == other.UpdatedAt.ToUnixTimeMilliseconds();
    }

    public override bool Equals(object? obj) => Equals(obj as DatasetRecordV1);
    public override int GetHashCode() => Id.GetHashCode();
}

public sealed class DatasetMetadataDocumentV1 : IEquatable<DatasetMetadataDocumentV1>
{
    public const int CurrentSchemaVersion = 1;

    public int SchemaVersion { get; }
    public Guid? LastOpenedDatasetId { get; private set; }
    public List<DatasetRecordV1> Datasets { get; }

    public DatasetMetadataDocumentV1(
        int schemaVersion = CurrentSchemaVersion,
        Guid? lastOpenedDatasetId = null,
        IEnumerable<DatasetRecordV1>? datasets = null)
    {
        if (schemaVersion != CurrentSchemaVersion)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.UnsupportedSchemaVersion,
                $"Unsupported metadata schema version {schemaVersion}.",
                schemaVersion.ToString(CultureInfo.InvariantCulture));
        }

        var list = new List<DatasetRecordV1>();
        var seenIds = new HashSet<Guid>();
        if (datasets is not null)
        {
            foreach (DatasetRecordV1 dataset in datasets)
            {
                if (!seenIds.Add(dataset.Id))
                {
                    throw new DatasetMetadataValidationException(
                        DatasetMetadataValidationErrorKind.DuplicateDatasetId,
                        $"Dataset ID {dataset.Id.ToString("D").ToUpperInvariant()} occurs more than once.");
                }
                list.Add(dataset.Clone());
            }
        }

        if (lastOpenedDatasetId is { } lastId && !seenIds.Contains(lastId))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.LastOpenedDatasetMissing,
                $"Last-opened dataset {lastId.ToString("D").ToUpperInvariant()} is not in this document.");
        }

        SchemaVersion = schemaVersion;
        LastOpenedDatasetId = lastOpenedDatasetId;
        Datasets = list;
    }

    public DatasetMetadataDocumentV1 Clone() =>
        new(SchemaVersion, LastOpenedDatasetId, Datasets);

    public void UpsertDataset(DatasetRecordV1 dataset)
    {
        int index = Datasets.FindIndex(d => d.Id == dataset.Id);
        if (index >= 0)
        {
            Datasets[index] = dataset;
        }
        else
        {
            Datasets.Add(dataset);
        }
    }

    public void ReplaceDataset(DatasetRecordV1 dataset)
    {
        int index = Datasets.FindIndex(d => d.Id == dataset.Id);
        if (index < 0)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.DatasetNotFound,
                $"Dataset {dataset.Id.ToString("D").ToUpperInvariant()} does not exist.");
        }
        Datasets[index] = dataset;
    }

    public DatasetRecordV1? RemoveDataset(Guid id)
    {
        int index = Datasets.FindIndex(d => d.Id == id);
        if (index < 0) return null;
        DatasetRecordV1 removed = Datasets[index];
        Datasets.RemoveAt(index);
        if (LastOpenedDatasetId == id)
        {
            LastOpenedDatasetId = null;
        }
        return removed;
    }

    public void SetLastOpenedDatasetId(Guid? id)
    {
        if (id is { } targetId && !Datasets.Any(d => d.Id == targetId))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.LastOpenedDatasetMissing,
                $"Last-opened dataset {targetId.ToString("D").ToUpperInvariant()} is not in this document.");
        }
        LastOpenedDatasetId = id;
    }

    public bool Equals(DatasetMetadataDocumentV1? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return SchemaVersion == other.SchemaVersion
            && LastOpenedDatasetId == other.LastOpenedDatasetId
            && Datasets.SequenceEqual(other.Datasets);
    }

    public override bool Equals(object? obj) => Equals(obj as DatasetMetadataDocumentV1);
    public override int GetHashCode() => HashCode.Combine(SchemaVersion, LastOpenedDatasetId, Datasets.Count);
}

public static class MetadataCanonical
{
    public static string SafeNormalizeNfc(string value)
    {
        try
        {
            return value.Normalize(NormalizationForm.FormC);
        }
        catch (ArgumentException)
        {
            return value;
        }
    }

    public static string CanonicalTagName(string name)
    {
        string canonical = SafeNormalizeNfc(name).Trim();
        if (canonical.Length == 0 || canonical.Contains('\0'))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidTagName,
                "A tag name cannot be empty or contain a NUL character.");
        }
        return canonical;
    }

    public static string CanonicalTagComparisonKey(string name)
        => SafeNormalizeNfc(name).ToLowerInvariant();

    public static string CanonicalDatasetFolderPath(string path)
    {
        string canonical = SafeNormalizeNfc(path);
        bool validRoot = canonical.StartsWith('/') || Path.IsPathFullyQualified(canonical);
        if (!validRoot || canonical.Length == 0 || canonical.Contains('\0'))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidLastKnownPath,
                $"The last-known dataset path is invalid: \u201C{path}\u201D.");
        }
        return canonical;
    }

    public static string CanonicalSchemaFingerprint(string fingerprint)
    {
        string canonical = fingerprint.Trim().ToLowerInvariant();
        if (canonical.Length != 16)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidSchemaFingerprint,
                $"\u201C{fingerprint}\u201D is not a valid spectroscopy schema fingerprint.");
        }
        foreach (char c in canonical)
        {
            bool isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            if (!isHex)
            {
                throw new DatasetMetadataValidationException(
                    DatasetMetadataValidationErrorKind.InvalidSchemaFingerprint,
                    $"\u201C{fingerprint}\u201D is not a valid spectroscopy schema fingerprint.");
            }
        }
        return canonical;
    }

    public static string CanonicalAxisColumn(string column)
    {
        string canonical = SafeNormalizeNfc(column).Trim();
        if (canonical.Length == 0 || canonical.Contains('\0'))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidAxisColumn,
                "A spectrum axis column cannot be empty or contain a NUL character.");
        }
        return canonical;
    }

    internal static IReadOnlyList<T> OrderedUnique<T>(
        IEnumerable<T> values,
        Func<T, T> validate)
    {
        var seen = new HashSet<T>();
        var result = new List<T>();
        foreach (T value in values)
        {
            T validated = validate(value);
            if (seen.Add(validated))
            {
                result.Add(validated);
            }
        }
        return result;
    }
}
