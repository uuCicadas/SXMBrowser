using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace SXMBrowser.Core;

public enum SpectroscopyParserErrorKind
{
    CannotRead,
    FileTooLarge,
    MissingData,
    MissingColumns,
    InsufficientValidRows
}

public sealed class SpectroscopyParserException : Exception
{
    public SpectroscopyParserErrorKind Kind { get; }
    public string FilePath { get; }
    public int? BadLineCount { get; }

    public SpectroscopyParserException(
        SpectroscopyParserErrorKind kind,
        string filePath,
        string message,
        int? badLineCount = null,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
        FilePath = filePath;
        BadLineCount = badLineCount;
    }
}

public sealed class SpectroscopyParser
{
    public const ulong MaximumFileByteCount = 64UL * 1024UL * 1024UL;
    private const int HeaderSniffByteCount = 262_144;
    private static readonly byte[] DataMarkerBytes = "[DATA]"u8.ToArray();

    private static readonly PosixDateParser SpectroscopyDateParser = new(
        "dd.MM.yyyy HH:mm:ss",
        "dd.MM.yy HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss");

    private static readonly (string Suffix, double Multiplier)[] SiMultipliers =
    [
        ("f", 1e-15),
        ("p", 1e-12),
        ("n", 1e-9),
        ("u", 1e-6),
        ("\u00B5", 1e-6), // MICRO SIGN µ
        ("m", 1e-3),
        ("k", 1e3),
        ("M", 1e6),
        ("G", 1e9)
    ];

    public ScanReport<SpectroscopyFile> ScanFolder(
        string folderPath,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var dir = new DirectoryInfo(folderPath);
        if (!dir.Exists)
        {
            throw new DirectoryNotFoundException($"Directory not found: {folderPath}");
        }

        var datPaths = dir.EnumerateFileSystemInfos()
            .Where(info => !SXMParser.IsHiddenEntry(info)
                && string.Equals(info.Extension, ".dat", StringComparison.OrdinalIgnoreCase))
            .Select(info => info.FullName)
            .OrderBy(p => p, Comparer<string>.Create(NaturalStringComparer.CompareFilenamesAndPaths))
            .ToList();

        var items = new List<SpectroscopyFile>(datPaths.Count);
        var issues = new List<ScanIssue>();

        foreach (string path in datPaths)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                (SpectroscopyFile file, int badLineCount) = LoadFileWithDiagnostics(path, cancellationToken);
                items.Add(file);
                if (badLineCount > 0)
                {
                    issues.Add(new ScanIssue(
                        path,
                        ScanStage.SpectroscopyRows,
                        $"Ignored {badLineCount} malformed data row{(badLineCount == 1 ? "" : "s")}.",
                        badLineCount));
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                int? badLineCount = (ex as SpectroscopyParserException)?.BadLineCount;
                issues.Add(new ScanIssue(path, ScanStage.SpectroscopyFile, ex.Message, badLineCount));
            }
        }

        return new ScanReport<SpectroscopyFile>(items, issues);
    }

    public SpectroscopyFile LoadFile(string filePath, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return LoadFileWithDiagnostics(filePath, cancellationToken).File;
    }

    private (SpectroscopyFile File, int BadLineCount) LoadFileWithDiagnostics(
        string filePath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        FileStream stream;
        try
        {
            stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new SpectroscopyParserException(
                SpectroscopyParserErrorKind.CannotRead,
                filePath,
                $"Cannot read spectroscopy file: {Path.GetFileName(filePath)}",
                innerException: ex);
        }

        byte[] data;
        using (stream)
        {
            ulong byteCount = (ulong)stream.Length;
            if (byteCount > MaximumFileByteCount)
            {
                throw new SpectroscopyParserException(
                    SpectroscopyParserErrorKind.FileTooLarge,
                    filePath,
                    $"Spectroscopy file is too large ({byteCount} bytes; maximum {MaximumFileByteCount} bytes): {Path.GetFileName(filePath)}");
            }

            int totalBytes = (int)byteCount;
            int prefixLimit = Math.Min(totalBytes, HeaderSniffByteCount);
            byte[] prefix = ReadUpTo(stream, prefixLimit, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

            int markerIdx = prefix.AsSpan().IndexOf(DataMarkerBytes);
            ReadOnlySpan<byte> nulSearchSlice = markerIdx >= 0
                ? prefix.AsSpan(0, markerIdx)
                : prefix.AsSpan();
            if (nulSearchSlice.IndexOf((byte)0x00) >= 0)
            {
                throw new SpectroscopyParserException(
                    SpectroscopyParserErrorKind.MissingData,
                    filePath,
                    $"No [DATA] section found: {Path.GetFileName(filePath)}");
            }
            if (byteCount > HeaderSniffByteCount && markerIdx < 0)
            {
                throw new SpectroscopyParserException(
                    SpectroscopyParserErrorKind.MissingData,
                    filePath,
                    $"No [DATA] section found: {Path.GetFileName(filePath)}");
            }

            if (prefix.Length >= totalBytes)
            {
                data = prefix;
            }
            else
            {
                data = new byte[totalBytes];
                Buffer.BlockCopy(prefix, 0, data, 0, prefix.Length);
                int offset = prefix.Length;
                const int chunkSize = 1_048_576;
                while (offset < totalBytes)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    int toRead = Math.Min(chunkSize, totalBytes - offset);
                    int n = stream.Read(data, offset, toRead);
                    if (n <= 0)
                    {
                        Array.Resize(ref data, offset);
                        break;
                    }
                    offset += n;
                }
            }
        }

        string text = DecodeUtf8OrLatin1(data);
        cancellationToken.ThrowIfCancellationRequested();

        int dataIndex = text.IndexOf("[DATA]", StringComparison.Ordinal);
        if (dataIndex < 0)
        {
            throw new SpectroscopyParserException(
                SpectroscopyParserErrorKind.MissingData,
                filePath,
                $"No [DATA] section found: {Path.GetFileName(filePath)}");
        }

        string headerText = text[..dataIndex];
        string dataText = text[(dataIndex + "[DATA]".Length)..];
        var header = ParseSpectroscopyHeader(headerText);

        var dataLines = TextSplitHelpers.SplitNonEmptyLines(dataText)
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToList();
        if (dataLines.Count == 0)
        {
            throw new SpectroscopyParserException(
                SpectroscopyParserErrorKind.MissingColumns,
                filePath,
                $"No plottable columns found: {Path.GetFileName(filePath)}");
        }

        string[] columns = MakeUniqueColumnNames(
            TrimTrailingEmptyColumns(SplitSpectroscopyLine(dataLines[0])));
        if (columns.Length < 2)
        {
            throw new SpectroscopyParserException(
                SpectroscopyParserErrorKind.MissingColumns,
                filePath,
                $"No plottable columns found: {Path.GetFileName(filePath)}");
        }

        string filename = Path.GetFileName(filePath);
        SpectroscopyKind kind = ClassifySpectroscopyKind(header.GetValueOrDefault("Experiment"), filename);
        const int xIndex = 0;
        int yIndex = PreferredYColumn(kind, columns);
        if (yIndex >= columns.Length)
        {
            throw new SpectroscopyParserException(
                SpectroscopyParserErrorKind.MissingColumns,
                filePath,
                $"No plottable columns found: {filename}");
        }

        var columnBuilders = new List<double>[columns.Length];
        for (int i = 0; i < columns.Length; i++)
        {
            columnBuilders[i] = [];
        }

        int badLineCount = 0;
        double[] rowParsed = new double[columns.Length];
        for (int i = 1; i < dataLines.Count; i++)
        {
            if ((i - 1) % 256 == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }
            string[] values = SplitSpectroscopyLine(dataLines[i]);
            if (values.Length != columns.Length)
            {
                badLineCount++;
                continue;
            }

            bool isCompleteRow = true;
            for (int c = 0; c < columns.Length; c++)
            {
                double? parsed = ParseEngineeringDouble(values[c]);
                if (parsed is null || !double.IsFinite(parsed.Value))
                {
                    isCompleteRow = false;
                    break;
                }
                rowParsed[c] = parsed.Value;
            }

            if (!isCompleteRow)
            {
                badLineCount++;
                continue;
            }

            for (int c = 0; c < columns.Length; c++)
            {
                columnBuilders[c].Add(rowParsed[c]);
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        var valuesByColumn = new Dictionary<string, double[]>(columns.Length, StringComparer.Ordinal);
        for (int c = 0; c < columns.Length; c++)
        {
            valuesByColumn[columns[c]] = columnBuilders[c].ToArray();
        }

        double[] xs = valuesByColumn[columns[xIndex]];
        double[] ys = valuesByColumn[columns[yIndex]];
        if (xs.Length < 2 || ys.Length != xs.Length)
        {
            int validCount = Math.Min(xs.Length, ys.Length);
            throw new SpectroscopyParserException(
                SpectroscopyParserErrorKind.InsufficientValidRows,
                filePath,
                $"Only {validCount} complete data row{(validCount == 1 ? "" : "s")} found; at least 2 are required and {badLineCount} malformed row{(badLineCount == 1 ? "" : "s")} were ignored: {filename}",
                badLineCount);
        }

        DateTimeOffset modifiedTime = SafeModifiedTime(filePath);
        string xLabel = columns[xIndex];
        string yLabel = columns[yIndex];
        var curve = new SpectroscopyCurve(
            id: null,
            filename: filename,
            modifiedTime: modifiedTime,
            columns: columns,
            valuesByColumn: valuesByColumn,
            x: xs,
            y: ys);

        string experiment = header.GetValueOrDefault("Experiment") ?? kind.Label();
        var file = new SpectroscopyFile(
            id: null,
            path: filePath,
            filename: filename,
            kind: kind,
            experiment: experiment,
            experimentIdentity: SpectroscopyExperimentIdentity.Make(header.GetValueOrDefault("Experiment"), kind),
            modifiedTime: modifiedTime,
            savedTime: ParseSpectroscopyDate(header.GetValueOrDefault("Saved Date")),
            position: ParsePosition(header),
            xLabel: xLabel,
            yLabel: yLabel,
            colorIndex: StableSpectrumColorIndex(filename),
            curve: curve);

        return (file, badLineCount);
    }

    public static double? ParseEngineeringDouble(string raw)
    {
        string trimmed = raw.Trim();
        if (trimmed.Length == 0 || trimmed.Equals("N/A", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        string normalized = trimmed.Replace("E", "e", StringComparison.Ordinal);
        if (TryParseStrictFloat(normalized, out double direct))
        {
            return double.IsFinite(direct) ? direct : null;
        }

        foreach ((string suffix, double multiplier) in SiMultipliers)
        {
            if (normalized.EndsWith(suffix, StringComparison.Ordinal))
            {
                string numberPart = normalized[..^suffix.Length].Trim();
                if (TryParseStrictFloat(numberPart, out double value))
                {
                    double scaled = value * multiplier;
                    return double.IsFinite(scaled) ? scaled : null;
                }
            }
        }

        return null;
    }

    private static bool TryParseStrictFloat(string s, out double value)
    {
        const NumberStyles styles = NumberStyles.AllowLeadingSign
            | NumberStyles.AllowDecimalPoint
            | NumberStyles.AllowExponent;
        return double.TryParse(s, styles, CultureInfo.InvariantCulture, out value);
    }

    private static string DecodeUtf8OrLatin1(byte[] data)
    {
        var strictUtf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
        try
        {
            return strictUtf8.GetString(data);
        }
        catch (DecoderFallbackException)
        {
            return Encoding.Latin1.GetString(data);
        }
    }

    private static byte[] ReadUpTo(FileStream stream, int count, CancellationToken cancellationToken)
    {
        if (count <= 0) return [];
        byte[] buffer = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            cancellationToken.ThrowIfCancellationRequested();
            int n = stream.Read(buffer, offset, count - offset);
            if (n <= 0)
            {
                Array.Resize(ref buffer, offset);
                break;
            }
            offset += n;
        }
        return buffer;
    }

    private static Dictionary<string, string> ParseSpectroscopyHeader(string text)
    {
        var header = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string rawLine in TextSplitHelpers.SplitNonEmptyLines(text))
        {
            string[] parts = SplitSpectroscopyLine(rawLine);
            if (parts.Length < 2) continue;
            header[parts[0]] = parts[1];
        }
        return header;
    }

    private static string[] SplitSpectroscopyLine(string line)
    {
        if (line.Contains('\t'))
        {
            string[] parts = line.Split('\t', StringSplitOptions.None);
            for (int i = 0; i < parts.Length; i++)
            {
                parts[i] = parts[i].Trim();
            }
            return parts;
        }
        return TextSplitHelpers.SplitWhitespace(line);
    }

    private static string[] TrimTrailingEmptyColumns(string[] columns)
    {
        int len = columns.Length;
        while (len > 0 && columns[len - 1].Length == 0)
        {
            len--;
        }
        return len == columns.Length ? columns : columns[..len];
    }

    private static string[] MakeUniqueColumnNames(string[] columns)
    {
        // Reserve literal labels, including numbered labels appearing later in the header.
        var reserved = new HashSet<string>(columns, StringComparer.Ordinal);
        var nextSuffix = new Dictionary<string, int>(StringComparer.Ordinal);
        var result = new string[columns.Length];
        for (int i = 0; i < columns.Length; i++)
        {
            string name = columns[i].Length == 0 ? "Column" : columns[i];
            if (!nextSuffix.TryGetValue(name, out int suffix))
            {
                nextSuffix[name] = 2;
                result[i] = name;
                continue;
            }

            string candidate;
            do
            {
                candidate = $"{name} ({suffix++})";
            } while (reserved.Contains(candidate));
            nextSuffix[name] = suffix;
            result[i] = candidate;
        }
        return result;
    }

    private static SpectroscopyKind ClassifySpectroscopyKind(string? experiment, string filename)
    {
        string folded = $"{experiment ?? string.Empty} {filename}".ToLowerInvariant();
        if (folded.Contains("bias", StringComparison.Ordinal)) return SpectroscopyKind.Bias;
        if (folded.Contains("z spectroscopy", StringComparison.Ordinal)
            || folded.StartsWith("z-", StringComparison.Ordinal)
            || folded.Contains("/z-", StringComparison.Ordinal))
        {
            return SpectroscopyKind.Z;
        }
        return SpectroscopyKind.Other;
    }

    private static int PreferredYColumn(SpectroscopyKind kind, string[] columns)
    {
        string[] preferred = kind switch
        {
            SpectroscopyKind.Z => ["OC M1 Freq. Shift (Hz)", "Frequency Shift", "Current (A)"],
            SpectroscopyKind.Bias => ["Current (A)", "OC M1 Freq. Shift (Hz)"],
            _ => ["Current (A)", "OC M1 Freq. Shift (Hz)"]
        };

        foreach (string name in preferred)
        {
            for (int i = 0; i < columns.Length; i++)
            {
                if (string.Equals(columns[i], name, StringComparison.OrdinalIgnoreCase))
                {
                    return i;
                }
            }
        }

        for (int i = 0; i < columns.Length; i++)
        {
            if (!columns[i].Contains("[bwd]", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(columns[i], columns[0], StringComparison.Ordinal))
            {
                return i;
            }
        }

        return Math.Min(1, columns.Length - 1);
    }

    private static (double X, double Y)? ParsePosition(Dictionary<string, string> header)
    {
        double? x = ParseEngineeringDouble(header.GetValueOrDefault("X (m)", string.Empty));
        double? y = ParseEngineeringDouble(header.GetValueOrDefault("Y (m)", string.Empty));
        if (x is null || y is null) return null;
        return (x.Value, y.Value);
    }

    private static DateTimeOffset? ParseSpectroscopyDate(string? value)
    {
        if (value is null) return null;
        string trimmed = value.Trim();
        return trimmed.Length == 0 ? null : SpectroscopyDateParser.Parse(trimmed);
    }

    private static int StableSpectrumColorIndex(string filename)
    {
        string baseName = Path.GetFileNameWithoutExtension(filename);
        var digitChars = new List<char>();
        bool hasStartedDigits = false;
        for (int i = baseName.Length - 1; i >= 0; i--)
        {
            char c = baseName[i];
            if (char.IsNumber(c))
            {
                digitChars.Add(c);
                hasStartedDigits = true;
            }
            else if (hasStartedDigits)
            {
                break;
            }
        }
        if (digitChars.Count > 0)
        {
            digitChars.Reverse();
            string digits = new(digitChars.ToArray());
            if (int.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out int val) && val > 0)
            {
                return val - 1;
            }
        }

        uint hash = 2166136261u;
        foreach (byte b in Encoding.UTF8.GetBytes(baseName))
        {
            hash ^= b;
            unchecked { hash *= 16777619u; }
        }
        return (int)(hash % 8u);
    }

    private static DateTimeOffset SafeModifiedTime(string filePath)
    {
        try
        {
            var info = new FileInfo(filePath);
            return info.Exists ? new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero) : DateTimeOffset.MinValue;
        }
        catch
        {
            return DateTimeOffset.MinValue;
        }
    }
}
