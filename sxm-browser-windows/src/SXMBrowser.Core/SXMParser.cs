using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace SXMBrowser.Core;

public enum SXMParserErrorKind
{
    MarkerNotFound,
    MissingPixels,
    InvalidPixels,
    PixelDimensionsOutOfRange,
    PixelCountOverflow,
    PixelCountExceedsLimit,
    MissingChannels,
    DuplicateChannel,
    MissingScanType,
    UnsupportedScanType,
    DataSizeOverflow,
    MatrixNotFound,
    CannotOpen,
    ShortData
}

public sealed class SXMParserException : Exception
{
    public SXMParserErrorKind Kind { get; }
    public string FilePath { get; }

    public SXMParserException(SXMParserErrorKind kind, string filePath, string message)
        : base(message)
    {
        Kind = kind;
        FilePath = filePath;
    }

    public SXMParserException(SXMParserErrorKind kind, string filePath, string message, Exception innerException)
        : base(message, innerException)
    {
        Kind = kind;
        FilePath = filePath;
    }
}

internal readonly record struct ChannelSpec(
    string Name,
    string Unit,
    IReadOnlyList<ScanDirection> Directions);

public sealed class SXMParser
{
    public const int MaximumPixelDimension = 16_384;
    public const int MaximumPixelCount = 64 * 1024 * 1024;
    private const int BytesPerSample = 4;
    private const int MaxHeaderSearchBytes = 16 * 1024 * 1024;
    private static readonly byte[] DataMarker = [0x1A, 0x04];

    private static readonly PosixDateParser SxmRecordedTimeParser = new(
        "dd.MM.yyyy HH:mm:ss",
        "dd.MM.yy HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "MM/dd/yyyy HH:mm:ss");

    private enum StorageEncoding
    {
        Float32MSBFirst
    }

    private readonly record struct MatrixLayout(
        int Width,
        int Height,
        int ItemCount,
        int ByteCount,
        int MatrixCount,
        int ExpectedPayloadBytes);

    public ScanReport<SXMMetadata> ScanFolder(
        string folderPath,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var dir = new DirectoryInfo(folderPath);
        if (!dir.Exists)
        {
            throw new DirectoryNotFoundException($"Directory not found: {folderPath}");
        }

        // Preserve directory enumeration exceptions (never swallow root scan failures as issues).
        var sxmPaths = dir.EnumerateFileSystemInfos()
            .Where(info => !IsHiddenEntry(info)
                && string.Equals(info.Extension, ".sxm", StringComparison.OrdinalIgnoreCase))
            .Select(info => info.FullName)
            .OrderBy(p => p, Comparer<string>.Create(NaturalStringComparer.CompareFilenamesAndPaths))
            .ToList();

        var items = new List<SXMMetadata>(sxmPaths.Count);
        var issues = new List<ScanIssue>();

        foreach (string path in sxmPaths)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                items.Add(LoadMetadata(path, cancellationToken));
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                issues.Add(new ScanIssue(path, ScanStage.SxmMetadata, ex.Message));
            }
        }

        return new ScanReport<SXMMetadata>(items, issues);
    }

    public SXMMetadata LoadMetadata(string filePath, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var headerRead = ReadHeader(filePath, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        var specs = ParseDataInfo(
            headerRead.Header.GetValueOrDefault("DATA_INFO", string.Empty),
            CancellationCheckpoint.FromToken(cancellationToken));
        return BuildMetadata(filePath, headerRead.Header, specs, id: null, cancellationToken);
    }

    public SXMFullFile LoadFullFile(SXMMetadata metadata, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var headerRead = ReadHeader(metadata.Path, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        var specs = ParseDataInfo(
            headerRead.Header.GetValueOrDefault("DATA_INFO", string.Empty),
            CancellationCheckpoint.FromToken(cancellationToken));
        SXMMetadata current = BuildMetadata(
            metadata.Path,
            headerRead.Header,
            specs,
            metadata.Id,
            cancellationToken);
        StorageEncoding encoding = ParseStorageEncoding(
            headerRead.Header.GetValueOrDefault("SCANIT_TYPE"),
            metadata.Path);
        cancellationToken.ThrowIfCancellationRequested();

        Dictionary<MatrixKey, Matrix> matrices = ReadMatrices(
            metadata.Path,
            headerRead.BodyOffset,
            current.Pixels.Width,
            current.Pixels.Height,
            specs,
            current.ScanDir,
            encoding,
            cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();

        IReadOnlyList<SXMChannel> channels = ChannelsFromSpecs(specs, matrices);
        var refreshed = new SXMMetadata(
            id: metadata.Id,
            path: metadata.Path,
            filename: metadata.Filename,
            header: current.Header,
            recordedTime: current.RecordedTime,
            modifiedTime: current.ModifiedTime,
            pixels: current.Pixels,
            scanRange: current.ScanRange,
            scanOffset: current.ScanOffset,
            scanAngle: current.ScanAngle,
            scanDir: current.ScanDir,
            zControllerOn: current.ZControllerOn,
            channels: channels,
            defaultChannel: ChooseDefaultChannel(channels, current.ZControllerOn));

        return new SXMFullFile(refreshed, matrices);
    }

    public Matrix LoadMatrix(
        SXMMetadata metadata,
        MatrixKey key,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var headerRead = ReadHeader(metadata.Path, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        var specs = ParseDataInfo(
            headerRead.Header.GetValueOrDefault("DATA_INFO", string.Empty),
            CancellationCheckpoint.FromToken(cancellationToken));
        SXMMetadata current = BuildMetadata(
            metadata.Path,
            headerRead.Header,
            specs,
            metadata.Id,
            cancellationToken);
        StorageEncoding encoding = ParseStorageEncoding(
            headerRead.Header.GetValueOrDefault("SCANIT_TYPE"),
            metadata.Path);
        MatrixLayout layout = ComputeMatrixLayout(
            metadata.Path,
            current.Pixels.Width,
            current.Pixels.Height,
            specs,
            cancellationToken);

        int idx = FindMatrixIndex(key, specs);
        if (idx < 0)
        {
            throw new SXMParserException(
                SXMParserErrorKind.MatrixNotFound,
                metadata.Path,
                $"Matrix {key.Channel} {key.Direction.Label()} is not available: {Path.GetFileName(metadata.Path)}");
        }

        cancellationToken.ThrowIfCancellationRequested();
        return ReadMatrix(
            metadata.Path,
            headerRead.BodyOffset,
            layout,
            idx,
            key.Direction,
            current.ScanDir,
            encoding,
            cancellationToken);
    }

    public static Dictionary<string, string> ParseHeader(string headerText)
        => ParseHeader(headerText, CancellationCheckpoint.None);

    internal static Dictionary<string, string> ParseHeader(
        string headerText,
        CancellationCheckpoint cancellation)
    {
        cancellation.Check();
        var header = new Dictionary<string, string>(StringComparer.Ordinal);
        string? currentKey = null;
        var currentLines = new List<string>();
        int lineIndex = 0;

        foreach (string rawLine in TextSplitHelpers.SplitNonEmptyLines(headerText))
        {
            if (lineIndex % 128 == 0)
            {
                cancellation.Check();
            }
            lineIndex++;

            string line = rawLine.Trim('\r');
            if (line.Length > 2 && line.StartsWith(':') && line.EndsWith(':'))
            {
                if (currentKey is not null)
                {
                    header[currentKey] = string.Join('\n', currentLines).Trim('\n');
                }
                string key = line[1..^1];
                if (key == "SCANIT_END")
                {
                    currentKey = null;
                    currentLines.Clear();
                    break;
                }
                currentKey = key;
                currentLines.Clear();
            }
            else if (currentKey is not null)
            {
                currentLines.Add(line);
            }
        }

        if (currentKey is not null)
        {
            header[currentKey] = string.Join('\n', currentLines).Trim('\n');
        }
        cancellation.Check();
        return header;
    }

    internal static List<ChannelSpec> ParseDataInfo(
        string value,
        CancellationCheckpoint cancellation)
    {
        cancellation.Check();
        var lines = TextSplitHelpers.SplitNonEmptyLines(value)
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToList();
        if (lines.Count < 2)
        {
            return [];
        }

        var headerCols = SplitDataLine(lines[0]).Select(s => s.ToLowerInvariant()).ToList();
        var specs = new List<ChannelSpec>();

        for (int lineIndex = 1; lineIndex < lines.Count; lineIndex++)
        {
            if ((lineIndex - 1) % 128 == 0)
            {
                cancellation.Check();
            }
            var parts = SplitDataLine(lines[lineIndex]);
            if (parts.Count < 2) continue;

            var row = new Dictionary<string, string>(StringComparer.Ordinal);
            for (int idx = 0; idx < headerCols.Count && idx < parts.Count; idx++)
            {
                row[headerCols[idx]] = parts[idx];
            }

            string name = row.GetValueOrDefault("name")
                ?? (parts.Count > 1 ? parts[1] : parts[0]);
            string unit = row.GetValueOrDefault("unit")
                ?? (parts.Count > 2 ? parts[2] : string.Empty);
            string directionValue = (row.GetValueOrDefault("direction")
                ?? (parts.Count > 3 ? parts[3] : "both")).ToLowerInvariant();
            specs.Add(new ChannelSpec(name, unit, ParseDirections(directionValue)));
        }

        cancellation.Check();
        return specs;
    }

    internal static string? ChooseDefaultChannel(
        IReadOnlyList<SXMChannel> channels,
        bool? zControllerOn)
    {
        if (channels.Count == 0) return null;
        string? freq = FindChannel(channels, ["frequency shift", "freq", "df", "delta f", "Δf"]);
        if (zControllerOn == false && freq is not null)
        {
            return freq;
        }
        string? height = FindChannel(channels, ["z", "height", "topography"]);
        if (height is not null)
        {
            return height;
        }
        if (freq is not null)
        {
            return freq;
        }
        return channels[0].Name;
    }

    private SXMMetadata BuildMetadata(
        string filePath,
        Dictionary<string, string> header,
        List<ChannelSpec> specs,
        Guid? id,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        (int width, int height) pixels = ParsePixels(header.GetValueOrDefault("SCAN_PIXELS"), filePath);
        if (specs.Count == 0)
        {
            throw new SXMParserException(
                SXMParserErrorKind.MissingChannels,
                filePath,
                $"DATA_INFO has no channels: {Path.GetFileName(filePath)}");
        }

        var channelNames = new HashSet<string>(StringComparer.Ordinal);
        foreach (ChannelSpec spec in specs)
        {
            if (!channelNames.Add(spec.Name))
            {
                throw new SXMParserException(
                    SXMParserErrorKind.DuplicateChannel,
                    filePath,
                    $"DATA_INFO contains duplicate channel \"{spec.Name}\": {Path.GetFileName(filePath)}");
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        _ = ParseStorageEncoding(header.GetValueOrDefault("SCANIT_TYPE"), filePath);

        DateTimeOffset modifiedTime = SafeModifiedTime(filePath);
        bool? zControllerOn = ParseZControllerOn(header.GetValueOrDefault("Z-CONTROLLER", string.Empty));
        IReadOnlyList<SXMChannel> channels = ChannelsFromSpecs(specs, matrices: null);

        return new SXMMetadata(
            id: id,
            path: filePath,
            filename: Path.GetFileName(filePath),
            header: header,
            recordedTime: ParseRecordedTime(header),
            modifiedTime: modifiedTime,
            pixels: pixels,
            scanRange: ParseFloatPair(header.GetValueOrDefault("SCAN_RANGE")),
            scanOffset: ParseFloatPair(header.GetValueOrDefault("SCAN_OFFSET")),
            scanAngle: ParseSingleFloat(header.GetValueOrDefault("SCAN_ANGLE")),
            scanDir: CleanSingleLine(header.GetValueOrDefault("SCAN_DIR")),
            zControllerOn: zControllerOn,
            channels: channels,
            defaultChannel: ChooseDefaultChannel(channels, zControllerOn));
    }

    private (string Text, Dictionary<string, string> Header, ulong BodyOffset) ReadHeader(
        string filePath,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        FileStream stream = OpenReadStream(filePath);
        using (stream)
        {
            byte[] chunkBuffer = new byte[64 * 1024];
            var buffer = new List<byte>(64 * 1024);
            long totalOffset = 0;

            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                int read = stream.Read(chunkBuffer, 0, chunkBuffer.Length);
                if (read <= 0) break;

                int searchFrom = Math.Max(0, buffer.Count - (DataMarker.Length - 1));
                for (int i = 0; i < read; i++)
                {
                    buffer.Add(chunkBuffer[i]);
                }

                int markerIdx = FindMarker(buffer, searchFrom);
                if (markerIdx >= 0)
                {
                    string text = DecodeHeaderBytes(buffer, markerIdx);
                    cancellationToken.ThrowIfCancellationRequested();
                    Dictionary<string, string> header = ParseHeader(
                        text,
                        CancellationCheckpoint.FromToken(cancellationToken));
                    return (text, header, (ulong)(markerIdx + DataMarker.Length));
                }

                totalOffset += read;
                if (totalOffset > MaxHeaderSearchBytes)
                {
                    break;
                }
            }
        }

        throw new SXMParserException(
            SXMParserErrorKind.MarkerNotFound,
            filePath,
            $"SXM data marker not found: {Path.GetFileName(filePath)}");
    }

    private static string DecodeHeaderBytes(List<byte> buffer, int length)
    {
        byte[] bytes = new byte[length];
        buffer.CopyTo(0, bytes, 0, length);
        return Encoding.Latin1.GetString(bytes);
    }

    private static int FindMarker(List<byte> buffer, int startIndex)
    {
        int limit = buffer.Count - 1;
        for (int i = startIndex; i < limit; i++)
        {
            if (buffer[i] == DataMarker[0] && buffer[i + 1] == DataMarker[1])
            {
                return i;
            }
        }
        return -1;
    }

    private Dictionary<MatrixKey, Matrix> ReadMatrices(
        string filePath,
        ulong offset,
        int width,
        int height,
        List<ChannelSpec> specs,
        string? scanDir,
        StorageEncoding encoding,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using FileStream stream = OpenReadStream(filePath);
        MatrixLayout layout = ComputeMatrixLayout(filePath, width, height, specs, cancellationToken);
        ValidateFileLength(stream, filePath, offset, layout, cancellationToken);
        stream.Seek((long)offset, SeekOrigin.Begin);

        var matrices = new Dictionary<MatrixKey, Matrix>();
        long consumedPayloadBytes = 0;

        foreach (ChannelSpec spec in specs)
        {
            foreach (ScanDirection direction in spec.Directions)
            {
                cancellationToken.ThrowIfCancellationRequested();
                byte[] chunk = ReadExactly(stream, layout.ByteCount, out int bytesRead, cancellationToken);
                if (bytesRead < layout.ByteCount)
                {
                    throw new SXMParserException(
                        SXMParserErrorKind.ShortData,
                        filePath,
                        $"File has {consumedPayloadBytes + bytesRead} matrix bytes; expected {layout.ExpectedPayloadBytes}: {Path.GetFileName(filePath)}");
                }
                consumedPayloadBytes += bytesRead;
                float[] values = DecodeValues(
                    chunk,
                    layout.ItemCount,
                    layout.Width,
                    layout.Height,
                    direction,
                    scanDir,
                    encoding,
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                matrices[new MatrixKey(spec.Name, direction)] = new Matrix(width, height, values);
            }
        }

        return matrices;
    }

    private Matrix ReadMatrix(
        string filePath,
        ulong payloadOffset,
        MatrixLayout layout,
        int matrixIndex,
        ScanDirection direction,
        string? scanDir,
        StorageEncoding encoding,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using FileStream stream = OpenReadStream(filePath);
        ValidateFileLength(stream, filePath, payloadOffset, layout, cancellationToken);

        ulong relativeOffset;
        ulong matrixOffset;
        try
        {
            relativeOffset = checked((ulong)layout.ByteCount * (ulong)matrixIndex);
            matrixOffset = checked(payloadOffset + relativeOffset);
        }
        catch (OverflowException)
        {
            throw new SXMParserException(
                SXMParserErrorKind.DataSizeOverflow,
                filePath,
                $"Matrix byte size overflows for {layout.ItemCount} pixels \u00D7 {layout.MatrixCount} matrices: {Path.GetFileName(filePath)}");
        }

        if (matrixOffset > long.MaxValue)
        {
            throw new SXMParserException(
                SXMParserErrorKind.DataSizeOverflow,
                filePath,
                $"Matrix byte size overflows for {layout.ItemCount} pixels \u00D7 {layout.MatrixCount} matrices: {Path.GetFileName(filePath)}");
        }

        stream.Seek((long)matrixOffset, SeekOrigin.Begin);
        byte[] chunk = ReadExactly(stream, layout.ByteCount, out int bytesRead, cancellationToken);
        if (bytesRead != layout.ByteCount)
        {
            throw new SXMParserException(
                SXMParserErrorKind.ShortData,
                filePath,
                $"File has {relativeOffset + (ulong)bytesRead} matrix bytes; expected {layout.ExpectedPayloadBytes}: {Path.GetFileName(filePath)}");
        }

        float[] values = DecodeValues(
            chunk,
            layout.ItemCount,
            layout.Width,
            layout.Height,
            direction,
            scanDir,
            encoding,
            cancellationToken);
        return new Matrix(layout.Width, layout.Height, values);
    }

    private static FileStream OpenReadStream(string filePath)
    {
        try
        {
            return new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new SXMParserException(
                SXMParserErrorKind.CannotOpen,
                filePath,
                $"Cannot open file: {filePath}",
                ex);
        }
    }

    private static MatrixLayout ComputeMatrixLayout(
        string filePath,
        int width,
        int height,
        List<ChannelSpec> specs,
        CancellationToken cancellationToken)
    {
        int itemCount;
        try
        {
            itemCount = checked(width * height);
        }
        catch (OverflowException)
        {
            throw new SXMParserException(
                SXMParserErrorKind.PixelCountOverflow,
                filePath,
                $"SCAN_PIXELS {width}\u00D7{height} overflows the supported size: {Path.GetFileName(filePath)}");
        }

        int byteCount;
        try
        {
            byteCount = checked(itemCount * BytesPerSample);
        }
        catch (OverflowException)
        {
            throw new SXMParserException(
                SXMParserErrorKind.DataSizeOverflow,
                filePath,
                $"Matrix byte size overflows for {itemCount} pixels \u00D7 1 matrices: {Path.GetFileName(filePath)}");
        }

        int matrixCount = 0;
        foreach (ChannelSpec spec in specs)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                matrixCount = checked(matrixCount + spec.Directions.Count);
            }
            catch (OverflowException)
            {
                throw new SXMParserException(
                    SXMParserErrorKind.DataSizeOverflow,
                    filePath,
                    $"Matrix byte size overflows for {itemCount} pixels \u00D7 {matrixCount} matrices: {Path.GetFileName(filePath)}");
            }
        }

        int expectedPayloadBytes;
        try
        {
            expectedPayloadBytes = checked(byteCount * matrixCount);
        }
        catch (OverflowException)
        {
            throw new SXMParserException(
                SXMParserErrorKind.DataSizeOverflow,
                filePath,
                $"Matrix byte size overflows for {itemCount} pixels \u00D7 {matrixCount} matrices: {Path.GetFileName(filePath)}");
        }

        return new MatrixLayout(width, height, itemCount, byteCount, matrixCount, expectedPayloadBytes);
    }

    private static int FindMatrixIndex(MatrixKey key, List<ChannelSpec> specs)
    {
        int index = 0;
        foreach (ChannelSpec spec in specs)
        {
            foreach (ScanDirection direction in spec.Directions)
            {
                if (string.Equals(spec.Name, key.Channel, StringComparison.Ordinal)
                    && direction == key.Direction)
                {
                    return index;
                }
                index++;
            }
        }
        return -1;
    }

    private static void ValidateFileLength(
        FileStream stream,
        string filePath,
        ulong payloadOffset,
        MatrixLayout layout,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ulong fileLength = (ulong)stream.Length;
        ulong availablePayloadBytes = fileLength >= payloadOffset ? fileLength - payloadOffset : 0UL;
        ulong expectedPayloadBytes = (ulong)layout.ExpectedPayloadBytes;
        if (availablePayloadBytes < expectedPayloadBytes)
        {
            throw new SXMParserException(
                SXMParserErrorKind.ShortData,
                filePath,
                $"File has {availablePayloadBytes} matrix bytes; expected {expectedPayloadBytes}: {Path.GetFileName(filePath)}");
        }
    }

    private static byte[] ReadExactly(
        FileStream stream,
        int count,
        out int totalRead,
        CancellationToken cancellationToken)
    {
        byte[] buffer = new byte[count];
        totalRead = 0;
        while (totalRead < count)
        {
            cancellationToken.ThrowIfCancellationRequested();
            int n = stream.Read(buffer, totalRead, count - totalRead);
            if (n <= 0) break;
            totalRead += n;
        }
        return buffer;
    }

    private static float[] DecodeValues(
        byte[] chunk,
        int itemCount,
        int width,
        int height,
        ScanDirection direction,
        string? scanDir,
        StorageEncoding encoding,
        CancellationToken cancellationToken)
    {
        float[] values = new float[itemCount];
        ReadOnlySpan<byte> span = chunk;

        for (int idx = 0; idx < itemCount; idx++)
        {
            if (idx % 4_096 == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }
            int byteIndex = idx * BytesPerSample;
            switch (encoding)
            {
                case StorageEncoding.Float32MSBFirst:
                    values[idx] = BinaryPrimitives.ReadSingleBigEndian(span.Slice(byteIndex, 4));
                    break;
            }
        }

        if (direction == ScanDirection.Bwd)
        {
            values = FlipHorizontally(values, width, height, cancellationToken);
        }
        if (SXMChannelRules.IsUpwardScanDirection(scanDir))
        {
            values = FlipVertically(values, width, height, cancellationToken);
        }
        cancellationToken.ThrowIfCancellationRequested();
        return values;
    }

    private static float[] FlipHorizontally(
        float[] values,
        int width,
        int height,
        CancellationToken cancellationToken)
    {
        float[] output = new float[values.Length];
        for (int y = 0; y < height; y++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            int rowStart = y * width;
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                }
                output[rowStart + x] = values[rowStart + (width - 1 - x)];
            }
        }
        return output;
    }

    private static float[] FlipVertically(
        float[] values,
        int width,
        int height,
        CancellationToken cancellationToken)
    {
        if (height <= 1 || width <= 0)
        {
            return values;
        }
        float[] output = new float[values.Length];
        for (int y = 0; y < height; y++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            int srcStart = (height - 1 - y) * width;
            int dstStart = y * width;
            Array.Copy(values, srcStart, output, dstStart, width);
        }
        return output;
    }

    private static IReadOnlyList<SXMChannel> ChannelsFromSpecs(
        List<ChannelSpec> specs,
        Dictionary<MatrixKey, Matrix>? matrices)
    {
        var list = new List<SXMChannel>(specs.Count);
        foreach (ChannelSpec spec in specs)
        {
            IReadOnlyList<ScanDirection> dirs = matrices is not null
                ? SXMValueExtensions.AllDirections
                    .Where(d => matrices.ContainsKey(new MatrixKey(spec.Name, d)))
                    .ToArray()
                : spec.Directions;
            list.Add(new SXMChannel(
                spec.Name,
                spec.Unit,
                dirs,
                SXMChannelRules.ClassifyChannel(spec.Name)));
        }
        return list;
    }

    private static List<string> SplitDataLine(string line)
    {
        if (line.Contains('\t'))
        {
            return line.Split('\t')
                .Select(s => s.Trim())
                .Where(s => s.Length > 0)
                .ToList();
        }
        return TextSplitHelpers.SplitWhitespace(line).ToList();
    }

    private static IReadOnlyList<ScanDirection> ParseDirections(string value)
    {
        if (value is "both" or "fwd+bwd" or "forward+backward")
        {
            return [ScanDirection.Fwd, ScanDirection.Bwd];
        }
        if (value is "backward" or "bwd")
        {
            return [ScanDirection.Bwd];
        }
        return [ScanDirection.Fwd];
    }

    private static (int Width, int Height) ParsePixels(string? value, string filePath)
    {
        if (value is null)
        {
            throw new SXMParserException(
                SXMParserErrorKind.MissingPixels,
                filePath,
                $"SCAN_PIXELS not found: {Path.GetFileName(filePath)}");
        }

        string[] parts = TextSplitHelpers.SplitWhitespace(value);
        if (parts.Length != 2
            || !long.TryParse(parts[0], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long width64)
            || !long.TryParse(parts[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long height64))
        {
            throw new SXMParserException(
                SXMParserErrorKind.InvalidPixels,
                filePath,
                $"Invalid SCAN_PIXELS \"{value}\": {Path.GetFileName(filePath)}");
        }

        long pixelCount64;
        try
        {
            pixelCount64 = checked(width64 * height64);
        }
        catch (OverflowException)
        {
            throw new SXMParserException(
                SXMParserErrorKind.PixelCountOverflow,
                filePath,
                $"SCAN_PIXELS {width64}\u00D7{height64} overflows the supported size: {Path.GetFileName(filePath)}");
        }

        if (width64 < 1 || width64 > MaximumPixelDimension
            || height64 < 1 || height64 > MaximumPixelDimension)
        {
            throw new SXMParserException(
                SXMParserErrorKind.PixelDimensionsOutOfRange,
                filePath,
                $"SCAN_PIXELS {width64}\u00D7{height64} must be within 1...{MaximumPixelDimension}: {Path.GetFileName(filePath)}");
        }

        if (pixelCount64 > MaximumPixelCount)
        {
            throw new SXMParserException(
                SXMParserErrorKind.PixelCountExceedsLimit,
                filePath,
                $"SXM has {pixelCount64} pixels; maximum is {MaximumPixelCount}: {Path.GetFileName(filePath)}");
        }

        return ((int)width64, (int)height64);
    }

    private static StorageEncoding ParseStorageEncoding(string? value, string filePath)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new SXMParserException(
                SXMParserErrorKind.MissingScanType,
                filePath,
                $"SCANIT_TYPE not found: {Path.GetFileName(filePath)}");
        }

        string[] tokens = TextSplitHelpers.SplitWhitespace(value)
            .Select(t => t.ToUpperInvariant())
            .ToArray();
        if (tokens.Length != 2 || tokens[0] != "FLOAT" || tokens[1] != "MSBFIRST")
        {
            throw new SXMParserException(
                SXMParserErrorKind.UnsupportedScanType,
                filePath,
                $"Unsupported SCANIT_TYPE \"{value}\": {Path.GetFileName(filePath)}");
        }

        return StorageEncoding.Float32MSBFirst;
    }

    private static (double X, double Y)? ParseFloatPair(string? value)
    {
        if (string.IsNullOrEmpty(value)) return null;
        string[] parts = TextSplitHelpers.SplitWhitespace(value);
        if (parts.Length < 2) return null;
        if (!double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double x)
            || !double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double y))
        {
            return null;
        }
        return (x, y);
    }

    private static double? ParseSingleFloat(string? value)
    {
        if (string.IsNullOrEmpty(value)) return null;
        string[] parts = TextSplitHelpers.SplitWhitespace(value);
        if (parts.Length == 0) return null;
        return double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double d)
            ? d
            : null;
    }

    private static DateTimeOffset? ParseRecordedTime(Dictionary<string, string> header)
    {
        string? dateValue = CleanSingleLine(header.GetValueOrDefault("REC_DATE"));
        if (dateValue is null) return null;
        string timeValue = CleanSingleLine(header.GetValueOrDefault("REC_TIME")) ?? "00:00:00";
        return SxmRecordedTimeParser.Parse($"{dateValue} {timeValue}");
    }

    private static bool? ParseZControllerOn(string value)
    {
        var lines = TextSplitHelpers.SplitNonEmptyLines(value)
            .Select(l => l.Trim())
            .Where(l => l.Length > 0)
            .ToList();

        if (lines.Count >= 2)
        {
            var labels = SplitDataLine(lines[0]).Select(s => s.ToLowerInvariant()).ToList();
            var values = SplitDataLine(lines[1]).Select(s => s.ToLowerInvariant()).ToList();
            for (int idx = 0; idx < labels.Count && idx < values.Count; idx++)
            {
                if (labels[idx] is "on/off" or "on" or "active")
                {
                    string token = values[idx];
                    if (token is "1" or "on" or "true") return true;
                    if (token is "0" or "off" or "false") return false;
                }
            }
        }

        string folded = value.ToLowerInvariant();
        if (folded.Contains("off", StringComparison.Ordinal)) return false;
        if (folded.Contains("on", StringComparison.Ordinal)) return true;
        return null;
    }

    private static string? CleanSingleLine(string? value)
    {
        if (value is null) return null;
        string trimmed = value.Trim();
        if (trimmed.Length == 0) return null;
        foreach (string first in TextSplitHelpers.SplitNonEmptyLines(trimmed))
        {
            return first;
        }
        return null;
    }

    private static string? FindChannel(IReadOnlyList<SXMChannel> channels, string[] keywords)
    {
        foreach (SXMChannel channel in channels)
        {
            string folded = channel.Name.ToLowerInvariant();
            foreach (string kw in keywords)
            {
                if (folded.Contains(kw.ToLowerInvariant(), StringComparison.Ordinal)
                    || channel.Name.Contains(kw, StringComparison.Ordinal))
                {
                    return channel.Name;
                }
            }
        }
        return null;
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

    internal static bool IsHiddenEntry(FileSystemInfo info)
    {
        if (info.Name.StartsWith('.')) return true;
        try
        {
            return (info.Attributes & FileAttributes.Hidden) != 0;
        }
        catch
        {
            return false;
        }
    }
}
