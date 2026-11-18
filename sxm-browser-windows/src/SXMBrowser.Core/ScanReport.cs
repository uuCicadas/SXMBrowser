using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json.Serialization;

namespace SXMBrowser.Core;

public enum ScanStage
{
    SxmMetadata,
    SpectroscopyFile,
    SpectroscopyRows
}

public static class ScanStageExtensions
{
    public static string ToRawValue(this ScanStage stage) => stage switch
    {
        ScanStage.SxmMetadata => "sxm-metadata",
        ScanStage.SpectroscopyFile => "spectroscopy-file",
        ScanStage.SpectroscopyRows => "spectroscopy-rows",
        _ => throw new ArgumentOutOfRangeException(nameof(stage), stage, null)
    };
}

public sealed record ScanIssue(
    string FilePath,
    ScanStage Stage,
    string Reason,
    int? BadLineCount = null)
{
    [JsonIgnore]
    public string Id => string.Join(
        '\u001f',
        Path.GetFullPath(FilePath),
        Stage.ToRawValue(),
        Reason,
        BadLineCount?.ToString(CultureInfo.InvariantCulture) ?? string.Empty);
}

public sealed record ScanReport<TItem>(
    IReadOnlyList<TItem> Items,
    IReadOnlyList<ScanIssue> Issues);
