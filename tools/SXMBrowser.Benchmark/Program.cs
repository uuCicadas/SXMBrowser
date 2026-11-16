using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using SXMBrowser.Core;

namespace SXMBrowser.Benchmark;

internal sealed class BenchmarkFailureException : Exception
{
    public int ExitCode { get; }

    public BenchmarkFailureException(int exitCode, string message) : base(message)
    {
        ExitCode = exitCode;
    }

    public static BenchmarkFailureException Usage(string msg) => new(64, msg);
    public static BenchmarkFailureException Unsupported(string msg) => new(69, msg);
    public static BenchmarkFailureException Gate(string msg) => new(1, msg);
}

internal sealed record BenchmarkConfiguration(
    int FileCount,
    int Width,
    int Height,
    int Trials,
    double MaximumScanMilliseconds,
    double MaximumImageMilliseconds,
    double MaximumThumbnailMilliseconds,
    int PixelCount,
    int PayloadByteCount,
    int GradientFileCount)
{
    private const string UsageText =
        "Usage: SXMBrowserBenchmark --files <count> --width <pixels> --height <pixels> --trials <count> --max-scan-ms <milliseconds> --max-image-ms <milliseconds> --max-thumbnail-ms <milliseconds>";

    private static readonly HashSet<string> ExpectedFlags = new(StringComparer.Ordinal)
    {
        "--files", "--width", "--height", "--trials",
        "--max-scan-ms", "--max-image-ms", "--max-thumbnail-ms"
    };

    public static BenchmarkConfiguration Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        int index = 0;
        while (index < args.Length)
        {
            string flag = args[index];
            if (!ExpectedFlags.Contains(flag))
            {
                throw BenchmarkFailureException.Usage($"Unknown benchmark argument: {flag}. {UsageText}");
            }
            if (values.ContainsKey(flag))
            {
                throw BenchmarkFailureException.Usage($"Duplicate benchmark argument: {flag}. {UsageText}");
            }
            if (index + 1 >= args.Length)
            {
                throw BenchmarkFailureException.Usage($"Missing value for {flag}. {UsageText}");
            }
            values[flag] = args[index + 1];
            index += 2;
        }

        string[] missing = ExpectedFlags.Where(f => !values.ContainsKey(f)).OrderBy(f => f, StringComparer.Ordinal).ToArray();
        if (missing.Length > 0)
        {
            throw BenchmarkFailureException.Usage($"Missing benchmark arguments: {string.Join(", ", missing)}. {UsageText}");
        }

        int fileCount = PositiveInt("--files", values);
        int width = PositiveInt("--width", values);
        int height = PositiveInt("--height", values);
        int trials = PositiveInt("--trials", values);
        double scanLimit = PositiveFiniteDouble("--max-scan-ms", values);
        double imageLimit = PositiveFiniteDouble("--max-image-ms", values);
        double thumbnailLimit = PositiveFiniteDouble("--max-thumbnail-ms", values);

        if (fileCount > 5_000) throw BenchmarkFailureException.Usage("--files must be within 1...5000.");
        if (trials > 25) throw BenchmarkFailureException.Usage("--trials must be within 1...25.");
        if (width > SXMParser.MaximumPixelDimension || height > SXMParser.MaximumPixelDimension)
        {
            throw BenchmarkFailureException.Usage($"--width and --height must not exceed {SXMParser.MaximumPixelDimension}.");
        }
        foreach ((string flag, double limit) in new[]
        {
            ("--max-scan-ms", scanLimit),
            ("--max-image-ms", imageLimit),
            ("--max-thumbnail-ms", thumbnailLimit)
        })
        {
            if (limit > 60_000.0) throw BenchmarkFailureException.Usage($"{flag} must not exceed 60000.");
        }

        int pixelCount;
        int payloadByteCount;
        int gradientFileCount;
        try
        {
            pixelCount = checked(width * height);
            if (pixelCount > SXMParser.MaximumPixelCount)
            {
                throw BenchmarkFailureException.Usage("The requested pixel count is unsupported.");
            }
            payloadByteCount = checked(pixelCount * 4);
            gradientFileCount = checked(2 * trials + 1);
            if (gradientFileCount > fileCount)
            {
                throw BenchmarkFailureException.Usage("--files must provide one warmup file and two independent files per trial.");
            }
            int physicalBytes = checked(payloadByteCount * gradientFileCount);
            if (physicalBytes > 256 * 1024 * 1024)
            {
                throw BenchmarkFailureException.Usage("The requested rendered fixture payload exceeds 256 MiB.");
            }
            long logicalBytes = checked((long)payloadByteCount * (long)fileCount);
            if (logicalBytes > 64L * 1024L * 1024L * 1024L)
            {
                throw BenchmarkFailureException.Usage("The requested logical fixture payload exceeds 64 GiB.");
            }
        }
        catch (OverflowException)
        {
            throw BenchmarkFailureException.Usage("The requested fixture size overflows.");
        }

        return new BenchmarkConfiguration(
            fileCount, width, height, trials,
            scanLimit, imageLimit, thumbnailLimit,
            pixelCount, payloadByteCount, gradientFileCount);
    }

    private static int PositiveInt(string flag, Dictionary<string, string> values)
    {
        if (!int.TryParse(values[flag], NumberStyles.Integer, CultureInfo.InvariantCulture, out int v) || v <= 0)
        {
            throw BenchmarkFailureException.Usage($"{flag} must be a positive integer.");
        }
        return v;
    }

    private static double PositiveFiniteDouble(string flag, Dictionary<string, string> values)
    {
        if (!double.TryParse(values[flag], NumberStyles.Float, CultureInfo.InvariantCulture, out double v)
            || !double.IsFinite(v) || v <= 0.0)
        {
            throw BenchmarkFailureException.Usage($"{flag} must be a positive finite number.");
        }
        return v;
    }
}

internal sealed class SyntheticFixture : IDisposable
{
    public string Folder { get; }
    public IReadOnlyList<string> Filenames { get; }
    public IReadOnlyList<string> GradientFilenames { get; }

    public SyntheticFixture(string folder, IReadOnlyList<string> filenames, IReadOnlyList<string> gradientFilenames)
    {
        Folder = folder;
        Filenames = filenames;
        GradientFilenames = gradientFilenames;
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(Folder)) Directory.Delete(Folder, recursive: true);
        }
        catch
        {
        }
    }
}

internal static class Program
{
    public static int Main(string[] args)
    {
        try
        {
            RunBenchmark(args);
            return 0;
        }
        catch (BenchmarkFailureException ex)
        {
            WriteFailure(ex.ExitCode, ex.Message);
            return ex.ExitCode;
        }
        catch (Exception ex)
        {
            WriteFailure(70, ex.Message);
            return 70;
        }
    }

    private static void ValidateEnvironment()
    {
#if DEBUG
        throw BenchmarkFailureException.Unsupported("Performance gates require a Release build.");
#endif
    }

    private static SyntheticFixture MakeSyntheticFixture(BenchmarkConfiguration config)
    {
        string folder = Path.Combine(Path.GetTempPath(), $"sxm-browser-benchmark-{Guid.NewGuid():N}");
        Directory.CreateDirectory(folder);

        try
        {
            string header =
                ":NANONIS_VERSION:\n" +
                "2\n" +
                ":SCANIT_TYPE:\n" +
                "FLOAT MSBFIRST\n" +
                ":SCAN_PIXELS:\n" +
                $"{config.Width} {config.Height}\n" +
                ":DATA_INFO:\n" +
                "Channel\tName\tUnit\tDirection\n" +
                "0\tZ\tm\tforward\n" +
                ":SCANIT_END:\n";

            byte[] headerBytes = Encoding.UTF8.GetBytes(header);
            byte[] prefix = new byte[headerBytes.Length + 2];
            Buffer.BlockCopy(headerBytes, 0, prefix, 0, headerBytes.Length);
            prefix[^2] = 0x1A;
            prefix[^1] = 0x04;

            long completeFileLength = checked((long)prefix.Length + config.PayloadByteCount);
            byte[] gradientPayload = new byte[config.PayloadByteCount];
            for (int idx = 0; idx < config.PixelCount; idx++)
            {
                int x = idx % config.Width;
                int y = idx / config.Width;
                int det = (x * x + 3 * y * y + 7 * x * y + 17 * x + 31 * y) % 8_191;
                float sample = det / 8_190.0f;
                BinaryPrimitives.WriteSingleBigEndian(gradientPayload.AsSpan(idx * 4, 4), sample);
            }

            var filenames = new List<string>(config.FileCount);
            var gradientFilenames = new List<string>(config.GradientFileCount);

            for (int i = 0; i < config.FileCount; i++)
            {
                string filename = $"benchmark-{i:D6}.sxm";
                string path = Path.Combine(folder, filename);
                if (i < config.GradientFileCount)
                {
                    using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
                    fs.Write(prefix);
                    fs.Write(gradientPayload);
                    gradientFilenames.Add(filename);
                }
                else
                {
                    using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
                    fs.Write(prefix);
                    fs.SetLength(completeFileLength);
                }
                filenames.Add(filename);
            }

            return new SyntheticFixture(folder, filenames, gradientFilenames);
        }
        catch
        {
            try { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); } catch { }
            throw;
        }
    }

    private static (string Channel, MatrixKey Key) SelectDefaultMatrixKey(SXMMetadata metadata)
    {
        string? channel = metadata.DefaultChannel;
        SXMChannel? info = channel is null ? null : metadata.Channels.FirstOrDefault(c => c.Name == channel);
        if (channel is null || info is null || info.Directions.Count == 0)
        {
            throw BenchmarkFailureException.Gate($"{metadata.Filename} has no usable default matrix.");
        }
        return (channel, new MatrixKey(channel, info.Directions[0]));
    }

    private static void ValidateFixturePayloads(
        SyntheticFixture fixture,
        BenchmarkConfiguration config,
        SXMParser parser)
    {
        string gradientPath = Path.Combine(fixture.Folder, fixture.GradientFilenames[0]);
        SXMMetadata gradMeta = parser.LoadMetadata(gradientPath);
        Matrix gradMatrix = parser.LoadMatrix(gradMeta, SelectDefaultMatrixKey(gradMeta).Key);
        if (gradMatrix.Width != config.Width
            || gradMatrix.Height != config.Height
            || gradMatrix.Values.Length != config.PixelCount
            || !gradMatrix.Values.All(float.IsFinite)
            || !gradMatrix.Values.Any(v => v != 0.0f))
        {
            throw BenchmarkFailureException.Gate("The deterministic gradient fixture is invalid.");
        }

        string sparsePath = Path.Combine(fixture.Folder, fixture.Filenames[^1]);
        SXMMetadata sparseMeta = parser.LoadMetadata(sparsePath);
        Matrix sparseMatrix = parser.LoadMatrix(sparseMeta, SelectDefaultMatrixKey(sparseMeta).Key);
        if (sparseMatrix.Width != config.Width
            || sparseMatrix.Height != config.Height
            || sparseMatrix.Values.Length != config.PixelCount
            || !sparseMatrix.Values.All(v => v == 0.0f))
        {
            throw BenchmarkFailureException.Gate("The sparse zero fixture is invalid.");
        }
    }

    private static void ValidateScan(ScanReport<SXMMetadata> report, BenchmarkConfiguration config)
    {
        if (report.Issues.Count > 0)
        {
            string details = string.Join(" | ", report.Issues.Select(i => $"{Path.GetFileName(i.FilePath)}:{i.Reason}"));
            throw BenchmarkFailureException.Gate($"Synthetic scan produced issues: {details}");
        }
        if (report.Items.Count != config.FileCount
            || report.Items.Select(f => f.Filename).Distinct(StringComparer.Ordinal).Count() != config.FileCount
            || !report.Items.All(f => f.Pixels.Width == config.Width && f.Pixels.Height == config.Height && f.DefaultChannel is not null))
        {
            throw BenchmarkFailureException.Gate(
                $"Synthetic scan did not return exactly {config.FileCount} unique {config.Width}x{config.Height} files.");
        }
    }

    private static SXMMetadata FindMetadata(string filename, IReadOnlyList<SXMMetadata> files)
    {
        return files.FirstOrDefault(f => f.Filename == filename)
            ?? throw BenchmarkFailureException.Gate($"Scanned metadata is missing {filename}.");
    }

    private static void RenderFirstImage(SXMMetadata meta, SXMParser parser, BenchmarkConfiguration config)
    {
        (string channel, MatrixKey key) = SelectDefaultMatrixKey(meta);
        Matrix matrix = parser.LoadMatrix(meta, key);
        ProcessingMode processing = SXMChannelRules.DefaultProcessing(channel);
        Matrix processed = SXMRenderer.ProcessedMatrix(matrix, processing);
        MatrixStatistics? stats = SXMRenderer.Statistics(processed);
        if (stats is null || stats.Count != config.PixelCount)
        {
            throw BenchmarkFailureException.Gate($"{meta.Filename} produced incomplete image statistics.");
        }
        (double vmin, double vmax) = SXMRenderer.AutomaticScale(stats);
        RenderedImage image = SXMRenderer.RenderProcessedImage(
            processed,
            new RenderOptions(
                channel,
                key.Direction,
                processing,
                SXMChannelRules.DefaultPalette(channel),
                vmin,
                vmax));
        if (image.Width != config.Width || image.Height != config.Height)
        {
            throw BenchmarkFailureException.Gate($"{meta.Filename} produced an invalid first image.");
        }
    }

    private static void RenderFirstThumbnail(SXMMetadata meta, SXMParser parser, BenchmarkConfiguration config)
    {
        (string channel, MatrixKey key) = SelectDefaultMatrixKey(meta);
        Matrix matrix = parser.LoadMatrix(meta, key);
        if (matrix.Width != config.Width || matrix.Height != config.Height || matrix.Values.Length != config.PixelCount)
        {
            throw BenchmarkFailureException.Gate($"{meta.Filename} produced an incomplete thumbnail matrix.");
        }
        RenderedImage image = SXMRenderer.RenderImage(
            matrix,
            new RenderOptions(
                channel,
                key.Direction,
                SXMChannelRules.DefaultProcessing(channel),
                SXMChannelRules.DefaultPalette(channel),
                OutputSize: 260));
        if (image.Width <= 0 || image.Height <= 0 || image.Width > 260 || image.Height > 260)
        {
            throw BenchmarkFailureException.Gate($"{meta.Filename} produced an invalid first thumbnail.");
        }
    }

    private static (T Value, double Ms) Measure<T>(Func<T> op)
    {
        long start = Stopwatch.GetTimestamp();
        T result = op();
        double ms = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        return (result, ms);
    }

    private static double Measure(Action op)
    {
        long start = Stopwatch.GetTimestamp();
        op();
        return Stopwatch.GetElapsedTime(start).TotalMilliseconds;
    }

    private static double Median(List<double> samples)
    {
        var ordered = samples.OrderBy(x => x).ToArray();
        int mid = ordered.Length / 2;
        return ordered.Length % 2 == 0
            ? (ordered[mid - 1] + ordered[mid]) / 2.0
            : ordered[mid];
    }

    private static string Fmt(double v) => v.ToString("F3", CultureInfo.InvariantCulture);
    private static string FmtList(List<double> vs) => string.Join(',', vs.Select(Fmt));

    private static void RunBenchmark(string[] args)
    {
        BenchmarkConfiguration config = BenchmarkConfiguration.Parse(args);
        ValidateEnvironment();

        using SyntheticFixture fixture = MakeSyntheticFixture(config);
        var parser = new SXMParser();
        ValidateFixturePayloads(fixture, config, parser);

        ScanReport<SXMMetadata> warmupScan = parser.ScanFolder(fixture.Folder);
        ValidateScan(warmupScan, config);

        var scanSamples = new List<double>(config.Trials);
        IReadOnlyList<SXMMetadata> scannedFiles = warmupScan.Items;
        for (int t = 0; t < config.Trials; t++)
        {
            (ScanReport<SXMMetadata> report, double ms) = Measure(() => parser.ScanFolder(fixture.Folder));
            ValidateScan(report, config);
            scannedFiles = report.Items;
            scanSamples.Add(ms);
        }

        SXMMetadata warmupMeta = FindMetadata(fixture.GradientFilenames[0], scannedFiles);
        RenderFirstImage(warmupMeta, parser, config);
        RenderFirstThumbnail(warmupMeta, parser, config);

        var imageSamples = new List<double>(config.Trials);
        var thumbnailSamples = new List<double>(config.Trials);

        for (int t = 0; t < config.Trials; t++)
        {
            SXMMetadata meta = FindMetadata(fixture.GradientFilenames[t + 1], scannedFiles);
            imageSamples.Add(Measure(() => RenderFirstImage(meta, parser, config)));
        }

        for (int t = 0; t < config.Trials; t++)
        {
            SXMMetadata meta = FindMetadata(fixture.GradientFilenames[config.Trials + t + 1], scannedFiles);
            thumbnailSamples.Add(Measure(() => RenderFirstThumbnail(meta, parser, config)));
        }

        double scanMedian = Median(scanSamples);
        double imageMedian = Median(imageSamples);
        double thumbnailMedian = Median(thumbnailSamples);

        Console.WriteLine($"benchmark_fixture_files={config.FileCount}");
        Console.WriteLine($"benchmark_fixture_size={config.Width}x{config.Height}");
        Console.WriteLine($"benchmark_trials={config.Trials}");
        Console.WriteLine($"scan_samples_ms={FmtList(scanSamples)}");
        Console.WriteLine($"scan_median_ms={Fmt(scanMedian)}");
        Console.WriteLine($"first_image_samples_ms={FmtList(imageSamples)}");
        Console.WriteLine($"first_image_median_ms={Fmt(imageMedian)}");
        Console.WriteLine($"first_thumbnail_samples_ms={FmtList(thumbnailSamples)}");
        Console.WriteLine($"first_thumbnail_median_ms={Fmt(thumbnailMedian)}");
        Console.WriteLine(
            $"limits_ms=scan:{Fmt(config.MaximumScanMilliseconds)},image:{Fmt(config.MaximumImageMilliseconds)},thumbnail:{Fmt(config.MaximumThumbnailMilliseconds)}");

        var failures = new List<string>();
        if (scanMedian > config.MaximumScanMilliseconds)
        {
            failures.Add($"scan median {Fmt(scanMedian)} ms exceeds {Fmt(config.MaximumScanMilliseconds)} ms");
        }
        if (imageMedian > config.MaximumImageMilliseconds)
        {
            failures.Add($"first image median {Fmt(imageMedian)} ms exceeds {Fmt(config.MaximumImageMilliseconds)} ms");
        }
        if (thumbnailMedian > config.MaximumThumbnailMilliseconds)
        {
            failures.Add($"first thumbnail median {Fmt(thumbnailMedian)} ms exceeds {Fmt(config.MaximumThumbnailMilliseconds)} ms");
        }
        if (failures.Count > 0)
        {
            throw BenchmarkFailureException.Gate(string.Join("; ", failures));
        }

        Console.WriteLine("benchmark_result=passed");
    }

    private static void WriteFailure(int code, string reason)
    {
        string singleLine = reason.Replace("\r", " ").Replace("\n", " ");
        Console.Error.WriteLine("benchmark_result=failed");
        Console.Error.WriteLine($"benchmark_exit_code={code}");
        Console.Error.WriteLine($"benchmark_error={singleLine}");
    }
}
