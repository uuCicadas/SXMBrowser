using System;
using System.Collections.Generic;
using System.Linq;

namespace SXMBrowser.Core;

public static class NumericalConstants
{
    /// <summary>
    /// IEEE-754 binary64 machine epsilon (2^-52), matching Swift Double.ulpOfOne.
    /// Do not replace with C# double.Epsilon (which is the smallest subnormal 5e-324).
    /// </summary>
    public const double DoubleUlpOfOne = 2.2204460492503130808472633361816E-16;
}

public enum ScanDirection
{
    Fwd,
    Bwd
}

public enum ChannelKind
{
    Topography,
    ConductanceOrCurrent,
    Afm
}

public enum ProcessingMode
{
    Raw,
    LineMean,
    LineSlope,
    LineLinear,
    LineDerivative,
    PlaneLinear
}

public enum PaletteName
{
    Gwyddion,
    DuskViolet,
    BlueViolet,
    Ember,
    Gray
}

public static class SXMValueExtensions
{
    public static readonly IReadOnlyList<ScanDirection> AllDirections =
        [ScanDirection.Fwd, ScanDirection.Bwd];

    public static readonly IReadOnlyList<ProcessingMode> AllProcessingModes =
    [
        ProcessingMode.Raw,
        ProcessingMode.LineMean,
        ProcessingMode.LineSlope,
        ProcessingMode.LineLinear,
        ProcessingMode.LineDerivative,
        ProcessingMode.PlaneLinear
    ];

    public static readonly IReadOnlyList<PaletteName> AllPalettes =
    [
        PaletteName.Gwyddion,
        PaletteName.DuskViolet,
        PaletteName.BlueViolet,
        PaletteName.Ember,
        PaletteName.Gray
    ];

    public static string ToRawValue(this ScanDirection direction) => direction switch
    {
        ScanDirection.Fwd => "fwd",
        ScanDirection.Bwd => "bwd",
        _ => throw new ArgumentOutOfRangeException(nameof(direction), direction, null)
    };

    public static bool TryParseScanDirection(string? raw, out ScanDirection direction)
    {
        switch (raw)
        {
            case "fwd":
                direction = ScanDirection.Fwd;
                return true;
            case "bwd":
                direction = ScanDirection.Bwd;
                return true;
            default:
                direction = default;
                return false;
        }
    }

    public static string Label(this ScanDirection direction) => direction switch
    {
        ScanDirection.Fwd => "Forward",
        ScanDirection.Bwd => "Backward",
        _ => throw new ArgumentOutOfRangeException(nameof(direction), direction, null)
    };

    public static bool UsesSTMPalette(this ChannelKind kind) => kind != ChannelKind.Afm;

    public static string ToRawValue(this ChannelKind kind) => kind switch
    {
        ChannelKind.Topography => "topography",
        ChannelKind.ConductanceOrCurrent => "conductanceOrCurrent",
        ChannelKind.Afm => "afm",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null)
    };

    public static string ToRawValue(this ProcessingMode mode) => mode switch
    {
        ProcessingMode.Raw => "raw",
        ProcessingMode.LineMean => "lineMean",
        ProcessingMode.LineSlope => "lineSlope",
        ProcessingMode.LineLinear => "lineLinear",
        ProcessingMode.LineDerivative => "lineDerivative",
        ProcessingMode.PlaneLinear => "planeLinear",
        _ => throw new ArgumentOutOfRangeException(nameof(mode), mode, null)
    };

    public static bool TryParseProcessingMode(string? raw, out ProcessingMode mode)
    {
        switch (raw)
        {
            case "raw":
                mode = ProcessingMode.Raw;
                return true;
            case "lineMean":
                mode = ProcessingMode.LineMean;
                return true;
            case "lineSlope":
                mode = ProcessingMode.LineSlope;
                return true;
            case "lineLinear":
                mode = ProcessingMode.LineLinear;
                return true;
            case "lineDerivative":
                mode = ProcessingMode.LineDerivative;
                return true;
            case "planeLinear":
                mode = ProcessingMode.PlaneLinear;
                return true;
            default:
                mode = default;
                return false;
        }
    }

    public static string Label(this ProcessingMode mode) => mode switch
    {
        ProcessingMode.Raw => "Raw",
        ProcessingMode.LineMean => "Subtract average",
        ProcessingMode.LineSlope => "Subtract slope",
        ProcessingMode.LineLinear => "Subtract linear fit",
        ProcessingMode.LineDerivative => "Differentiate",
        ProcessingMode.PlaneLinear => "Plane linear fit",
        _ => throw new ArgumentOutOfRangeException(nameof(mode), mode, null)
    };

    public static string ToRawValue(this PaletteName palette) => palette switch
    {
        PaletteName.Gwyddion => "gwyddion",
        PaletteName.DuskViolet => "duskViolet",
        PaletteName.BlueViolet => "blueViolet",
        PaletteName.Ember => "ember",
        PaletteName.Gray => "gray",
        _ => throw new ArgumentOutOfRangeException(nameof(palette), palette, null)
    };

    public static bool TryParsePaletteName(string? raw, out PaletteName palette)
    {
        switch (raw)
        {
            case "gwyddion":
                palette = PaletteName.Gwyddion;
                return true;
            case "duskViolet":
                palette = PaletteName.DuskViolet;
                return true;
            case "blueViolet":
                palette = PaletteName.BlueViolet;
                return true;
            case "ember":
                palette = PaletteName.Ember;
                return true;
            case "gray":
                palette = PaletteName.Gray;
                return true;
            default:
                palette = default;
                return false;
        }
    }

    public static string Label(this PaletteName palette) => palette switch
    {
        PaletteName.Gwyddion => "Gwyddion",
        PaletteName.DuskViolet => "Dusk Violet",
        PaletteName.BlueViolet => "Ink Violet",
        PaletteName.Ember => "Ember",
        PaletteName.Gray => "Basic gray",
        _ => throw new ArgumentOutOfRangeException(nameof(palette), palette, null)
    };
}

public sealed class SXMChannel : IEquatable<SXMChannel>
{
    public string Id => Name;
    public string Name { get; }
    public string Unit { get; }
    public IReadOnlyList<ScanDirection> Directions { get; }
    public ChannelKind Kind { get; }

    public SXMChannel(
        string name,
        string unit,
        IReadOnlyList<ScanDirection> directions,
        ChannelKind kind)
    {
        Name = name;
        Unit = unit;
        Directions = directions;
        Kind = kind;
    }

    public bool Equals(SXMChannel? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return string.Equals(Name, other.Name, StringComparison.Ordinal)
            && string.Equals(Unit, other.Unit, StringComparison.Ordinal)
            && Kind == other.Kind
            && Directions.SequenceEqual(other.Directions);
    }

    public override bool Equals(object? obj) => Equals(obj as SXMChannel);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Name, StringComparer.Ordinal);
        hash.Add(Unit, StringComparer.Ordinal);
        hash.Add(Kind);
        foreach (var dir in Directions)
        {
            hash.Add(dir);
        }
        return hash.ToHashCode();
    }
}

public sealed class SXMMetadata : IEquatable<SXMMetadata>
{
    public Guid Id { get; }
    public string Path { get; }
    public string Filename { get; }
    public IReadOnlyDictionary<string, string> Header { get; }
    public DateTimeOffset? RecordedTime { get; }
    public DateTimeOffset ModifiedTime { get; }
    public (int Width, int Height) Pixels { get; }
    public (double X, double Y)? ScanRange { get; }
    public (double X, double Y)? ScanOffset { get; }
    public double? ScanAngle { get; }
    public string? ScanDir { get; }
    public bool? ZControllerOn { get; }
    public IReadOnlyList<SXMChannel> Channels { get; }
    public string? DefaultChannel { get; }

    public SXMMetadata(
        Guid? id,
        string path,
        string filename,
        IReadOnlyDictionary<string, string> header,
        DateTimeOffset? recordedTime,
        DateTimeOffset modifiedTime,
        (int Width, int Height) pixels,
        (double X, double Y)? scanRange,
        (double X, double Y)? scanOffset,
        double? scanAngle,
        string? scanDir,
        bool? zControllerOn,
        IReadOnlyList<SXMChannel> channels,
        string? defaultChannel)
    {
        Id = id ?? Guid.NewGuid();
        Path = path;
        Filename = filename;
        Header = header;
        RecordedTime = recordedTime;
        ModifiedTime = modifiedTime;
        Pixels = pixels;
        ScanRange = scanRange;
        ScanOffset = scanOffset;
        ScanAngle = scanAngle;
        ScanDir = scanDir;
        ZControllerOn = zControllerOn;
        Channels = channels;
        DefaultChannel = defaultChannel;
    }

    public bool Equals(SXMMetadata? other) => other is not null && Id == other.Id;
    public override bool Equals(object? obj) => Equals(obj as SXMMetadata);
    public override int GetHashCode() => Id.GetHashCode();
}

public sealed class Matrix
{
    public int Width { get; }
    public int Height { get; }
    public float[] Values { get; }

    public Matrix(int width, int height, float[] values)
    {
        Width = width;
        Height = height;
        Values = values;
    }

    public float this[int x, int y]
    {
        get => Values[y * Width + x];
        set => Values[y * Width + x] = value;
    }

    public Matrix Clone() => new(Width, Height, (float[])Values.Clone());
}

public readonly record struct MatrixKey(string Channel, ScanDirection Direction);

public sealed record SXMFullFile(
    SXMMetadata Metadata,
    IReadOnlyDictionary<MatrixKey, Matrix> Matrices);

public sealed record MatrixStatistics(
    int Count,
    double Min,
    double Max,
    double P1,
    double P99,
    double Mean,
    double Std);

public sealed class HistogramDistribution : IEquatable<HistogramDistribution>
{
    public int Bins { get; }
    public int[] Counts { get; }
    public double[] Edges { get; }

    public HistogramDistribution(int bins, int[] counts, double[] edges)
    {
        Bins = bins;
        Counts = counts;
        Edges = edges;
    }

    public bool Equals(HistogramDistribution? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return Bins == other.Bins
            && Counts.AsSpan().SequenceEqual(other.Counts)
            && Edges.AsSpan().SequenceEqual(other.Edges);
    }

    public override bool Equals(object? obj) => Equals(obj as HistogramDistribution);

    public override int GetHashCode() => HashCode.Combine(Bins, Counts.Length, Edges.Length);
}

public sealed record HistogramStats(
    MatrixStatistics Statistics,
    HistogramDistribution Distribution)
{
    public int Count => Statistics.Count;
    public double Min => Statistics.Min;
    public double Max => Statistics.Max;
    public double P1 => Statistics.P1;
    public double P99 => Statistics.P99;
    public double Mean => Statistics.Mean;
    public double Std => Statistics.Std;
    public int Bins => Distribution.Bins;
    public int[] Hist => Distribution.Counts;
    public double[] Edges => Distribution.Edges;
}

public sealed record RenderOptions(
    string Channel,
    ScanDirection Direction,
    ProcessingMode Processing,
    PaletteName Palette,
    double? Vmin = null,
    double? Vmax = null,
    int? OutputSize = null,
    bool Invert = false,
    bool TransparentMissingValues = false);

public sealed record RenderedImage(
    int Width,
    int Height,
    byte[] RgbaBytes);

public static class SXMChannelRules
{
    private static readonly string[] AfmKeywords =
    [
        "frequency shift", "freq", "df", "delta f",
        "amplitude", "excitation", "pll", "oc_"
    ];

    private static readonly string[] FrequencyShiftKeywords =
    [
        "frequency shift", "freq", "df", "delta f", "\u03B4f"
    ];

    public static bool IsFrequencyShiftChannel(string name)
    {
        string folded = name.ToLowerInvariant();
        foreach (string kw in FrequencyShiftKeywords)
        {
            if (folded.Contains(kw, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return name.Contains("\u0394f", StringComparison.Ordinal);
    }

    /// <summary>
    /// Returns true when :SCAN_DIR: explicitly specifies an upward scan.
    /// </summary>
    public static bool IsUpwardScanDirection(string? scanDir)
    {
        if (string.IsNullOrEmpty(scanDir)) return false;

        int i = 0;
        while (i < scanDir.Length)
        {
            while (i < scanDir.Length && !char.IsLetter(scanDir[i]))
            {
                i++;
            }
            if (i >= scanDir.Length) break;
            int start = i;
            while (i < scanDir.Length && char.IsLetter(scanDir[i]))
            {
                i++;
            }
            if (scanDir.AsSpan(start, i - start).Equals("up", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    public static ChannelKind ClassifyChannel(string name)
    {
        string folded = name.ToLowerInvariant();
        foreach (string kw in AfmKeywords)
        {
            if (folded.Contains(kw, StringComparison.Ordinal))
            {
                return ChannelKind.Afm;
            }
        }
        if (name.Contains("Δf", StringComparison.Ordinal))
        {
            return ChannelKind.Afm;
        }

        // Split folded string by non-alphanumeric tokens
        int i = 0;
        while (i < folded.Length)
        {
            while (i < folded.Length && !char.IsLetterOrDigit(folded[i]))
            {
                i++;
            }
            if (i >= folded.Length) break;
            int start = i;
            while (i < folded.Length && char.IsLetterOrDigit(folded[i]))
            {
                i++;
            }
            if (folded.AsSpan(start, i - start).SequenceEqual("z"))
            {
                return ChannelKind.Topography;
            }
        }

        if (folded.Contains("topograph", StringComparison.Ordinal)
            || folded.Contains("height", StringComparison.Ordinal))
        {
            return ChannelKind.Topography;
        }

        return ChannelKind.ConductanceOrCurrent;
    }

    /// <summary>
    /// Windows edition defaults all STM channels (Topography & Conductance/Current)
    /// to Gwyddion, while AFM/PLL channels default to Basic gray.
    /// </summary>
    public static PaletteName DefaultPalette(string channelName) =>
        ClassifyChannel(channelName).UsesSTMPalette()
            ? PaletteName.Gwyddion
            : PaletteName.Gray;

    public static ProcessingMode DefaultProcessing(string channelName) =>
        ClassifyChannel(channelName) == ChannelKind.Topography
            ? ProcessingMode.PlaneLinear
            : ProcessingMode.Raw;
}
