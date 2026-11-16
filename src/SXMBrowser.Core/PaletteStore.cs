using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SXMBrowser.Core;

public readonly record struct PaletteStop(
    [property: JsonPropertyName("position")] double Position,
    [property: JsonPropertyName("r")] double R,
    [property: JsonPropertyName("g")] double G,
    [property: JsonPropertyName("b")] double B);

public enum PaletteCatalogErrorKind
{
    DecodingFailed,
    UnsupportedSchemaVersion,
    UnknownPalette,
    DuplicatePalette,
    MissingPalettes,
    InsufficientStops,
    NonFiniteStop,
    OutOfRangeStop,
    UnorderedStops,
    IncompleteRange
}

public sealed class PaletteCatalogException : Exception
{
    public PaletteCatalogErrorKind Kind { get; }

    public PaletteCatalogException(PaletteCatalogErrorKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }
}

public sealed class PaletteLookup
{
    private readonly PaletteStop[] _stops;
    public IReadOnlyList<PaletteStop> Stops => _stops;
    public bool IsUniformUnitGrid { get; }
    private readonly int _segmentCount;
    private readonly double _segmentScale;

    public PaletteLookup(IReadOnlyList<PaletteStop> stops)
    {
        _stops = stops is PaletteStop[] arr ? (PaletteStop[])arr.Clone() : stops.ToArray();
        int count = _stops.Length - 1;
        _segmentCount = Math.Max(0, count);
        _segmentScale = Math.Max(1, count);

        if (count >= 1 && (count & (count - 1)) == 0)
        {
            double scale = count;
            bool uniform = true;
            for (int i = 0; i < _stops.Length; i++)
            {
                if (_stops[i].Position != i / scale)
                {
                    uniform = false;
                    break;
                }
            }
            IsUniformUnitGrid = uniform;
        }
        else
        {
            IsUniformUnitGrid = false;
        }
    }

    public (double R, double G, double B) ColorAt(double value)
    {
        if (_stops.Length == 0)
        {
            return (value, value, value);
        }
        PaletteStop first = _stops[0];
        PaletteStop last = _stops[^1];
        if (value <= first.Position) return (first.R, first.G, first.B);
        if (value >= last.Position) return (last.R, last.G, last.B);
        if (!double.IsFinite(value)) return (last.R, last.G, last.B);

        if (IsUniformUnitGrid)
        {
            int index = Math.Min(_segmentCount - 1, Math.Max(0, (int)(value * _segmentScale)));
            PaletteStop a = _stops[index];
            PaletteStop b = _stops[index + 1];
            double t = (value - a.Position) * _segmentScale;
            return (
                a.R * (1.0 - t) + b.R * t,
                a.G * (1.0 - t) + b.G * t,
                a.B * (1.0 - t) + b.B * t);
        }

        // Binary search fallback for arbitrary non-uniform stop spacing (e.g. Gwyddion.net).
        int lower = 1;
        int upper = _stops.Length - 1;
        while (lower < upper)
        {
            int middle = lower + (upper - lower) / 2;
            if (value <= _stops[middle].Position)
            {
                upper = middle;
            }
            else
            {
                lower = middle + 1;
            }
        }
        PaletteStop left = _stops[lower - 1];
        PaletteStop right = _stops[lower];
        double span = Math.Max(1e-12, right.Position - left.Position);
        double frac = (value - left.Position) / span;
        return (
            left.R * (1.0 - frac) + right.R * frac,
            left.G * (1.0 - frac) + right.G * frac,
            left.B * (1.0 - frac) + right.B * frac);
    }
}

public sealed class PaletteStore
{
    public static PaletteStore Shared { get; } = LoadEmbedded();

    private readonly Dictionary<PaletteName, PaletteLookup> _lookupsByPalette;

    private static PaletteStore LoadEmbedded()
    {
        Assembly asm = typeof(PaletteStore).Assembly;
        const string resourceName = "SXMBrowser.Core.Resources.palettes.json";
        using Stream? stream = asm.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Missing embedded resource {resourceName}.");
        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        return new PaletteStore(ms.ToArray());
    }

    public PaletteStore(ReadOnlySpan<byte> data)
    {
        PaletteCatalogResource? resource;
        try
        {
            resource = JsonSerializer.Deserialize<PaletteCatalogResource>(data);
        }
        catch (Exception ex)
        {
            throw new PaletteCatalogException(
                PaletteCatalogErrorKind.DecodingFailed,
                $"The embedded palette catalog could not be decoded: {ex.Message}");
        }

        if (resource is null || resource.Palettes is null)
        {
            throw new PaletteCatalogException(
                PaletteCatalogErrorKind.DecodingFailed,
                "The embedded palette catalog could not be decoded.");
        }

        if (resource.SchemaVersion != 1)
        {
            throw new PaletteCatalogException(
                PaletteCatalogErrorKind.UnsupportedSchemaVersion,
                $"Palette catalog schema version {resource.SchemaVersion} is not supported.");
        }

        var catalog = new Dictionary<PaletteName, PaletteLookup>(SXMValueExtensions.AllPalettes.Count);

        foreach (PaletteResource entry in resource.Palettes)
        {
            if (!SXMValueExtensions.TryParsePaletteName(entry.Name, out PaletteName palette))
            {
                throw new PaletteCatalogException(
                    PaletteCatalogErrorKind.UnknownPalette,
                    $"Palette catalog contains unknown palette \u201C{entry.Name}\u201D.");
            }
            if (catalog.ContainsKey(palette))
            {
                throw new PaletteCatalogException(
                    PaletteCatalogErrorKind.DuplicatePalette,
                    $"Palette catalog contains duplicate palette \u201C{palette.ToRawValue()}\u201D.");
            }
            if (entry.Stops is null)
            {
                throw new PaletteCatalogException(
                    PaletteCatalogErrorKind.InsufficientStops,
                    $"Palette \u201C{palette.ToRawValue()}\u201D must contain at least two stops.");
            }
            ValidateStops(entry.Stops, palette);
            catalog[palette] = new PaletteLookup(entry.Stops);
        }

        var missing = SXMValueExtensions.AllPalettes.Where(p => !catalog.ContainsKey(p)).ToArray();
        if (missing.Length > 0)
        {
            throw new PaletteCatalogException(
                PaletteCatalogErrorKind.MissingPalettes,
                $"Palette catalog is missing: {string.Join(", ", missing.Select(p => p.ToRawValue()))}.");
        }

        _lookupsByPalette = catalog;
    }

    public PaletteLookup Lookup(PaletteName palette)
    {
        if (!_lookupsByPalette.TryGetValue(palette, out PaletteLookup? lookup))
        {
            throw new InvalidOperationException($"Validated palette catalog is missing {palette.ToRawValue()}.");
        }
        return lookup;
    }

    public IReadOnlyList<PaletteStop> Stops(PaletteName palette) => Lookup(palette).Stops;

    private static void ValidateStops(List<PaletteStop> stops, PaletteName palette)
    {
        if (stops.Count < 2)
        {
            throw new PaletteCatalogException(
                PaletteCatalogErrorKind.InsufficientStops,
                $"Palette \u201C{palette.ToRawValue()}\u201D must contain at least two stops.");
        }

        for (int index = 0; index < stops.Count; index++)
        {
            PaletteStop stop = stops[index];
            double[] values = [stop.Position, stop.R, stop.G, stop.B];
            foreach (double v in values)
            {
                if (!double.IsFinite(v))
                {
                    throw new PaletteCatalogException(
                        PaletteCatalogErrorKind.NonFiniteStop,
                        $"Palette \u201C{palette.ToRawValue()}\u201D stop {index} contains a non-finite value.");
                }
            }
            foreach (double v in values)
            {
                if (v < 0.0 || v > 1.0)
                {
                    throw new PaletteCatalogException(
                        PaletteCatalogErrorKind.OutOfRangeStop,
                        $"Palette \u201C{palette.ToRawValue()}\u201D stop {index} is outside the 0...1 range.");
                }
            }
            if (index > 0 && stop.Position <= stops[index - 1].Position)
            {
                throw new PaletteCatalogException(
                    PaletteCatalogErrorKind.UnorderedStops,
                    $"Palette \u201C{palette.ToRawValue()}\u201D stop {index} is not strictly increasing.");
            }
        }

        if (stops[0].Position != 0.0 || stops[^1].Position != 1.0)
        {
            throw new PaletteCatalogException(
                PaletteCatalogErrorKind.IncompleteRange,
                $"Palette \u201C{palette.ToRawValue()}\u201D must span exactly 0...1.");
        }
    }

    private sealed class PaletteCatalogResource
    {
        [JsonPropertyName("schemaVersion")]
        public int SchemaVersion { get; set; }

        [JsonPropertyName("palettes")]
        public List<PaletteResource>? Palettes { get; set; }
    }

    private sealed class PaletteResource
    {
        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;

        [JsonPropertyName("stops")]
        public List<PaletteStop>? Stops { get; set; }
    }
}
