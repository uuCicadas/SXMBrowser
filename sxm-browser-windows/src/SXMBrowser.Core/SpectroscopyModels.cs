using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace SXMBrowser.Core;

public enum SpectroscopyKind
{
    Z,
    Bias,
    Other
}

public static class SpectroscopyKindExtensions
{
    public static string ToRawValue(this SpectroscopyKind kind) => kind switch
    {
        SpectroscopyKind.Z => "z",
        SpectroscopyKind.Bias => "bias",
        SpectroscopyKind.Other => "other",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null)
    };

    public static bool TryParse(string? raw, out SpectroscopyKind kind)
    {
        switch (raw)
        {
            case "z":
                kind = SpectroscopyKind.Z;
                return true;
            case "bias":
                kind = SpectroscopyKind.Bias;
                return true;
            case "other":
                kind = SpectroscopyKind.Other;
                return true;
            default:
                kind = default;
                return false;
        }
    }

    public static string Label(this SpectroscopyKind kind) => kind switch
    {
        SpectroscopyKind.Z => "Z",
        SpectroscopyKind.Bias => "Bias",
        SpectroscopyKind.Other => "Spectrum",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null)
    };

    public static int SortRank(this SpectroscopyKind kind) => kind switch
    {
        SpectroscopyKind.Z => 0,
        SpectroscopyKind.Bias => 1,
        SpectroscopyKind.Other => 2,
        _ => 3
    };
}

public static class SpectroscopyExperimentIdentity
{
    public static string Make(string? experiment, SpectroscopyKind fallbackKind)
    {
        string raw = experiment ?? string.Empty;
        string nfc = SafeNormalizeNfc(raw);
        string joined = TextSplitHelpers.JoinWhitespaceNormalized(nfc).ToLowerInvariant();
        return joined.Length == 0 ? fallbackKind.ToRawValue() : joined;
    }

    internal static string SafeNormalizeNfc(string value)
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

    internal static string DeterministicFingerprint(IEnumerable<string> components)
    {
        string identity = string.Join(
            '|',
            components.Select(c => $"{Encoding.UTF8.GetByteCount(c)}:{c}"));
        ulong hash = 14_695_981_039_346_656_037UL;
        foreach (byte b in Encoding.UTF8.GetBytes(identity))
        {
            hash ^= b;
            unchecked
            {
                hash *= 1_099_511_628_211UL;
            }
        }
        return hash.ToString("x16", CultureInfo.InvariantCulture);
    }
}

public sealed class SpectroscopyColumnSchema : IEquatable<SpectroscopyColumnSchema>
{
    public IReadOnlyList<string> NormalizedColumns { get; }
    public string Fingerprint { get; }

    public SpectroscopyColumnSchema(IReadOnlyList<string> columns)
    {
        var normalized = new string[columns.Count];
        for (int i = 0; i < columns.Count; i++)
        {
            normalized[i] = Normalize(columns[i]);
        }
        NormalizedColumns = normalized;
        Fingerprint = SpectroscopyExperimentIdentity.DeterministicFingerprint(normalized);
    }

    public static string Normalize(string column)
    {
        string nfc = SpectroscopyExperimentIdentity.SafeNormalizeNfc(column);
        return TextSplitHelpers.JoinWhitespaceNormalized(nfc).ToLowerInvariant();
    }

    public bool Equals(SpectroscopyColumnSchema? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return string.Equals(Fingerprint, other.Fingerprint, StringComparison.Ordinal)
            && NormalizedColumns.SequenceEqual(other.NormalizedColumns, StringComparer.Ordinal);
    }

    public override bool Equals(object? obj) => Equals(obj as SpectroscopyColumnSchema);

    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Fingerprint);
}

public sealed class SpectroscopyGroupKey : IEquatable<SpectroscopyGroupKey>
{
    public SpectroscopyKind Kind { get; }
    public string ExperimentIdentity { get; }
    public SpectroscopyColumnSchema ColumnSchema { get; }
    public string Fingerprint { get; }

    public SpectroscopyGroupKey(
        SpectroscopyKind kind,
        string? experiment,
        SpectroscopyColumnSchema columnSchema)
    {
        Kind = kind;
        ExperimentIdentity = SpectroscopyExperimentIdentity.Make(experiment, kind);
        ColumnSchema = columnSchema;
        Fingerprint = SpectroscopyExperimentIdentity.DeterministicFingerprint(
            [kind.ToRawValue(), ExperimentIdentity, columnSchema.Fingerprint]);
    }

    public SpectroscopyGroupKey(
        SpectroscopyKind kind,
        SpectroscopyColumnSchema columnSchema)
        : this(kind, experiment: null, columnSchema)
    {
    }

    public bool Equals(SpectroscopyGroupKey? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return Kind == other.Kind
            && string.Equals(ExperimentIdentity, other.ExperimentIdentity, StringComparison.Ordinal)
            && ColumnSchema.Equals(other.ColumnSchema);
    }

    public override bool Equals(object? obj) => Equals(obj as SpectroscopyGroupKey);

    public override int GetHashCode() =>
        HashCode.Combine(Kind, StringComparer.Ordinal.GetHashCode(ExperimentIdentity), ColumnSchema);
}

public sealed class SpectroscopyCurve
{
    public Guid Id { get; }
    public string Filename { get; }
    public DateTimeOffset ModifiedTime { get; }
    public IReadOnlyList<string> Columns { get; }
    public IReadOnlyDictionary<string, double[]> ValuesByColumn { get; }
    public double[] X { get; }
    public double[] Y { get; }
    public SpectroscopyColumnSchema ColumnSchema { get; }

    public SpectroscopyCurve(
        Guid? id,
        string filename,
        DateTimeOffset modifiedTime,
        IReadOnlyList<string> columns,
        IReadOnlyDictionary<string, double[]> valuesByColumn,
        double[] x,
        double[] y)
    {
        Id = id ?? Guid.NewGuid();
        Filename = filename;
        ModifiedTime = modifiedTime;
        Columns = columns;
        ValuesByColumn = valuesByColumn;
        X = x;
        Y = y;
        ColumnSchema = new SpectroscopyColumnSchema(columns);
    }

    public (double X, double Y)[]? Points(string xColumn, string yColumn)
    {
        string? xKey = ColumnKeyMatching(xColumn);
        string? yKey = ColumnKeyMatching(yColumn);
        if (xKey is null || yKey is null) return null;
        if (!ValuesByColumn.TryGetValue(xKey, out double[]? xs)
            || !ValuesByColumn.TryGetValue(yKey, out double[]? ys))
        {
            return null;
        }
        int count = Math.Min(xs.Length, ys.Length);
        var pts = new (double X, double Y)[count];
        for (int i = 0; i < count; i++)
        {
            pts[i] = (xs[i], ys[i]);
        }
        return pts;
    }

    internal (double X, double Y)[]? PointsByIndex(int xColumnIndex, int yColumnIndex)
    {
        if ((uint)xColumnIndex >= (uint)Columns.Count
            || (uint)yColumnIndex >= (uint)Columns.Count)
        {
            return null;
        }
        if (!ValuesByColumn.TryGetValue(Columns[xColumnIndex], out double[]? xs)
            || !ValuesByColumn.TryGetValue(Columns[yColumnIndex], out double[]? ys))
        {
            return null;
        }
        int count = Math.Min(xs.Length, ys.Length);
        var pts = new (double X, double Y)[count];
        for (int i = 0; i < count; i++)
        {
            pts[i] = (xs[i], ys[i]);
        }
        return pts;
    }

    private string? ColumnKeyMatching(string requestedColumn)
    {
        if (ValuesByColumn.ContainsKey(requestedColumn))
        {
            return requestedColumn;
        }
        string normalized = SpectroscopyColumnSchema.Normalize(requestedColumn);
        string? match = null;
        int matchCount = 0;
        foreach (string col in Columns)
        {
            if (string.Equals(SpectroscopyColumnSchema.Normalize(col), normalized, StringComparison.Ordinal))
            {
                match = col;
                matchCount++;
                if (matchCount > 1) return null;
            }
        }
        return matchCount == 1 ? match : null;
    }
}

public sealed class SpectroscopyFile : IEquatable<SpectroscopyFile>
{
    public Guid Id { get; }
    public string Path { get; }
    public string Filename { get; }
    public SpectroscopyKind Kind { get; }
    public string Experiment { get; }
    public string ExperimentIdentity { get; }
    public DateTimeOffset ModifiedTime { get; }
    public DateTimeOffset? SavedTime { get; }
    public (double X, double Y)? Position { get; }
    public string XLabel { get; }
    public string YLabel { get; }
    public int ColorIndex { get; }
    public SpectroscopyCurve Curve { get; }

    public SpectroscopyFile(
        Guid? id,
        string path,
        string filename,
        SpectroscopyKind kind,
        string experiment,
        string? experimentIdentity,
        DateTimeOffset modifiedTime,
        DateTimeOffset? savedTime,
        (double X, double Y)? position,
        string xLabel,
        string yLabel,
        int colorIndex,
        SpectroscopyCurve curve)
    {
        Id = id ?? Guid.NewGuid();
        Path = path;
        Filename = filename;
        Kind = kind;
        Experiment = experiment;
        ExperimentIdentity = SpectroscopyExperimentIdentity.Make(experimentIdentity ?? experiment, kind);
        ModifiedTime = modifiedTime;
        SavedTime = savedTime;
        Position = position;
        XLabel = xLabel;
        YLabel = yLabel;
        ColorIndex = colorIndex;
        Curve = curve;
    }

    public bool Equals(SpectroscopyFile? other) => other is not null && Id == other.Id;
    public override bool Equals(object? obj) => Equals(obj as SpectroscopyFile);
    public override int GetHashCode() => Id.GetHashCode();
}

public sealed class SpectroscopyGroup : IEquatable<SpectroscopyGroup>
{
    public string Id { get; }
    public Guid SxmId { get; }
    public string SxmFilename { get; }
    public SpectroscopyKind Kind { get; }
    public string Experiment { get; }
    public string ExperimentIdentity { get; }
    public SpectroscopyColumnSchema ColumnSchema { get; }
    public string XLabel { get; }
    public string YLabel { get; }
    public IReadOnlyList<SpectroscopyFile> Spectra { get; }
    public string RenderId { get; }

    private SpectroscopyGroup(
        string id,
        Guid sxmId,
        string sxmFilename,
        SpectroscopyKind kind,
        string experiment,
        string experimentIdentity,
        SpectroscopyColumnSchema columnSchema,
        string xLabel,
        string yLabel,
        IReadOnlyList<SpectroscopyFile> spectra,
        string renderId)
    {
        Id = id;
        SxmId = sxmId;
        SxmFilename = sxmFilename;
        Kind = kind;
        Experiment = experiment;
        ExperimentIdentity = experimentIdentity;
        ColumnSchema = columnSchema;
        XLabel = xLabel;
        YLabel = yLabel;
        Spectra = spectra;
        RenderId = renderId;
    }

    public static SpectroscopyGroup? Create(
        SXMMetadata sxm,
        SpectroscopyGroupKey key,
        IReadOnlyList<SpectroscopyFile> spectra)
    {
        if (spectra.Count == 0) return null;
        foreach (SpectroscopyFile s in spectra)
        {
            if (s.Kind != key.Kind
                || !string.Equals(s.ExperimentIdentity, key.ExperimentIdentity, StringComparison.Ordinal)
                || !s.Curve.ColumnSchema.Equals(key.ColumnSchema))
            {
                return null;
            }
        }

        var ordered = spectra
            .OrderBy(s => s.Filename, NaturalStringComparer.Instance)
            .ToArray();

        string stableId = $"{sxm.Id.ToString("D").ToUpperInvariant()}-{key.Fingerprint}";
        string renderId = $"{stableId}-{string.Join(',', ordered.Select(s => s.Id.ToString("D").ToUpperInvariant()))}";
        SpectroscopyFile first = ordered[0];

        return new SpectroscopyGroup(
            stableId,
            sxm.Id,
            sxm.Filename,
            key.Kind,
            first.Experiment,
            key.ExperimentIdentity,
            key.ColumnSchema,
            string.IsNullOrEmpty(first.XLabel) ? "X" : first.XLabel,
            string.IsNullOrEmpty(first.YLabel) ? "Y" : first.YLabel,
            ordered,
            renderId);
    }

    public static List<SpectroscopyGroup> CompatibleGroups(
        SXMMetadata sxm,
        IReadOnlyList<SpectroscopyFile> spectra)
    {
        var buckets = new Dictionary<SpectroscopyGroupKey, List<SpectroscopyFile>>();
        foreach (SpectroscopyFile s in spectra)
        {
            var key = new SpectroscopyGroupKey(s.Kind, s.ExperimentIdentity, s.Curve.ColumnSchema);
            if (!buckets.TryGetValue(key, out List<SpectroscopyFile>? list))
            {
                list = [];
                buckets[key] = list;
            }
            list.Add(s);
        }

        var groups = new List<SpectroscopyGroup>(buckets.Count);
        foreach ((SpectroscopyGroupKey key, List<SpectroscopyFile> list) in buckets)
        {
            SpectroscopyGroup? group = Create(sxm, key, list);
            if (group is not null)
            {
                groups.Add(group);
            }
        }

        groups.Sort(CompareGroups);
        return groups;
    }

    public string Title => string.IsNullOrWhiteSpace(Experiment)
        ? $"{Kind.Label()} spectroscopy"
        : Experiment;

    public string CurveCountText => $"{Spectra.Count} line{(Spectra.Count == 1 ? "" : "s")}";

    public IReadOnlyList<string> AvailableColumns =>
        Spectra.Count > 0 ? Spectra[0].Curve.Columns : Array.Empty<string>();

    public string? CanonicalColumn(string column)
    {
        IReadOnlyList<string> cols = AvailableColumns;
        for (int i = 0; i < cols.Count; i++)
        {
            if (string.Equals(cols[i], column, StringComparison.Ordinal))
            {
                return cols[i];
            }
        }

        string normalized = SpectroscopyColumnSchema.Normalize(column);
        string? match = null;
        int matchCount = 0;
        for (int i = 0; i < cols.Count; i++)
        {
            if (string.Equals(SpectroscopyColumnSchema.Normalize(cols[i]), normalized, StringComparison.Ordinal))
            {
                match = cols[i];
                matchCount++;
                if (matchCount > 1) return null;
            }
        }
        return matchCount == 1 ? match : null;
    }

    public (double X, double Y)[]? Points(SpectroscopyFile spectrum, string xColumn, string yColumn)
    {
        bool containsSpectrum = false;
        for (int i = 0; i < Spectra.Count; i++)
        {
            if (Spectra[i].Id == spectrum.Id)
            {
                containsSpectrum = true;
                break;
            }
        }
        if (!containsSpectrum
            || spectrum.Kind != Kind
            || !spectrum.Curve.ColumnSchema.Equals(ColumnSchema))
        {
            return null;
        }

        string? canonicalX = CanonicalColumn(xColumn);
        string? canonicalY = CanonicalColumn(yColumn);
        if (canonicalX is null || canonicalY is null) return null;

        int xIndex = IndexOfExact(AvailableColumns, canonicalX);
        int yIndex = IndexOfExact(AvailableColumns, canonicalY);
        if (xIndex < 0 || yIndex < 0) return null;

        return spectrum.Curve.PointsByIndex(xIndex, yIndex);
    }

    public (double[] X, double[] Y)? ColumnSeries(
        SpectroscopyFile spectrum,
        string xColumn,
        string yColumn)
    {
        bool containsSpectrum = false;
        for (int i = 0; i < Spectra.Count; i++)
        {
            if (Spectra[i].Id == spectrum.Id)
            {
                containsSpectrum = true;
                break;
            }
        }
        if (!containsSpectrum
            || spectrum.Kind != Kind
            || !spectrum.Curve.ColumnSchema.Equals(ColumnSchema))
        {
            return null;
        }

        string? canonicalX = CanonicalColumn(xColumn);
        string? canonicalY = CanonicalColumn(yColumn);
        if (canonicalX is null || canonicalY is null) return null;

        if (!spectrum.Curve.ValuesByColumn.TryGetValue(canonicalX, out double[]? xValues)
            || !spectrum.Curve.ValuesByColumn.TryGetValue(canonicalY, out double[]? yValues))
        {
            return null;
        }

        return (xValues, yValues);
    }

    private static int IndexOfExact(IReadOnlyList<string> cols, string target)
    {
        for (int i = 0; i < cols.Count; i++)
        {
            if (string.Equals(cols[i], target, StringComparison.Ordinal))
            {
                return i;
            }
        }
        return -1;
    }

    private static int CompareGroups(SpectroscopyGroup lhs, SpectroscopyGroup rhs)
    {
        int rankDiff = lhs.Kind.SortRank().CompareTo(rhs.Kind.SortRank());
        if (rankDiff != 0) return rankDiff;

        int expDiff = string.CompareOrdinal(lhs.ExperimentIdentity, rhs.ExperimentIdentity);
        if (expDiff != 0) return expDiff;

        IReadOnlyList<string> lc = lhs.ColumnSchema.NormalizedColumns;
        IReadOnlyList<string> rc = rhs.ColumnSchema.NormalizedColumns;
        int minCount = Math.Min(lc.Count, rc.Count);
        for (int i = 0; i < minCount; i++)
        {
            int colDiff = string.CompareOrdinal(lc[i], rc[i]);
            if (colDiff != 0) return colDiff;
        }
        if (lc.Count != rc.Count)
        {
            return lc.Count.CompareTo(rc.Count);
        }

        return string.CompareOrdinal(lhs.Id, rhs.Id);
    }

    public bool Equals(SpectroscopyGroup? other) =>
        other is not null && string.Equals(RenderId, other.RenderId, StringComparison.Ordinal);

    public override bool Equals(object? obj) => Equals(obj as SpectroscopyGroup);
    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(RenderId);
}
