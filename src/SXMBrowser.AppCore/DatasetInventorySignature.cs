using System;
using System.Collections.Generic;
using System.Linq;

namespace SXMBrowser.AppCore;

public sealed record DatasetInventoryFileStamp
{
    public DatasetRelativePath Path { get; }
    public ulong ByteCount { get; }
    public DateTimeOffset ModifiedAt { get; }

    public DatasetInventoryFileStamp(
        DatasetRelativePath path,
        ulong byteCount,
        DateTimeOffset modifiedAt)
    {
        string? ext = path.PathExtension?.ToLowerInvariant();
        if (ext != "sxm" && ext != "dat")
        {
            throw new InvalidOperationException(
                $"Inventory signatures support only .sxm and .dat files: {path.RawValue}");
        }
        if (path.RawValue.Contains('/'))
        {
            throw new InvalidOperationException(
                $"Inventory signatures require top-level dataset files: {path.RawValue}");
        }
        Path = path;
        ByteCount = byteCount;
        ModifiedAt = modifiedAt;
    }
}

public sealed class DatasetInventorySignature : IEquatable<DatasetInventorySignature>
{
    public IReadOnlyList<DatasetInventoryFileStamp> Files { get; }

    public DatasetInventorySignature(IEnumerable<DatasetInventoryFileStamp> files)
    {
        var seen = new HashSet<DatasetRelativePath>();
        var list = new List<DatasetInventoryFileStamp>();
        foreach (DatasetInventoryFileStamp f in files)
        {
            if (!seen.Add(f.Path))
            {
                throw new InvalidOperationException(
                    $"The inventory signature contains duplicate path \u201C{f.Path.RawValue}\u201D.");
            }
            list.Add(f);
        }
        Files = list.OrderBy(f => f.Path).ToArray();
    }

    public bool Equals(DatasetInventorySignature? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return Files.SequenceEqual(other.Files);
    }

    public override bool Equals(object? obj) => Equals(obj as DatasetInventorySignature);
    public override int GetHashCode() => Files.Count;
}
