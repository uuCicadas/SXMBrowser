using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public interface IDatasetMetadataFileAccess
{
    bool FileExists(string filePath);
    void CreateDirectory(string directoryPath);
    byte[] ReadData(string filePath);
    void WriteDataAtomically(byte[] data, string filePath);
    void RemoveItem(string filePath);
}

public sealed class FoundationDatasetMetadataFileAccess : IDatasetMetadataFileAccess
{
    public bool FileExists(string filePath) => File.Exists(filePath);

    public void CreateDirectory(string directoryPath) => Directory.CreateDirectory(directoryPath);

    public byte[] ReadData(string filePath) => File.ReadAllBytes(filePath);

    public void WriteDataAtomically(byte[] data, string filePath)
    {
        string dir = Path.GetDirectoryName(filePath)
            ?? throw new IOException($"Cannot determine parent directory for {filePath}.");
        Directory.CreateDirectory(dir);
        string tempPath = Path.Combine(dir, $".metadata-v1.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var fs = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                fs.Write(data, 0, data.Length);
                fs.Flush(flushToDisk: true);
            }
            File.Move(tempPath, filePath, overwrite: true);
        }
        catch
        {
            try
            {
                if (File.Exists(tempPath)) File.Delete(tempPath);
            }
            catch
            {
            }
            throw;
        }
    }

    public void RemoveItem(string filePath)
    {
        if (File.Exists(filePath))
        {
            File.Delete(filePath);
        }
    }
}

public enum DatasetMetadataStoreErrorKind
{
    ReadFailed,
    CorruptDocument,
    UnsupportedSchemaVersion,
    EncodingFailed,
    DirectoryCreationFailed,
    WriteFailed,
    VerificationFailed
}

public sealed class DatasetMetadataStoreException : Exception
{
    public DatasetMetadataStoreErrorKind Kind { get; }
    public string FilePath { get; }
    public int? Version { get; }
    public string? RollbackFailure { get; }

    public DatasetMetadataStoreException(
        DatasetMetadataStoreErrorKind kind,
        string filePath,
        string message,
        int? version = null,
        string? rollbackFailure = null,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
        FilePath = filePath;
        Version = version;
        RollbackFailure = rollbackFailure;
    }
}

/// <summary>
/// Thread-safe serialized local persistence store for dataset tags, manual associations,
/// hidden DAT paths, and spectrum axis preferences with atomic write + read-back verification.
/// </summary>
public sealed class DatasetMetadataStore
{
    private sealed record DiskSnapshot(byte[]? OriginalData, DatasetMetadataDocumentV1 Document);

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = false,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly IDatasetMetadataFileAccess _fileAccess;

    public string FilePath { get; }
    public DatasetMetadataDocumentV1? PublishedDocument { get; private set; }

    public static string DefaultFilePath
    {
        get
        {
            string baseDir = OperatingSystem.IsWindows()
                ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
                : Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".local",
                    "share");
            return Path.Combine(baseDir, "SXM Browser", "metadata-v1.json");
        }
    }

    public DatasetMetadataStore(
        string? filePath = null,
        IDatasetMetadataFileAccess? fileAccess = null)
    {
        FilePath = Path.GetFullPath(filePath ?? DefaultFilePath);
        _fileAccess = fileAccess ?? new FoundationDatasetMetadataFileAccess();
    }

    public async Task<DatasetMetadataDocumentV1> LoadAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            DiskSnapshot snapshot = LoadSnapshot();
            PublishedDocument = snapshot.Document;
            return snapshot.Document.Clone();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<DatasetMetadataDocumentV1> TransactionAsync(
        Action<DatasetMetadataDocumentV1> mutation,
        CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            DiskSnapshot snapshot = LoadSnapshot();
            DatasetMetadataDocumentV1 candidate = snapshot.Document.Clone();
            mutation(candidate);

            byte[] expectedData = ValidatedEncoding(candidate);
            string directoryPath = Path.GetDirectoryName(FilePath) ?? FilePath;
            try
            {
                _fileAccess.CreateDirectory(directoryPath);
            }
            catch (Exception ex)
            {
                throw new DatasetMetadataStoreException(
                    DatasetMetadataStoreErrorKind.DirectoryCreationFailed,
                    directoryPath,
                    $"Could not create {directoryPath}: {ex.Message}",
                    innerException: ex);
            }

            try
            {
                _fileAccess.WriteDataAtomically(expectedData, FilePath);
            }
            catch (Exception ex)
            {
                string? rollbackFailure = Rollback(snapshot);
                throw new DatasetMetadataStoreException(
                    DatasetMetadataStoreErrorKind.WriteFailed,
                    FilePath,
                    OperationDescription($"Could not write metadata at {FilePath}", ex.Message, rollbackFailure),
                    rollbackFailure: rollbackFailure,
                    innerException: ex);
            }

            DatasetMetadataDocumentV1 verifiedDocument;
            try
            {
                byte[] writtenData = _fileAccess.ReadData(FilePath);
                verifiedDocument = DecodeDocument(writtenData);
                byte[] canonicalWrittenData = EncodeDocument(verifiedDocument);
                if (!canonicalWrittenData.AsSpan().SequenceEqual(expectedData))
                {
                    throw new InvalidDataException("Written metadata bytes did not match expected canonical encoding.");
                }
            }
            catch (Exception ex)
            {
                string? rollbackFailure = Rollback(snapshot);
                throw new DatasetMetadataStoreException(
                    DatasetMetadataStoreErrorKind.VerificationFailed,
                    FilePath,
                    OperationDescription($"Could not verify metadata at {FilePath}", ex.Message, rollbackFailure),
                    rollbackFailure: rollbackFailure,
                    innerException: ex);
            }

            PublishedDocument = verifiedDocument;
            return verifiedDocument.Clone();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<DatasetRecordV1?> DatasetForFolderAsync(
        string folderPath,
        CancellationToken ct = default)
    {
        string canonical = StandardizedFolderPath(folderPath);
        DatasetMetadataDocumentV1 doc = await LoadAsync(ct).ConfigureAwait(false);
        return doc.Datasets.FirstOrDefault(d => PathMatches(d.LastKnownPath, canonical));
    }

    public async Task<DatasetRecordV1?> LastOpenedDatasetAsync(CancellationToken ct = default)
    {
        DatasetMetadataDocumentV1 doc = await LoadAsync(ct).ConfigureAwait(false);
        if (doc.LastOpenedDatasetId is not { } id) return null;
        return doc.Datasets.FirstOrDefault(d => d.Id == id);
    }

    public async Task<DatasetRecordV1> UpdateDatasetAsync(
        Guid id,
        Action<DatasetRecordV1> mutation,
        DateTimeOffset? updatedAt = null,
        CancellationToken ct = default)
    {
        DateTimeOffset ts = updatedAt ?? DateTimeOffset.UtcNow;
        DatasetMetadataDocumentV1 verified = await TransactionAsync(document =>
        {
            DatasetRecordV1? existing = document.Datasets.FirstOrDefault(d => d.Id == id);
            if (existing is null)
            {
                throw new DatasetMetadataValidationException(
                    DatasetMetadataValidationErrorKind.DatasetNotFound,
                    $"Dataset {id.ToString("D").ToUpperInvariant()} does not exist.");
            }
            DatasetRecordV1 updated = existing.Clone();
            mutation(updated);
            updated.MarkUpdated(ts);
            document.ReplaceDataset(updated);
        }, ct).ConfigureAwait(false);

        DatasetRecordV1? result = verified.Datasets.FirstOrDefault(d => d.Id == id);
        if (result is null)
        {
            throw new DatasetMetadataStoreException(
                DatasetMetadataStoreErrorKind.VerificationFailed,
                FilePath,
                "The verified document omitted the updated dataset.");
        }
        return result;
    }

    public async Task<DatasetRecordV1> FindOrCreateDatasetAsync(
        string folderPath,
        byte[]? folderBookmark = null,
        DateTimeOffset? updatedAt = null,
        CancellationToken ct = default)
    {
        string path = StandardizedFolderPath(folderPath);
        DateTimeOffset ts = updatedAt ?? DateTimeOffset.UtcNow;

        DatasetMetadataDocumentV1 verified = await TransactionAsync(document =>
        {
            DatasetRecordV1? existing = document.Datasets.FirstOrDefault(d => PathMatches(d.LastKnownPath, path));
            if (existing is not null)
            {
                DatasetRecordV1 updated = existing.Clone();
                updated.UpdateFolderIdentity(folderBookmark ?? updated.FolderBookmark, path, ts);
                document.UpsertDataset(updated);
                document.SetLastOpenedDatasetId(updated.Id);
            }
            else
            {
                var created = new DatasetRecordV1(
                    id: null,
                    folderBookmark: folderBookmark,
                    lastKnownPath: path,
                    updatedAt: ts);
                document.UpsertDataset(created);
                document.SetLastOpenedDatasetId(created.Id);
            }
        }, ct).ConfigureAwait(false);

        DatasetRecordV1? result = verified.Datasets.FirstOrDefault(d => PathMatches(d.LastKnownPath, path));
        if (result is null)
        {
            throw new DatasetMetadataStoreException(
                DatasetMetadataStoreErrorKind.VerificationFailed,
                FilePath,
                "The verified document omitted the opened dataset.");
        }
        return result;
    }

    public async Task<DatasetRecordV1> RebindDatasetAsync(
        Guid id,
        string toFolderPath,
        byte[]? folderBookmark = null,
        DateTimeOffset? updatedAt = null,
        CancellationToken ct = default)
    {
        string path = StandardizedFolderPath(toFolderPath);
        DateTimeOffset ts = updatedAt ?? DateTimeOffset.UtcNow;

        DatasetMetadataDocumentV1 verified = await TransactionAsync(document =>
        {
            DatasetRecordV1? existing = document.Datasets.FirstOrDefault(d => d.Id == id);
            if (existing is null)
            {
                throw new DatasetMetadataValidationException(
                    DatasetMetadataValidationErrorKind.DatasetNotFound,
                    $"Dataset {id.ToString("D").ToUpperInvariant()} does not exist.");
            }
            DatasetRecordV1 updated = existing.Clone();
            updated.UpdateFolderIdentity(folderBookmark ?? updated.FolderBookmark, path, ts);
            document.ReplaceDataset(updated);
            document.SetLastOpenedDatasetId(id);
        }, ct).ConfigureAwait(false);

        DatasetRecordV1? result = verified.Datasets.FirstOrDefault(d => d.Id == id);
        if (result is null)
        {
            throw new DatasetMetadataStoreException(
                DatasetMetadataStoreErrorKind.VerificationFailed,
                FilePath,
                "The verified document omitted the rebound dataset.");
        }
        return result;
    }

    public static string StandardizedFolderPath(string folderPath)
    {
        if (string.IsNullOrWhiteSpace(folderPath) || folderPath.Contains('\0'))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidLastKnownPath,
                $"The last-known dataset path is invalid: \u201C{folderPath}\u201D.");
        }

        string full;
        try
        {
            full = Path.GetFullPath(folderPath);
        }
        catch (Exception)
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidLastKnownPath,
                $"The last-known dataset path is invalid: \u201C{folderPath}\u201D.");
        }

        string root = Path.GetPathRoot(full) ?? string.Empty;
        if (!string.Equals(full, root, StringComparison.Ordinal))
        {
            full = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        return MetadataCanonical.SafeNormalizeNfc(full);
    }

    private static bool PathMatches(string a, string b)
    {
        StringComparison cmp = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        return string.Equals(a, b, cmp);
    }

    private DiskSnapshot LoadSnapshot()
    {
        if (!_fileAccess.FileExists(FilePath))
        {
            return new DiskSnapshot(null, new DatasetMetadataDocumentV1());
        }

        byte[] data;
        try
        {
            data = _fileAccess.ReadData(FilePath);
        }
        catch (Exception ex)
        {
            throw new DatasetMetadataStoreException(
                DatasetMetadataStoreErrorKind.ReadFailed,
                FilePath,
                $"Could not read metadata at {FilePath}: {ex.Message}",
                innerException: ex);
        }

        return new DiskSnapshot(data, DecodeStoredDocument(data));
    }

    private byte[] ValidatedEncoding(DatasetMetadataDocumentV1 document)
    {
        byte[] first = EncodeDocument(document);
        DatasetMetadataDocumentV1 validated;
        try
        {
            validated = DecodeDocument(first);
        }
        catch (Exception ex)
        {
            throw new DatasetMetadataStoreException(
                DatasetMetadataStoreErrorKind.EncodingFailed,
                FilePath,
                $"Could not encode metadata: {ex.Message}",
                innerException: ex);
        }
        return EncodeDocument(validated);
    }

    private DatasetMetadataDocumentV1 DecodeStoredDocument(byte[] data)
    {
        try
        {
            return DecodeDocument(data);
        }
        catch (DatasetMetadataValidationException ex)
            when (ex.Kind == DatasetMetadataValidationErrorKind.UnsupportedSchemaVersion
                  && int.TryParse(ex.Detail, NumberStyles.Integer, CultureInfo.InvariantCulture, out int ver))
        {
            throw new DatasetMetadataStoreException(
                DatasetMetadataStoreErrorKind.UnsupportedSchemaVersion,
                FilePath,
                $"Metadata at {FilePath} uses unsupported schema version {ver}.",
                version: ver,
                innerException: ex);
        }
        catch (Exception ex)
        {
            throw new DatasetMetadataStoreException(
                DatasetMetadataStoreErrorKind.CorruptDocument,
                FilePath,
                $"Metadata at {FilePath} is invalid: {ex.Message}",
                innerException: ex);
        }
    }

    private byte[] EncodeDocument(DatasetMetadataDocumentV1 document)
    {
        try
        {
            using var ms = new MemoryStream();
            using (var writer = new Utf8JsonWriter(ms, WriterOptions))
            {
                writer.WriteStartObject();
                // Sorted keys: datasets, lastOpenedDatasetID (optional), schemaVersion
                writer.WritePropertyName("datasets");
                writer.WriteStartArray();
                foreach (DatasetRecordV1 ds in document.Datasets)
                {
                    WriteDatasetRecord(writer, ds);
                }
                writer.WriteEndArray();

                if (document.LastOpenedDatasetId is { } lastId)
                {
                    writer.WriteString("lastOpenedDatasetID", lastId.ToString("D").ToUpperInvariant());
                }

                writer.WriteNumber("schemaVersion", document.SchemaVersion);
                writer.WriteEndObject();
            }
            return ms.ToArray();
        }
        catch (Exception ex)
        {
            throw new DatasetMetadataStoreException(
                DatasetMetadataStoreErrorKind.EncodingFailed,
                FilePath,
                $"Could not encode metadata: {ex.Message}",
                innerException: ex);
        }
    }

    private static void WriteDatasetRecord(Utf8JsonWriter writer, DatasetRecordV1 ds)
    {
        writer.WriteStartObject();
        // Alphabetical keys: folderBookmark, hiddenDATPaths, id, lastKnownPath, manualAssociations, spectrumAxisPreferences, tags, updatedAt
        if (ds.FolderBookmark is not null)
        {
            writer.WriteBase64String("folderBookmark", ds.FolderBookmark);
        }

        writer.WritePropertyName("hiddenDATPaths");
        writer.WriteStartArray();
        foreach (DatasetRelativePath p in ds.HiddenDATPaths)
        {
            writer.WriteStringValue(p.RawValue);
        }
        writer.WriteEndArray();

        writer.WriteString("id", ds.Id.ToString("D").ToUpperInvariant());
        writer.WriteString("lastKnownPath", ds.LastKnownPath);

        writer.WritePropertyName("manualAssociations");
        writer.WriteStartArray();
        foreach (DatasetManualAssociationV1 a in ds.ManualAssociations)
        {
            writer.WriteStartObject();
            writer.WriteString("datPath", a.DatPath.RawValue);
            writer.WriteString("sxmPath", a.SxmPath.RawValue);
            writer.WriteEndObject();
        }
        writer.WriteEndArray();

        writer.WritePropertyName("spectrumAxisPreferences");
        writer.WriteStartArray();
        foreach (SpectrumAxisPreferenceV1 pref in ds.SpectrumAxisPreferences)
        {
            writer.WriteStartObject();
            writer.WritePropertyName("key");
            writer.WriteStartObject();
            if (pref.Key.ExperimentIdentity is not null)
            {
                writer.WriteString("experimentIdentity", pref.Key.ExperimentIdentity);
            }
            writer.WriteString("kind", pref.Key.Kind.ToRawValue());
            writer.WriteString("schemaFingerprint", pref.Key.SchemaFingerprint);
            writer.WriteString("sxmPath", pref.Key.SxmPath.RawValue);
            writer.WriteEndObject();

            writer.WritePropertyName("selection");
            writer.WriteStartObject();
            writer.WriteString("xColumn", pref.Selection.XColumn);
            writer.WriteString("yColumn", pref.Selection.YColumn);
            writer.WriteEndObject();
            writer.WriteEndObject();
        }
        writer.WriteEndArray();

        writer.WritePropertyName("tags");
        writer.WriteStartArray();
        foreach (DatasetTagV1 tag in ds.Tags)
        {
            writer.WriteStartObject();
            writer.WriteString("id", tag.Id.ToString("D").ToUpperInvariant());
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

        writer.WriteNumber("updatedAt", ds.UpdatedAt.ToUnixTimeMilliseconds());
        writer.WriteEndObject();
    }

    private static DatasetMetadataDocumentV1 DecodeDocument(byte[] data)
    {
        using JsonDocument doc = JsonDocument.Parse(data);
        JsonElement root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("Metadata root must be a JSON object.");
        }

        int schemaVersion = ReadInt32(root, "schemaVersion");
        Guid? lastOpenedDatasetId = ReadOptionalGuid(root, "lastOpenedDatasetID");

        if (!root.TryGetProperty("datasets", out JsonElement datasetsEl) || datasetsEl.ValueKind != JsonValueKind.Array)
        {
            throw new JsonException("Missing or invalid 'datasets' array.");
        }

        var datasets = new List<DatasetRecordV1>();
        foreach (JsonElement item in datasetsEl.EnumerateArray())
        {
            datasets.Add(ReadDatasetRecord(item));
        }

        return new DatasetMetadataDocumentV1(schemaVersion, lastOpenedDatasetId, datasets);
    }

    private static DatasetRecordV1 ReadDatasetRecord(JsonElement el)
    {
        if (el.ValueKind != JsonValueKind.Object) throw new JsonException("Dataset item must be an object.");

        Guid id = ReadGuid(el, "id");
        byte[]? folderBookmark = null;
        if (el.TryGetProperty("folderBookmark", out JsonElement bmEl) && bmEl.ValueKind != JsonValueKind.Null)
        {
            if (bmEl.ValueKind != JsonValueKind.String) throw new JsonException("folderBookmark must be base64 string.");
            folderBookmark = bmEl.GetBytesFromBase64();
        }
        string lastKnownPath = ReadString(el, "lastKnownPath");

        if (!el.TryGetProperty("tags", out JsonElement tagsEl) || tagsEl.ValueKind != JsonValueKind.Array)
            throw new JsonException("Missing 'tags' array.");
        var tags = new List<DatasetTagV1>();
        foreach (JsonElement tagEl in tagsEl.EnumerateArray())
        {
            Guid tagId = ReadGuid(tagEl, "id");
            string name = ReadString(tagEl, "name");
            var sxmPaths = ReadRelativePathArray(tagEl, "sxmPaths", DatasetFileKind.Sxm);
            tags.Add(new DatasetTagV1(tagId, name, sxmPaths));
        }

        if (!el.TryGetProperty("manualAssociations", out JsonElement assocEl) || assocEl.ValueKind != JsonValueKind.Array)
            throw new JsonException("Missing 'manualAssociations' array.");
        var assocs = new List<DatasetManualAssociationV1>();
        foreach (JsonElement aEl in assocEl.EnumerateArray())
        {
            string datPath = ReadString(aEl, "datPath");
            string sxmPath = ReadString(aEl, "sxmPath");
            assocs.Add(new DatasetManualAssociationV1(datPath, sxmPath));
        }

        var hiddenDatPaths = ReadRelativePathArray(el, "hiddenDATPaths", DatasetFileKind.Dat);

        if (!el.TryGetProperty("spectrumAxisPreferences", out JsonElement prefsEl) || prefsEl.ValueKind != JsonValueKind.Array)
            throw new JsonException("Missing 'spectrumAxisPreferences' array.");
        var prefs = new List<SpectrumAxisPreferenceV1>();
        foreach (JsonElement pEl in prefsEl.EnumerateArray())
        {
            if (!pEl.TryGetProperty("key", out JsonElement kEl) || kEl.ValueKind != JsonValueKind.Object)
                throw new JsonException("Missing 'key' object.");
            if (!pEl.TryGetProperty("selection", out JsonElement sEl) || sEl.ValueKind != JsonValueKind.Object)
                throw new JsonException("Missing 'selection' object.");

            string sxmPath = ReadString(kEl, "sxmPath");
            string kindRaw = ReadString(kEl, "kind");
            if (!SpectroscopyKindExtensions.TryParse(kindRaw, out SpectroscopyKind kind))
                throw new JsonException($"Invalid spectroscopy kind: {kindRaw}");
            string? expId = ReadOptionalString(kEl, "experimentIdentity");
            string fp = ReadString(kEl, "schemaFingerprint");

            string xCol = ReadString(sEl, "xColumn");
            string yCol = ReadString(sEl, "yColumn");

            prefs.Add(new SpectrumAxisPreferenceV1(
                new SpectrumAxisPreferenceKeyV1(sxmPath, kind, expId, fp),
                new AxisSelection(xCol, yCol)));
        }

        DateTimeOffset updatedAt = ReadTimestampMillis(el, "updatedAt");
        return new DatasetRecordV1(
            id,
            folderBookmark,
            lastKnownPath,
            tags,
            assocs,
            hiddenDatPaths,
            prefs,
            updatedAt);
    }

    private static List<DatasetRelativePath> ReadRelativePathArray(
        JsonElement obj,
        string propName,
        DatasetFileKind kind)
    {
        if (!obj.TryGetProperty(propName, out JsonElement arr) || arr.ValueKind != JsonValueKind.Array)
            throw new JsonException($"Missing '{propName}' array.");
        var result = new List<DatasetRelativePath>();
        foreach (JsonElement item in arr.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String)
                throw new JsonException($"Element in '{propName}' must be a string.");
            result.Add(new DatasetRelativePath(item.GetString()!, kind));
        }
        return result;
    }

    private static int ReadInt32(JsonElement obj, string propName)
    {
        if (!obj.TryGetProperty(propName, out JsonElement el) || !el.TryGetInt32(out int value))
            throw new JsonException($"Missing or invalid integer '{propName}'.");
        return value;
    }

    private static string ReadString(JsonElement obj, string propName)
    {
        if (!obj.TryGetProperty(propName, out JsonElement el) || el.ValueKind != JsonValueKind.String)
            throw new JsonException($"Missing or invalid string '{propName}'.");
        return el.GetString()!;
    }

    private static string? ReadOptionalString(JsonElement obj, string propName)
    {
        if (!obj.TryGetProperty(propName, out JsonElement el) || el.ValueKind == JsonValueKind.Null)
            return null;
        if (el.ValueKind != JsonValueKind.String)
            throw new JsonException($"Invalid string '{propName}'.");
        return el.GetString();
    }

    private static Guid ReadGuid(JsonElement obj, string propName)
    {
        string raw = ReadString(obj, propName);
        if (!Guid.TryParseExact(raw, "D", out Guid guid))
            throw new JsonException($"Invalid UUID '{raw}' for '{propName}'.");
        return guid;
    }

    private static Guid? ReadOptionalGuid(JsonElement obj, string propName)
    {
        if (!obj.TryGetProperty(propName, out JsonElement el) || el.ValueKind == JsonValueKind.Null)
            return null;
        if (el.ValueKind != JsonValueKind.String)
            throw new JsonException($"Invalid UUID '{propName}'.");
        string raw = el.GetString()!;
        if (!Guid.TryParseExact(raw, "D", out Guid guid))
            throw new JsonException($"Invalid UUID '{raw}' for '{propName}'.");
        return guid;
    }

    private static DateTimeOffset ReadTimestampMillis(JsonElement obj, string propName)
    {
        if (!obj.TryGetProperty(propName, out JsonElement el) || el.ValueKind != JsonValueKind.Number)
            throw new JsonException($"Missing or invalid timestamp '{propName}'.");
        double ms = el.GetDouble();
        if (!double.IsFinite(ms))
        {
            throw new DatasetMetadataValidationException(
                DatasetMetadataValidationErrorKind.InvalidUpdatedAt,
                "The metadata update time must be finite.");
        }
        long roundedMs = (long)Math.Round(ms, MidpointRounding.AwayFromZero);
        return DateTimeOffset.FromUnixTimeMilliseconds(roundedMs);
    }

    private string? Rollback(DiskSnapshot snapshot)
    {
        try
        {
            if (snapshot.OriginalData is not null)
            {
                string dir = Path.GetDirectoryName(FilePath) ?? FilePath;
                _fileAccess.CreateDirectory(dir);
                _fileAccess.WriteDataAtomically(snapshot.OriginalData, FilePath);
            }
            else if (_fileAccess.FileExists(FilePath))
            {
                _fileAccess.RemoveItem(FilePath);
            }
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    private static string OperationDescription(string prefix, string message, string? rollbackFailure)
    {
        string description = $"{prefix}: {message}";
        if (rollbackFailure is not null)
        {
            description += $" Rollback also failed: {rollbackFailure}";
        }
        return description;
    }
}
