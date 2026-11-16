using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public readonly record struct DatasetPathItem<TId>(TId Id, string Path);

public sealed class DatasetPathIndex : IEquatable<DatasetPathIndex>
{
    public string FolderPath { get; }
    public IReadOnlyDictionary<Guid, DatasetRelativePath> SxmPathById { get; }
    public IReadOnlyDictionary<DatasetRelativePath, Guid> SxmIdByPath { get; }
    public IReadOnlyDictionary<Guid, DatasetRelativePath> DatPathById { get; }
    public IReadOnlyDictionary<DatasetRelativePath, Guid> DatIdByPath { get; }

    public DatasetPathIndex(
        string folderPath,
        IEnumerable<DatasetPathItem<Guid>> sxmItems,
        IEnumerable<DatasetPathItem<Guid>> datItems)
    {
        string canonicalFolder = DatasetMetadataStore.StandardizedFolderPath(folderPath);
        (var sxmPathById, var sxmIdByPath) = BuildMap(sxmItems, DatasetFileKind.Sxm, canonicalFolder);
        (var datPathById, var datIdByPath) = BuildMap(datItems, DatasetFileKind.Dat, canonicalFolder);

        FolderPath = canonicalFolder;
        SxmPathById = sxmPathById;
        SxmIdByPath = sxmIdByPath;
        DatPathById = datPathById;
        DatIdByPath = datIdByPath;
    }

    public DatasetPathIndex(
        string folderPath,
        IEnumerable<SXMMetadata> sxmFiles,
        IEnumerable<SpectroscopyFile> spectroscopyFiles)
        : this(
            folderPath,
            sxmFiles.Select(f => new DatasetPathItem<Guid>(f.Id, f.Path)),
            spectroscopyFiles.Select(f => new DatasetPathItem<Guid>(f.Id, f.Path)))
    {
    }

    public DatasetRelativePath? SxmPath(Guid id) =>
        SxmPathById.TryGetValue(id, out DatasetRelativePath? p) ? p : null;

    public Guid? SxmId(DatasetRelativePath path) =>
        SxmIdByPath.TryGetValue(path, out Guid id) ? id : null;

    public DatasetRelativePath? DatPath(Guid id) =>
        DatPathById.TryGetValue(id, out DatasetRelativePath? p) ? p : null;

    public Guid? DatId(DatasetRelativePath path) =>
        DatIdByPath.TryGetValue(path, out Guid id) ? id : null;

    private static (Dictionary<Guid, DatasetRelativePath>, Dictionary<DatasetRelativePath, Guid>) BuildMap(
        IEnumerable<DatasetPathItem<Guid>> items,
        DatasetFileKind kind,
        string canonicalFolder)
    {
        var pathById = new Dictionary<Guid, DatasetRelativePath>();
        var idByPath = new Dictionary<DatasetRelativePath, Guid>();

        foreach (DatasetPathItem<Guid> item in items)
        {
            if (pathById.ContainsKey(item.Id))
            {
                throw new InvalidOperationException(
                    $"The {kind.ToString().ToUpperInvariant()} file ID {item.Id} occurs more than once.");
            }
            DatasetRelativePath rel = ComputeRelativePath(item.Path, kind, canonicalFolder);
            if (idByPath.ContainsKey(rel))
            {
                throw new InvalidOperationException(
                    $"The {kind.ToString().ToUpperInvariant()} relative path \u201C{rel.RawValue}\u201D occurs more than once.");
            }
            pathById[item.Id] = rel;
            idByPath[rel] = item.Id;
        }
        return (pathById, idByPath);
    }

    private static DatasetRelativePath ComputeRelativePath(
        string itemPath,
        DatasetFileKind kind,
        string canonicalFolder)
    {
        string canonicalItem = DatasetMetadataStore.StandardizedFolderPath(itemPath);
        StringComparison cmp = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;

        string relative = Path.GetRelativePath(canonicalFolder, canonicalItem);
        if (string.IsNullOrEmpty(relative)
            || relative == "."
            || relative == ".."
            || relative.StartsWith(".." + Path.DirectorySeparatorChar, cmp)
            || relative.StartsWith(".." + Path.AltDirectorySeparatorChar, cmp)
            || Path.IsPathRooted(relative))
        {
            throw new InvalidOperationException(
                $"The {kind.ToString().ToUpperInvariant()} item {canonicalItem} is outside the dataset folder {canonicalFolder}.");
        }

        string normalized = relative.Replace('\\', '/');
        return new DatasetRelativePath(normalized, kind);
    }

    public bool Equals(DatasetPathIndex? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return string.Equals(FolderPath, other.FolderPath, StringComparison.Ordinal)
            && SxmPathById.Count == other.SxmPathById.Count
            && DatPathById.Count == other.DatPathById.Count
            && SxmPathById.All(kv => other.SxmPathById.TryGetValue(kv.Key, out var p) && p.Equals(kv.Value))
            && DatPathById.All(kv => other.DatPathById.TryGetValue(kv.Key, out var p) && p.Equals(kv.Value));
    }

    public override bool Equals(object? obj) => Equals(obj as DatasetPathIndex);
    public override int GetHashCode() => HashCode.Combine(FolderPath, SxmPathById.Count, DatPathById.Count);
}

public sealed record DatasetSessionIdentity(Guid SessionId, Guid DatasetId, string FolderPath);

public sealed class ActiveDatasetSession : IEquatable<ActiveDatasetSession>
{
    public Guid SessionId { get; }
    public Guid DatasetId { get; }
    public string FolderPath { get; }
    public DatasetRecordV1 VerifiedRecord { get; }
    public DatasetPathIndex PathIndex { get; }

    public ActiveDatasetSession(
        Guid? sessionId,
        Guid datasetId,
        string folderPath,
        DatasetRecordV1 verifiedRecord,
        DatasetPathIndex pathIndex)
    {
        if (datasetId != verifiedRecord.Id)
        {
            throw new InvalidOperationException(
                $"Dataset session expected {datasetId}, but verified record is {verifiedRecord.Id}.");
        }
        string canonicalFolder = DatasetMetadataStore.StandardizedFolderPath(folderPath);
        if (!string.Equals(verifiedRecord.LastKnownPath, canonicalFolder, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Dataset session folder {canonicalFolder} does not match verified record folder {verifiedRecord.LastKnownPath}.");
        }
        if (!string.Equals(pathIndex.FolderPath, canonicalFolder, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Dataset session folder {canonicalFolder} does not match path index folder {pathIndex.FolderPath}.");
        }

        SessionId = sessionId ?? Guid.NewGuid();
        DatasetId = datasetId;
        FolderPath = pathIndex.FolderPath;
        VerifiedRecord = verifiedRecord;
        PathIndex = pathIndex;
    }

    public DatasetSessionIdentity Identity => new(SessionId, DatasetId, VerifiedRecord.LastKnownPath);

    public bool Matches(DatasetSessionIdentity identity) => Identity.Equals(identity);

    public bool Equals(ActiveDatasetSession? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return SessionId == other.SessionId
            && DatasetId == other.DatasetId
            && string.Equals(FolderPath, other.FolderPath, StringComparison.Ordinal)
            && VerifiedRecord.Equals(other.VerifiedRecord)
            && PathIndex.Equals(other.PathIndex);
    }

    public override bool Equals(object? obj) => Equals(obj as ActiveDatasetSession);
    public override int GetHashCode() => HashCode.Combine(SessionId, DatasetId);
}

public sealed class DatasetSessionGate
{
    public Guid? ExpectedSessionId { get; private set; }
    public DatasetSessionIdentity? ActiveIdentity { get; private set; }

    public Guid Begin(Guid? sessionId = null)
    {
        Guid id = sessionId ?? Guid.NewGuid();
        ExpectedSessionId = id;
        ActiveIdentity = null;
        return id;
    }

    public bool AcceptsOpeningResult(Guid sessionId) => ExpectedSessionId == sessionId;

    public bool Activate(ActiveDatasetSession session)
    {
        if (!AcceptsOpeningResult(session.SessionId)) return false;
        ActiveIdentity = session.Identity;
        return true;
    }

    public bool Accepts(ActiveDatasetSession session) =>
        ExpectedSessionId == session.SessionId && Equals(ActiveIdentity, session.Identity);

    public bool Accepts(DatasetSessionIdentity identity) => Equals(ActiveIdentity, identity);

    public void Invalidate()
    {
        ExpectedSessionId = null;
        ActiveIdentity = null;
    }
}
