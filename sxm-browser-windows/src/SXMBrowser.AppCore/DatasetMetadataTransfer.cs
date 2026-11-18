using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public enum DatasetMetadataTransferErrorKind
{
    EmptyPayload,
    PayloadTooLarge,
    UnsupportedFilePath,
    NotRegularFile,
    FileReadFailed,
    MalformedJson,
    MissingField,
    TypeMismatch,
    UnknownField,
    InvalidFormatIdentifier,
    UnsupportedFormatVersion,
    InvalidUuid,
    NonCanonicalUuid,
    InvalidValue,
    NonCanonicalValue,
    DuplicateEntry,
    ConflictingEntry,
    InvalidMetadata,
    EncodingFailed
}

public sealed class DatasetMetadataTransferException : Exception
{
    public DatasetMetadataTransferErrorKind Kind { get; }

    public DatasetMetadataTransferException(
        DatasetMetadataTransferErrorKind kind,
        string message,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
    }
}

public sealed class DatasetMetadataTransferV1 : IEquatable<DatasetMetadataTransferV1>
{
    public const string FormatIdentifier = "com.sxmbrowser.dataset-metadata";
    public const int CurrentFormatVersion = 1;

    public IReadOnlyList<DatasetTagV1> Tags { get; }
    public IReadOnlyList<DatasetManualAssociationV1> ManualAssociations { get; }
    public IReadOnlyList<DatasetRelativePath> HiddenDATPaths { get; }
    public IReadOnlyList<SpectrumAxisPreferenceV1> SpectrumAxisPreferences { get; }

    public DatasetMetadataTransferV1(DatasetRecordV1 exporting)
        : this(
            exporting.Tags,
            exporting.ManualAssociations,
            exporting.HiddenDATPaths,
            exporting.SpectrumAxisPreferences)
    {
    }

    public DatasetMetadataTransferV1(
        IEnumerable<DatasetTagV1> tags,
        IEnumerable<DatasetManualAssociationV1> manualAssociations,
        IEnumerable<DatasetRelativePath> hiddenDATPaths,
        IEnumerable<SpectrumAxisPreferenceV1> spectrumAxisPreferences)
    {
        var tagList = tags.ToList();
        var assocList = manualAssociations.ToList();
        var hiddenList = hiddenDATPaths.ToList();
        var axisList = spectrumAxisPreferences.ToList();

        RejectDuplicateTags(tagList);
        RejectDuplicateAssociations(assocList);
        RejectDuplicateHiddenPaths(hiddenList);
        RejectDuplicateAxisPreferences(axisList);

        DatasetRecordV1 validated;
        try
        {
            validated = new DatasetRecordV1(
                id: Guid.Empty,
                folderBookmark: null,
                lastKnownPath: "/",
                tags: tagList,
                manualAssociations: assocList,
                hiddenDATPaths: hiddenList,
                spectrumAxisPreferences: axisList,
                updatedAt: DateTimeOffset.UnixEpoch);
        }
        catch (DatasetMetadataValidationException ex)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.InvalidMetadata,
                $"Invalid metadata at $: {ex.Message}",
                ex);
        }

        try
        {
            Tags = validated.Tags
                .Select(t => new DatasetTagV1(t.Id, t.Name, t.SxmPaths.OrderBy(p => p)))
                .ToArray();
        }
        catch (DatasetMetadataValidationException ex)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.InvalidMetadata,
                $"Invalid metadata at $.tags: {ex.Message}",
                ex);
        }

        ManualAssociations = validated.ManualAssociations
            .OrderBy(a => a.DatPath)
            .ThenBy(a => a.SxmPath)
            .ToArray();
        HiddenDATPaths = validated.HiddenDATPaths
            .OrderBy(p => p)
            .ToArray();
        SpectrumAxisPreferences = validated.SpectrumAxisPreferences
            .OrderBy(p => p, Comparer<SpectrumAxisPreferenceV1>.Create(CompareAxisPreferences))
            .ToArray();
    }

    private static int CompareAxisPreferences(SpectrumAxisPreferenceV1 lhs, SpectrumAxisPreferenceV1 rhs)
    {
        int cmp = lhs.Key.SxmPath.CompareTo(rhs.Key.SxmPath);
        if (cmp != 0) return cmp;
        cmp = string.CompareOrdinal(lhs.Key.Kind.ToRawValue(), rhs.Key.Kind.ToRawValue());
        if (cmp != 0) return cmp;
        cmp = string.CompareOrdinal(lhs.Key.ExperimentIdentity ?? "", rhs.Key.ExperimentIdentity ?? "");
        if (cmp != 0) return cmp;
        cmp = string.CompareOrdinal(lhs.Key.SchemaFingerprint, rhs.Key.SchemaFingerprint);
        if (cmp != 0) return cmp;
        cmp = string.CompareOrdinal(lhs.Selection.XColumn, rhs.Selection.XColumn);
        if (cmp != 0) return cmp;
        return string.CompareOrdinal(lhs.Selection.YColumn, rhs.Selection.YColumn);
    }

    private static void RejectDuplicateTags(List<DatasetTagV1> tags)
    {
        var seenIds = new HashSet<Guid>();
        var seenNames = new HashSet<string>(StringComparer.Ordinal);
        for (int i = 0; i < tags.Count; i++)
        {
            string path = $"$.tags[{i}]";
            if (!seenIds.Add(tags[i].Id))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.DuplicateEntry,
                    $"Duplicate entry \u201C{tags[i].Id.ToString("D").ToLowerInvariant()}\u201D at {path}.");
            }
            string key = MetadataCanonical.CanonicalTagComparisonKey(tags[i].Name);
            if (!seenNames.Add(key))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.DuplicateEntry,
                    $"Duplicate entry \u201C{tags[i].Name}\u201D at {path}.");
            }
        }
    }

    private static void RejectDuplicateAssociations(List<DatasetManualAssociationV1> associations)
    {
        var targetByDat = new Dictionary<DatasetRelativePath, DatasetRelativePath>();
        for (int i = 0; i < associations.Count; i++)
        {
            DatasetManualAssociationV1 a = associations[i];
            if (targetByDat.TryGetValue(a.DatPath, out DatasetRelativePath? existing))
            {
                string path = $"$.manualAssociations[{i}]";
                if (existing.Equals(a.SxmPath))
                {
                    throw new DatasetMetadataTransferException(
                        DatasetMetadataTransferErrorKind.DuplicateEntry,
                        $"Duplicate entry \u201C{a.DatPath.RawValue}\u201D at {path}.");
                }
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.ConflictingEntry,
                    $"Conflicting entry \u201C{a.DatPath.RawValue}\u201D at {path}.");
            }
            targetByDat[a.DatPath] = a.SxmPath;
        }
    }

    private static void RejectDuplicateHiddenPaths(List<DatasetRelativePath> paths)
    {
        var seen = new HashSet<DatasetRelativePath>();
        for (int i = 0; i < paths.Count; i++)
        {
            if (!seen.Add(paths[i]))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.DuplicateEntry,
                    $"Duplicate entry \u201C{paths[i].RawValue}\u201D at $.hiddenDATPaths[{i}].");
            }
        }
    }

    private static void RejectDuplicateAxisPreferences(List<SpectrumAxisPreferenceV1> preferences)
    {
        var selectionByKey = new Dictionary<SpectrumAxisPreferenceKeyV1, AxisSelection>();
        for (int i = 0; i < preferences.Count; i++)
        {
            SpectrumAxisPreferenceV1 p = preferences[i];
            if (selectionByKey.TryGetValue(p.Key, out AxisSelection? existing))
            {
                string path = $"$.spectrumAxisPreferences[{i}]";
                if (existing.Equals(p.Selection))
                {
                    throw new DatasetMetadataTransferException(
                        DatasetMetadataTransferErrorKind.DuplicateEntry,
                        $"Duplicate entry \u201C{p.Key.StableIdentifier}\u201D at {path}.");
                }
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.ConflictingEntry,
                    $"Conflicting entry \u201C{p.Key.StableIdentifier}\u201D at {path}.");
            }
            selectionByKey[p.Key] = p.Selection;
        }
    }

    public bool Equals(DatasetMetadataTransferV1? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return Tags.SequenceEqual(other.Tags)
            && ManualAssociations.SequenceEqual(other.ManualAssociations)
            && HiddenDATPaths.SequenceEqual(other.HiddenDATPaths)
            && SpectrumAxisPreferences.SequenceEqual(other.SpectrumAxisPreferences);
    }

    public override bool Equals(object? obj) => Equals(obj as DatasetMetadataTransferV1);
    public override int GetHashCode() =>
        HashCode.Combine(Tags.Count, ManualAssociations.Count, HiddenDATPaths.Count, SpectrumAxisPreferences.Count);
}

/// <summary>
/// Strict portable JSON codec compatible 100% byte-for-byte with macOS v2.6.0 transfer files.
/// </summary>
public sealed class DatasetMetadataTransferCodec
{
    public const int MaximumByteCount = 16 * 1024 * 1024;
    private const int ReadChunkByteCount = 64 * 1024;

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = false,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private static readonly string[] RootAllowedKeys =
    [
        "formatIdentifier",
        "formatVersion",
        "hiddenDATPaths",
        "manualAssociations",
        "spectrumAxisPreferences",
        "tags"
    ];

    private static readonly string[] TagAllowedKeys = ["id", "name", "sxmPaths"];
    private static readonly string[] AssocAllowedKeys = ["datPath", "sxmPath"];
    private static readonly string[] AxisAllowedKeys =
        ["experimentIdentity", "kind", "schemaFingerprint", "sxmPath", "xColumn", "yColumn"];

    public byte[] Encode(DatasetMetadataTransferV1 transfer)
    {
        byte[] data;
        try
        {
            using var ms = new MemoryStream();
            using (var writer = new Utf8JsonWriter(ms, WriterOptions))
            {
                writer.WriteStartObject();
                // Sorted keys: formatIdentifier, formatVersion, hiddenDATPaths, manualAssociations, spectrumAxisPreferences, tags
                writer.WriteString("formatIdentifier", DatasetMetadataTransferV1.FormatIdentifier);
                writer.WriteNumber("formatVersion", DatasetMetadataTransferV1.CurrentFormatVersion);

                writer.WritePropertyName("hiddenDATPaths");
                writer.WriteStartArray();
                foreach (DatasetRelativePath p in transfer.HiddenDATPaths)
                {
                    writer.WriteStringValue(p.RawValue);
                }
                writer.WriteEndArray();

                writer.WritePropertyName("manualAssociations");
                writer.WriteStartArray();
                foreach (DatasetManualAssociationV1 a in transfer.ManualAssociations)
                {
                    writer.WriteStartObject();
                    writer.WriteString("datPath", a.DatPath.RawValue);
                    writer.WriteString("sxmPath", a.SxmPath.RawValue);
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();

                writer.WritePropertyName("spectrumAxisPreferences");
                writer.WriteStartArray();
                foreach (SpectrumAxisPreferenceV1 pref in transfer.SpectrumAxisPreferences)
                {
                    writer.WriteStartObject();
                    if (pref.Key.ExperimentIdentity is not null)
                    {
                        writer.WriteString("experimentIdentity", pref.Key.ExperimentIdentity);
                    }
                    writer.WriteString("kind", pref.Key.Kind.ToRawValue());
                    writer.WriteString("schemaFingerprint", pref.Key.SchemaFingerprint);
                    writer.WriteString("sxmPath", pref.Key.SxmPath.RawValue);
                    writer.WriteString("xColumn", pref.Selection.XColumn);
                    writer.WriteString("yColumn", pref.Selection.YColumn);
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();

                writer.WritePropertyName("tags");
                writer.WriteStartArray();
                foreach (DatasetTagV1 tag in transfer.Tags)
                {
                    writer.WriteStartObject();
                    writer.WriteString("id", tag.Id.ToString("D").ToLowerInvariant());
                    writer.WriteString("name", tag.Name);
                    writer.WritePropertyName("sxmPaths");
                    writer.WriteStartArray();
                    foreach (DatasetRelativePath p in tag.SxmPaths)
                    {
                        writer.WriteStringValue(p.RawValue);
                    }
                    writer.WriteEndArray();
                    writer.WriteEndObject();
                }
                writer.WriteEndArray();

                writer.WriteEndObject();
            }
            data = ms.ToArray();
        }
        catch (Exception ex) when (ex is not DatasetMetadataTransferException)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.EncodingFailed,
                $"Could not encode metadata transfer: {ex.Message}",
                ex);
        }

        if (data.Length > MaximumByteCount)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.PayloadTooLarge,
                $"The metadata transfer contains {data.Length} bytes; the limit is {MaximumByteCount} bytes.");
        }
        return data;
    }

    public DatasetMetadataTransferV1 DecodeFromFile(string filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath))
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.UnsupportedFilePath,
                $"The metadata transfer path is invalid: {filePath}");
        }

        string fullPath = Path.GetFullPath(filePath);
        FileInfo info = new(fullPath);
        if (!info.Exists)
        {
            if (Directory.Exists(fullPath))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.NotRegularFile,
                    $"The metadata transfer is not a regular file: {fullPath}.");
            }
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.FileReadFailed,
                $"Could not read metadata transfer at {fullPath}: File not found.");
        }
        if ((info.Attributes & FileAttributes.Directory) != 0)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.NotRegularFile,
                $"The metadata transfer is not a regular file: {fullPath}.");
        }
        if (info.Length > MaximumByteCount)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.PayloadTooLarge,
                $"The metadata transfer contains {info.Length} bytes; the limit is {MaximumByteCount} bytes.");
        }

        byte[] data;
        try
        {
            using var fs = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            using var ms = new MemoryStream((int)Math.Min(info.Length, MaximumByteCount));
            byte[] chunk = new byte[ReadChunkByteCount];
            int total = 0;
            while (total <= MaximumByteCount)
            {
                int n = fs.Read(chunk, 0, Math.Min(chunk.Length, (MaximumByteCount + 1) - total));
                if (n <= 0) break;
                total += n;
                if (total > MaximumByteCount)
                {
                    throw new DatasetMetadataTransferException(
                        DatasetMetadataTransferErrorKind.PayloadTooLarge,
                        $"The metadata transfer contains {total} bytes; the limit is {MaximumByteCount} bytes.");
                }
                ms.Write(chunk, 0, n);
            }
            data = ms.ToArray();
        }
        catch (DatasetMetadataTransferException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.FileReadFailed,
                $"Could not read metadata transfer at {fullPath}: {ex.Message}",
                ex);
        }

        return Decode(data);
    }

    public DatasetMetadataTransferV1 Decode(ReadOnlySpan<byte> data)
    {
        if (data.IsEmpty)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.EmptyPayload,
                "The metadata transfer file is empty.");
        }
        if (data.Length > MaximumByteCount)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.PayloadTooLarge,
                $"The metadata transfer contains {data.Length} bytes; the limit is {MaximumByteCount} bytes.");
        }

        JsonDocument doc;
        try
        {
            var reader = new Utf8JsonReader(data, new JsonReaderOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow
            });
            doc = JsonDocument.ParseValue(ref reader);
        }
        catch (JsonException ex)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.MalformedJson,
                $"Malformed JSON at $: {ex.Message}",
                ex);
        }

        using (doc)
        {
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.TypeMismatch,
                    "Expected JSON object at $.");
            }
            RejectUnknownFields(root, RootAllowedKeys, "$");

            string formatId = RequireString(root, "formatIdentifier", "$");
            if (!string.Equals(formatId, DatasetMetadataTransferV1.FormatIdentifier, StringComparison.Ordinal))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.InvalidFormatIdentifier,
                    $"Unsupported metadata transfer identifier \u201C{formatId}\u201D.");
            }

            int version = RequireInt32(root, "formatVersion", "$");
            if (version != DatasetMetadataTransferV1.CurrentFormatVersion)
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.UnsupportedFormatVersion,
                    $"Unsupported metadata transfer version {version}.");
            }

            List<DatasetTagV1> tags = DecodeTags(RequireArray(root, "tags", "$"));
            List<DatasetManualAssociationV1> associations =
                DecodeAssociations(RequireArray(root, "manualAssociations", "$"));
            List<DatasetRelativePath> hiddenDatPaths =
                DecodeHiddenPaths(RequireArray(root, "hiddenDATPaths", "$"));
            List<SpectrumAxisPreferenceV1> axisPrefs =
                DecodeAxisPreferences(RequireArray(root, "spectrumAxisPreferences", "$"));

            return new DatasetMetadataTransferV1(tags, associations, hiddenDatPaths, axisPrefs);
        }
    }

    private static List<DatasetTagV1> DecodeTags(JsonElement array)
    {
        var tags = new List<DatasetTagV1>();
        var seenIds = new HashSet<Guid>();
        var seenNames = new HashSet<string>(StringComparer.Ordinal);
        int tagIndex = 0;

        foreach (JsonElement tagEl in array.EnumerateArray())
        {
            string path = $"$.tags[{tagIndex}]";
            tagIndex++;
            if (tagEl.ValueKind != JsonValueKind.Object)
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.TypeMismatch,
                    $"Expected JSON object at {path}.");
            }
            RejectUnknownFields(tagEl, TagAllowedKeys, path);

            string rawId = RequireString(tagEl, "id", path);
            if (!Guid.TryParseExact(rawId, "D", out Guid id))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.InvalidUuid,
                    $"\u201C{rawId}\u201D is not a UUID at {path}.id.");
            }
            string canonicalId = id.ToString("D").ToLowerInvariant();
            if (!StringsHaveIdenticalUtf8(rawId, canonicalId))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.NonCanonicalUuid,
                    $"UUID \u201C{rawId}\u201D is not lowercase canonical form at {path}.id.");
            }
            if (!seenIds.Add(id))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.DuplicateEntry,
                    $"Duplicate entry \u201C{canonicalId}\u201D at {path}.");
            }

            string rawName = RequireString(tagEl, "name", path);
            string canonicalName = MapValidationError($"{path}.name", () => MetadataCanonical.CanonicalTagName(rawName));
            RequireCanonical(rawName, canonicalName, $"{path}.name");
            string nameKey = MetadataCanonical.CanonicalTagComparisonKey(canonicalName);
            if (!seenNames.Add(nameKey))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.DuplicateEntry,
                    $"Duplicate entry \u201C{canonicalName}\u201D at {path}.");
            }

            JsonElement pathsEl = RequireArray(tagEl, "sxmPaths", path);
            var sxmPaths = new List<DatasetRelativePath>();
            var seenPaths = new HashSet<DatasetRelativePath>();
            int memberIndex = 0;
            foreach (JsonElement memberEl in pathsEl.EnumerateArray())
            {
                string memberPath = $"{path}.sxmPaths[{memberIndex}]";
                memberIndex++;
                if (memberEl.ValueKind != JsonValueKind.String)
                {
                    throw new DatasetMetadataTransferException(
                        DatasetMetadataTransferErrorKind.TypeMismatch,
                        $"Expected string at {memberPath}.");
                }
                string rawPath = memberEl.GetString()!;
                DatasetRelativePath sxmPath = CanonicalSxmPath(rawPath, memberPath);
                if (!seenPaths.Add(sxmPath))
                {
                    throw new DatasetMetadataTransferException(
                        DatasetMetadataTransferErrorKind.DuplicateEntry,
                        $"Duplicate entry \u201C{sxmPath.RawValue}\u201D at {memberPath}.");
                }
                sxmPaths.Add(sxmPath);
            }

            tags.Add(MapValidationError(path, () => new DatasetTagV1(id, canonicalName, sxmPaths)));
        }

        return tags;
    }

    private static List<DatasetManualAssociationV1> DecodeAssociations(JsonElement array)
    {
        var associations = new List<DatasetManualAssociationV1>();
        var targetByDat = new Dictionary<DatasetRelativePath, DatasetRelativePath>();
        int index = 0;

        foreach (JsonElement el in array.EnumerateArray())
        {
            string path = $"$.manualAssociations[{index}]";
            index++;
            if (el.ValueKind != JsonValueKind.Object)
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.TypeMismatch,
                    $"Expected JSON object at {path}.");
            }
            RejectUnknownFields(el, AssocAllowedKeys, path);

            string rawDat = RequireString(el, "datPath", path);
            string rawSxm = RequireString(el, "sxmPath", path);
            DatasetRelativePath datPath = CanonicalDatPath(rawDat, $"{path}.datPath");
            DatasetRelativePath sxmPath = CanonicalSxmPath(rawSxm, $"{path}.sxmPath");

            if (targetByDat.TryGetValue(datPath, out DatasetRelativePath? existing))
            {
                if (existing.Equals(sxmPath))
                {
                    throw new DatasetMetadataTransferException(
                        DatasetMetadataTransferErrorKind.DuplicateEntry,
                        $"Duplicate entry \u201C{datPath.RawValue}\u201D at {path}.");
                }
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.ConflictingEntry,
                    $"Conflicting entry \u201C{datPath.RawValue}\u201D at {path}.");
            }
            targetByDat[datPath] = sxmPath;
            associations.Add(MapValidationError(path, () => new DatasetManualAssociationV1(datPath, sxmPath)));
        }

        return associations;
    }

    private static List<DatasetRelativePath> DecodeHiddenPaths(JsonElement array)
    {
        var hidden = new List<DatasetRelativePath>();
        var seen = new HashSet<DatasetRelativePath>();
        int index = 0;

        foreach (JsonElement el in array.EnumerateArray())
        {
            string path = $"$.hiddenDATPaths[{index}]";
            index++;
            if (el.ValueKind != JsonValueKind.String)
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.TypeMismatch,
                    $"Expected string at {path}.");
            }
            DatasetRelativePath datPath = CanonicalDatPath(el.GetString()!, path);
            if (!seen.Add(datPath))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.DuplicateEntry,
                    $"Duplicate entry \u201C{datPath.RawValue}\u201D at {path}.");
            }
            hidden.Add(datPath);
        }

        return hidden;
    }

    private static List<SpectrumAxisPreferenceV1> DecodeAxisPreferences(JsonElement array)
    {
        var prefs = new List<SpectrumAxisPreferenceV1>();
        var selectionByKey = new Dictionary<SpectrumAxisPreferenceKeyV1, AxisSelection>();
        int index = 0;

        foreach (JsonElement el in array.EnumerateArray())
        {
            string path = $"$.spectrumAxisPreferences[{index}]";
            index++;
            if (el.ValueKind != JsonValueKind.Object)
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.TypeMismatch,
                    $"Expected JSON object at {path}.");
            }
            RejectUnknownFields(el, AxisAllowedKeys, path);

            string rawSxm = RequireString(el, "sxmPath", path);
            DatasetRelativePath sxmPath = CanonicalSxmPath(rawSxm, $"{path}.sxmPath");

            string rawKind = RequireString(el, "kind", path);
            if (!SpectroscopyKindExtensions.TryParse(rawKind, out SpectroscopyKind kind))
            {
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.InvalidValue,
                    $"\u201C{rawKind}\u201D is not a valid value at {path}.kind.");
            }

            string? rawExpId = OptionalString(el, "experimentIdentity", path);
            string rawFp = RequireString(el, "schemaFingerprint", path);
            string rawX = RequireString(el, "xColumn", path);
            string rawY = RequireString(el, "yColumn", path);

            SpectrumAxisPreferenceKeyV1 key = MapValidationError(
                $"{path}.schemaFingerprint",
                () => new SpectrumAxisPreferenceKeyV1(sxmPath, kind, rawExpId, rawFp));
            if (rawExpId is not null)
            {
                RequireCanonical(rawExpId, key.ExperimentIdentity ?? string.Empty, $"{path}.experimentIdentity");
            }
            RequireCanonical(rawFp, key.SchemaFingerprint, $"{path}.schemaFingerprint");

            SpectrumAxisPreferenceV1 pref = MapValidationError(
                path,
                () => new SpectrumAxisPreferenceV1(key, new AxisSelection(rawX, rawY)));
            RequireCanonical(rawX, pref.Selection.XColumn, $"{path}.xColumn");
            RequireCanonical(rawY, pref.Selection.YColumn, $"{path}.yColumn");

            if (selectionByKey.TryGetValue(key, out AxisSelection? existing))
            {
                if (existing.Equals(pref.Selection))
                {
                    throw new DatasetMetadataTransferException(
                        DatasetMetadataTransferErrorKind.DuplicateEntry,
                        $"Duplicate entry \u201C{key.StableIdentifier}\u201D at {path}.");
                }
                throw new DatasetMetadataTransferException(
                    DatasetMetadataTransferErrorKind.ConflictingEntry,
                    $"Conflicting entry \u201C{key.StableIdentifier}\u201D at {path}.");
            }

            selectionByKey[key] = pref.Selection;
            prefs.Add(pref);
        }

        return prefs;
    }

    private static void RejectUnknownFields(JsonElement obj, string[] allowed, string path)
    {
        var allowedSet = new HashSet<string>(allowed, StringComparer.Ordinal);
        string? unknown = null;
        foreach (JsonProperty prop in obj.EnumerateObject())
        {
            if (!allowedSet.Contains(prop.Name))
            {
                if (unknown is null || string.CompareOrdinal(prop.Name, unknown) < 0)
                {
                    unknown = prop.Name;
                }
            }
        }
        if (unknown is not null)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.UnknownField,
                $"Unknown field \u201C{unknown}\u201D at {path}.");
        }
    }

    private static string RequireString(JsonElement obj, string field, string parentPath)
    {
        if (!obj.TryGetProperty(field, out JsonElement el))
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.MissingField,
                $"Required field \u201C{field}\u201D is missing at {parentPath}.");
        }
        if (el.ValueKind != JsonValueKind.String)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.TypeMismatch,
                $"Expected string at {parentPath}.{field}.");
        }
        return el.GetString()!;
    }

    private static string? OptionalString(JsonElement obj, string field, string parentPath)
    {
        if (!obj.TryGetProperty(field, out JsonElement el) || el.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (el.ValueKind != JsonValueKind.String)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.TypeMismatch,
                $"Expected string at {parentPath}.{field}.");
        }
        return el.GetString();
    }

    private static int RequireInt32(JsonElement obj, string field, string parentPath)
    {
        if (!obj.TryGetProperty(field, out JsonElement el))
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.MissingField,
                $"Required field \u201C{field}\u201D is missing at {parentPath}.");
        }
        if (el.ValueKind != JsonValueKind.Number || !el.TryGetInt32(out int value))
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.TypeMismatch,
                $"Expected integer at {parentPath}.{field}.");
        }
        return value;
    }

    private static JsonElement RequireArray(JsonElement obj, string field, string parentPath)
    {
        if (!obj.TryGetProperty(field, out JsonElement el))
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.MissingField,
                $"Required field \u201C{field}\u201D is missing at {parentPath}.");
        }
        if (el.ValueKind != JsonValueKind.Array)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.TypeMismatch,
                $"Expected array at {parentPath}.{field}.");
        }
        return el;
    }

    private static DatasetRelativePath CanonicalSxmPath(string rawValue, string path)
    {
        DatasetRelativePath canonical = MapValidationError(path, () => DatasetRelativePath.Sxm(rawValue));
        RequireCanonical(rawValue, canonical.RawValue, path);
        return canonical;
    }

    private static DatasetRelativePath CanonicalDatPath(string rawValue, string path)
    {
        DatasetRelativePath canonical = MapValidationError(path, () => DatasetRelativePath.Dat(rawValue));
        RequireCanonical(rawValue, canonical.RawValue, path);
        return canonical;
    }

    private static void RequireCanonical(string rawValue, string canonical, string path)
    {
        if (!StringsHaveIdenticalUtf8(rawValue, canonical))
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.NonCanonicalValue,
                $"\u201C{rawValue}\u201D is not canonical at {path}.");
        }
    }

    private static bool StringsHaveIdenticalUtf8(string lhs, string rhs)
    {
        return string.Equals(lhs, rhs, StringComparison.Ordinal);
    }

    private static T MapValidationError<T>(string path, Func<T> operation)
    {
        try
        {
            return operation();
        }
        catch (DatasetMetadataValidationException ex)
        {
            throw new DatasetMetadataTransferException(
                DatasetMetadataTransferErrorKind.InvalidMetadata,
                $"Invalid metadata at {path}: {ex.Message}",
                ex);
        }
    }
}
