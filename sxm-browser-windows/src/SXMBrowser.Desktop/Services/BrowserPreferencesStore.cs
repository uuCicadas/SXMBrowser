using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Encodings.Web;
using System.Text.Json;
using SXMBrowser.AppCore;
using SXMBrowser.Core;

namespace SXMBrowser.Desktop.Services;

public enum ThemeAppearanceMode
{
    System,
    Light,
    Dark
}

public static class ThemeAppearanceModeExtensions
{
    public static string ToRawValue(this ThemeAppearanceMode mode) => mode switch
    {
        ThemeAppearanceMode.System => "system",
        ThemeAppearanceMode.Light => "light",
        ThemeAppearanceMode.Dark => "dark",
        _ => "system"
    };

    public static bool TryParse(string? raw, out ThemeAppearanceMode mode)
    {
        switch (raw?.Trim().ToLowerInvariant())
        {
            case "system":
                mode = ThemeAppearanceMode.System;
                return true;
            case "light":
                mode = ThemeAppearanceMode.Light;
                return true;
            case "dark":
                mode = ThemeAppearanceMode.Dark;
                return true;
            default:
                mode = ThemeAppearanceMode.System;
                return false;
        }
    }

    public static string Label(this ThemeAppearanceMode mode) => mode switch
    {
        ThemeAppearanceMode.System => "Follow System",
        ThemeAppearanceMode.Light => "Light",
        ThemeAppearanceMode.Dark => "Dark",
        _ => "Follow System"
    };
}

public sealed record BrowserPreferencesSnapshot
{
    public PaletteName StmPreviewPalette { get; init; } = PaletteName.Gwyddion;
    public FileSortCriterion SortCriterion { get; init; } = FileSortCriterion.Name;
    public bool SortAscending { get; init; } = false;
    public bool SidebarVisible { get; init; } = true;
    public bool InspectorVisible { get; init; } = true;
    public double SidebarWidth { get; init; } = 300.0;
    public double InspectorWidth { get; init; } = 320.0;
    public int HistogramBins { get; init; } = 256;
    public GridDensity GridDensity { get; init; } = GridDensity.Comfortable;
    public bool ShowsGridSpectroscopyCards { get; init; } = true;
    public bool SingleSpectroscopyDrawerExpanded { get; init; } = true;
    public double SingleSpectroscopyDrawerHeight { get; init; } = SingleSpectroscopyState.DefaultHeight;
    public ThemeAppearanceMode ThemeMode { get; init; } = ThemeAppearanceMode.System;
    public string? LastOpenedFolderPath { get; init; }
    public Dictionary<string, List<string>> ExpandedTagIdsByDataset { get; init; } =
        new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<Guid> GetExpandedTagIds(Guid datasetId)
    {
        string key = datasetId.ToString("D").ToUpperInvariant();
        if (!ExpandedTagIdsByDataset.TryGetValue(key, out List<string>? rawIds))
        {
            return Array.Empty<Guid>();
        }
        var result = new List<Guid>(rawIds.Count);
        foreach (string raw in rawIds)
        {
            if (Guid.TryParseExact(raw, "D", out Guid parsed))
            {
                result.Add(parsed);
            }
        }
        return result;
    }

    public BrowserPreferencesSnapshot WithExpandedTagIds(Guid datasetId, IEnumerable<Guid> tagIds)
    {
        string key = datasetId.ToString("D").ToUpperInvariant();
        var next = new Dictionary<string, List<string>>(ExpandedTagIdsByDataset, StringComparer.OrdinalIgnoreCase);
        next[key] = tagIds
            .Distinct()
            .Select(id => id.ToString("D").ToUpperInvariant())
            .OrderBy(s => s, StringComparer.Ordinal)
            .ToList();
        return this with { ExpandedTagIdsByDataset = next };
    }
}

public sealed class BrowserPreferencesStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private sealed class PreferencesDto
    {
        public int SchemaVersion { get; set; } = 1;
        public string? StmPreviewPalette { get; set; }
        public string? SortCriterion { get; set; }
        public bool? SortAscending { get; set; }
        public bool? SidebarVisible { get; set; }
        public bool? InspectorVisible { get; set; }
        public double? SidebarWidth { get; set; }
        public double? InspectorWidth { get; set; }
        public int? HistogramBins { get; set; }
        public string? GridDensity { get; set; }
        public bool? ShowsGridSpectroscopyCards { get; set; }
        public bool? SingleSpectroscopyDrawerExpanded { get; set; }
        public double? SingleSpectroscopyDrawerHeight { get; set; }
        public string? ThemeMode { get; set; }
        public string? LastOpenedFolderPath { get; set; }
        public Dictionary<string, List<string>>? ExpandedTagIdsByDataset { get; set; }
    }

    public string FilePath { get; }

    public static string DefaultFilePath
    {
        get
        {
            string? metadataDir = Path.GetDirectoryName(DatasetMetadataStore.DefaultFilePath);
            string baseDir = string.IsNullOrEmpty(metadataDir)
                ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
                : metadataDir;
            return Path.Combine(baseDir, "preferences-v1.json");
        }
    }

    public BrowserPreferencesStore(string? filePath = null)
    {
        FilePath = Path.GetFullPath(filePath ?? DefaultFilePath);
    }

    public BrowserPreferencesSnapshot Load()
    {
        try
        {
            if (!File.Exists(FilePath))
            {
                return new BrowserPreferencesSnapshot();
            }

            string json = File.ReadAllText(FilePath);
            PreferencesDto? dto = JsonSerializer.Deserialize<PreferencesDto>(json, SerializerOptions);
            if (dto is null)
            {
                return new BrowserPreferencesSnapshot();
            }

            PaletteName stmPalette = PaletteName.Gwyddion;
            if (dto.StmPreviewPalette is not null
                && SXMValueExtensions.TryParsePaletteName(dto.StmPreviewPalette, out PaletteName parsedPalette))
            {
                stmPalette = parsedPalette;
            }

            FileSortCriterion sortCriterion = dto.SortCriterion switch
            {
                "modifiedTime" => FileSortCriterion.ModifiedTime,
                "recordedTime" => FileSortCriterion.RecordedTime,
                _ => FileSortCriterion.Name
            };

            GridDensity density = GridDensity.Comfortable;
            if (dto.GridDensity is not null
                && GridDensityExtensions.TryParse(dto.GridDensity, out GridDensity parsedDensity))
            {
                density = parsedDensity;
            }

            ThemeAppearanceMode themeMode = ThemeAppearanceMode.System;
            if (dto.ThemeMode is not null
                && ThemeAppearanceModeExtensions.TryParse(dto.ThemeMode, out ThemeAppearanceMode parsedTheme))
            {
                themeMode = parsedTheme;
            }

            int bins = dto.HistogramBins is int b && b is 64 or 128 or 256 or 512 ? b : 256;

            double sidebarWidth = ClampFinite(dto.SidebarWidth, 300.0, NativePaneLayout.SidebarMinWidth, NativePaneLayout.SidebarMaxWidth);
            double inspectorWidth = ClampFinite(dto.InspectorWidth, 320.0, NativePaneLayout.InspectorMinWidth, NativePaneLayout.InspectorMaxWidth);
            double drawerHeight = SingleSpectroscopyState.ClampedHeight(
                dto.SingleSpectroscopyDrawerHeight ?? SingleSpectroscopyState.DefaultHeight);

            var expanded = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            if (dto.ExpandedTagIdsByDataset is not null)
            {
                foreach ((string k, List<string> v) in dto.ExpandedTagIdsByDataset)
                {
                    if (!string.IsNullOrWhiteSpace(k) && v is not null)
                    {
                        expanded[k] = [.. v.Where(s => !string.IsNullOrWhiteSpace(s))];
                    }
                }
            }

            return new BrowserPreferencesSnapshot
            {
                StmPreviewPalette = stmPalette,
                SortCriterion = sortCriterion,
                SortAscending = dto.SortAscending ?? false,
                SidebarVisible = dto.SidebarVisible ?? true,
                InspectorVisible = dto.InspectorVisible ?? true,
                SidebarWidth = sidebarWidth,
                InspectorWidth = inspectorWidth,
                HistogramBins = bins,
                GridDensity = density,
                ShowsGridSpectroscopyCards = dto.ShowsGridSpectroscopyCards ?? true,
                SingleSpectroscopyDrawerExpanded = dto.SingleSpectroscopyDrawerExpanded ?? true,
                SingleSpectroscopyDrawerHeight = drawerHeight,
                ThemeMode = themeMode,
                LastOpenedFolderPath = dto.LastOpenedFolderPath,
                ExpandedTagIdsByDataset = expanded
            };
        }
        catch
        {
            return new BrowserPreferencesSnapshot();
        }
    }

    public void Save(BrowserPreferencesSnapshot snapshot)
    {
        string dir = Path.GetDirectoryName(FilePath)
            ?? throw new IOException($"Cannot determine directory for {FilePath}.");
        Directory.CreateDirectory(dir);

        var dto = new PreferencesDto
        {
            SchemaVersion = 1,
            StmPreviewPalette = snapshot.StmPreviewPalette.ToRawValue(),
            SortCriterion = snapshot.SortCriterion switch
            {
                FileSortCriterion.ModifiedTime => "modifiedTime",
                FileSortCriterion.RecordedTime => "recordedTime",
                _ => "name"
            },
            SortAscending = snapshot.SortAscending,
            SidebarVisible = snapshot.SidebarVisible,
            InspectorVisible = snapshot.InspectorVisible,
            SidebarWidth = snapshot.SidebarWidth,
            InspectorWidth = snapshot.InspectorWidth,
            HistogramBins = snapshot.HistogramBins,
            GridDensity = snapshot.GridDensity.ToRawValue(),
            ShowsGridSpectroscopyCards = snapshot.ShowsGridSpectroscopyCards,
            SingleSpectroscopyDrawerExpanded = snapshot.SingleSpectroscopyDrawerExpanded,
            SingleSpectroscopyDrawerHeight = snapshot.SingleSpectroscopyDrawerHeight,
            ThemeMode = snapshot.ThemeMode.ToRawValue(),
            LastOpenedFolderPath = snapshot.LastOpenedFolderPath,
            ExpandedTagIdsByDataset = snapshot.ExpandedTagIdsByDataset
        };

        byte[] utf8 = JsonSerializer.SerializeToUtf8Bytes(dto, SerializerOptions);
        string tempPath = Path.Combine(dir, $".preferences-v1.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var fs = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                fs.Write(utf8, 0, utf8.Length);
                fs.Flush(flushToDisk: true);
            }
            File.Move(tempPath, FilePath, overwrite: true);
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

    private static double ClampFinite(double? value, double fallback, double min, double max)
    {
        if (value is not double v || !double.IsFinite(v)) return fallback;
        return Math.Min(max, Math.Max(min, v));
    }
}
