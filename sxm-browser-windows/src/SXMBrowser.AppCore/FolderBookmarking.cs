using System;
using System.IO;
using System.Text;

namespace SXMBrowser.AppCore;

public sealed record FolderBookmarkResolution(string FolderPath, bool IsStale);

public interface IFolderBookmarking
{
    byte[]? CreateBookmark(string folderPath);
    FolderBookmarkResolution? ResolveBookmark(byte[]? bookmarkData);
}

/// <summary>
/// Cross-platform folder bookmarking using canonical UTF-8 folder path tokens.
/// Keeps macOS security-scoped bookmark compatibility cleanly separated while supporting
/// stale-free path resolution on Windows.
/// </summary>
public sealed class PortableFolderBookmarking : IFolderBookmarking
{
    public byte[]? CreateBookmark(string folderPath)
    {
        if (string.IsNullOrWhiteSpace(folderPath)) return null;
        string canonical = DatasetMetadataStore.StandardizedFolderPath(folderPath);
        return Encoding.UTF8.GetBytes(canonical);
    }

    public FolderBookmarkResolution? ResolveBookmark(byte[]? bookmarkData)
    {
        if (bookmarkData is null || bookmarkData.Length == 0) return null;
        try
        {
            string decoded = Encoding.UTF8.GetString(bookmarkData);
            if (!Directory.Exists(decoded)) return null;
            string canonical = DatasetMetadataStore.StandardizedFolderPath(decoded);
            return new FolderBookmarkResolution(canonical, IsStale: false);
        }
        catch
        {
            return null;
        }
    }
}
