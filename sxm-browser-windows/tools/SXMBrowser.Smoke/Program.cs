using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using SXMBrowser.AppCore;
using SXMBrowser.Core;

namespace SXMBrowser.Smoke;

internal sealed class SmokeFailureException : Exception
{
    public int ExitCode { get; }

    public SmokeFailureException(int exitCode, string message) : base(message)
    {
        ExitCode = exitCode;
    }

    public static SmokeFailureException Usage(string msg) => new(64, msg);
    public static SmokeFailureException Input(string msg) => new(66, msg);
    public static SmokeFailureException Contract(string msg) => new(1, msg);
}

internal static class Program
{
    private readonly record struct PixelDimensions(int Width, int Height);
    private sealed record FirstRenderFixture(string Filename, string Channel, ScanDirection Direction, Matrix Matrix);

    private static readonly Dictionary<string, PixelDimensions> ExpectedSxmDimensions = new(StringComparer.Ordinal)
    {
        ["Au1110145.sxm"] = new(112, 112),
        ["Au1110191.sxm"] = new(112, 112),
        ["Au1110363.sxm"] = new(112, 112),
        ["Au1110365.sxm"] = new(512, 512),
        ["Au1110410.sxm"] = new(112, 112),
        ["Au1110419.sxm"] = new(112, 112)
    };

    private static readonly HashSet<string> ExpectedDatNames = new(StringComparer.Ordinal)
    {
        "Au1110145Z-Spectroscopy-1.dat",
        "Au1110145Z-Spectroscopy-2.dat",
        "Au1110145Z-Spectroscopy-3.dat",
        "Au1110145Z-Spectroscopy-4.dat",
        "Au1110145Z-Spectroscopy-5.dat",
        "Au1110191Z-Spectroscopy-1.dat",
        "Au1110191Z-Spectroscopy-2dat.dat",
        "Au1110191Z-Spectroscopy-3.dat",
        "Au1110363Bias-Spectroscopy-1.dat",
        "Au1110363Bias-Spectroscopy-2.dat",
        "Au1110365Bias-Spectroscopy-1.dat",
        "Au1110365Bias-Spectroscopy-2.dat",
        "Au1110410Z-Spectroscopy-1.dat",
        "Au1110410Z-Spectroscopy-2.dat",
        "Au1110410Z-Spectroscopy-3.dat",
        "Au1110419Z-Spectroscopy-1.dat",
        "Au1110419Z-Spectroscopy-2.dat",
        "Au1110419Z-Spectroscopy-3.dat"
    };

    public static int Main(string[] args)
    {
        try
        {
            RunSmoke(args);
            return 0;
        }
        catch (SmokeFailureException ex)
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

    private static string CanonicalSampleFolder(string[] args)
    {
        if (args.Length != 2 || args[0] != "--canonical-sample" || string.IsNullOrWhiteSpace(args[1]))
        {
            throw SmokeFailureException.Usage("Usage: SXMBrowserSmoke --canonical-sample <directory>");
        }

        string folder = Path.GetFullPath(args[1]);
        if (!Directory.Exists(folder))
        {
            throw SmokeFailureException.Input($"Canonical sample directory is missing or unreadable: {folder}");
        }
        return folder;
    }

    private static void VerifyCanonicalNames(
        IReadOnlyList<string> actual,
        HashSet<string> expected,
        string kind)
    {
        var actualSet = new HashSet<string>(actual, StringComparer.Ordinal);
        var missing = expected.Except(actualSet, StringComparer.Ordinal).OrderBy(s => s, StringComparer.Ordinal).ToArray();
        var unexpected = actualSet.Except(expected, StringComparer.Ordinal).OrderBy(s => s, StringComparer.Ordinal).ToArray();

        if (actual.Count != expected.Count
            || actualSet.Count != actual.Count
            || missing.Length > 0
            || unexpected.Length > 0)
        {
            string missingText = missing.Length == 0 ? "-" : string.Join(',', missing);
            string unexpectedText = unexpected.Length == 0 ? "-" : string.Join(',', unexpected);
            throw SmokeFailureException.Contract(
                $"{kind} file set does not match the canonical sample; expected={expected.Count} actual={actual.Count} missing={missingText} unexpected={unexpectedText}");
        }
    }

    private static (int PayloadCount, int MatrixCount, FirstRenderFixture FirstRender) ValidateSxmFiles(
        IReadOnlyList<SXMMetadata> files,
        SXMParser parser)
    {
        if (files.Count == 0)
        {
            throw SmokeFailureException.Contract("The canonical sample has no SXM files.");
        }

        SXMMetadata firstFile = files[0];
        int payloadCount = 0;
        int matrixCount = 0;
        FirstRenderFixture? firstRender = null;

        foreach (SXMMetadata file in files)
        {
            if (!ExpectedSxmDimensions.TryGetValue(file.Filename, out PixelDimensions expected))
            {
                throw SmokeFailureException.Contract($"Unexpected SXM file reached payload validation: {file.Filename}");
            }
            if (file.Pixels.Width != expected.Width || file.Pixels.Height != expected.Height)
            {
                throw SmokeFailureException.Contract(
                    $"{file.Filename} dimensions are {file.Pixels.Width}x{file.Pixels.Height}; expected {expected.Width}x{expected.Height}");
            }

            SXMFullFile full;
            try
            {
                full = parser.LoadFullFile(file);
            }
            catch (Exception ex)
            {
                throw SmokeFailureException.Contract($"Could not load the complete payload for {file.Filename}: {ex.Message}");
            }
            payloadCount++;

            if (full.Matrices.Count == 0)
            {
                throw SmokeFailureException.Contract($"{file.Filename} contains no readable matrices.");
            }
            foreach (Matrix matrix in full.Matrices.Values)
            {
                if (matrix.Width != expected.Width
                    || matrix.Height != expected.Height
                    || matrix.Values.Length != expected.Width * expected.Height)
                {
                    throw SmokeFailureException.Contract(
                        $"{file.Filename} contains a matrix with inconsistent dimensions or sample count.");
                }
                matrixCount++;
            }

            string? channel = full.Metadata.DefaultChannel;
            SXMChannel? channelInfo = channel is null
                ? null
                : full.Metadata.Channels.FirstOrDefault(c => c.Name == channel);
            if (channel is null || channelInfo is null || channelInfo.Directions.Count == 0)
            {
                throw SmokeFailureException.Contract($"{file.Filename} has no usable default channel.");
            }

            ScanDirection direction = channelInfo.Directions[0];
            var defaultKey = new MatrixKey(channel, direction);
            if (!full.Matrices.TryGetValue(defaultKey, out Matrix? defaultMatrix))
            {
                throw SmokeFailureException.Contract(
                    $"{file.Filename} is missing its default matrix {channel} {direction.ToRawValue()}.");
            }

            if (file.Id == firstFile.Id)
            {
                firstRender = new FirstRenderFixture(file.Filename, channel, direction, defaultMatrix);
            }
        }

        if (firstRender is null)
        {
            throw SmokeFailureException.Contract("The first canonical SXM payload was not validated.");
        }
        return (payloadCount, matrixCount, firstRender);
    }

    private static int ValidateSpectroscopyFiles(IReadOnlyList<SpectroscopyFile> files)
    {
        foreach (SpectroscopyFile file in files)
        {
            SpectroscopyCurve curve = file.Curve;
            if (curve.Columns.Count < 2
                || curve.Columns.Distinct(StringComparer.Ordinal).Count() != curve.Columns.Count
                || curve.ValuesByColumn.Count != curve.Columns.Count
                || curve.X.Length < 2
                || curve.Y.Length != curve.X.Length
                || !curve.X.All(double.IsFinite)
                || !curve.Y.All(double.IsFinite))
            {
                throw SmokeFailureException.Contract($"{file.Filename} has an incomplete spectroscopy curve.");
            }

            foreach (string col in curve.Columns)
            {
                if (!curve.ValuesByColumn.TryGetValue(col, out double[]? vals)
                    || vals.Length != curve.X.Length
                    || !vals.All(double.IsFinite))
                {
                    throw SmokeFailureException.Contract(
                        $"{file.Filename} has an incomplete or non-finite column: {col}");
                }
            }
        }
        return files.Count;
    }

    private static (int StatisticsCount, int HistogramBins, string ImageSize) ValidateFirstRender(FirstRenderFixture fixture)
    {
        ProcessingMode processing = SXMChannelRules.DefaultProcessing(fixture.Channel);
        PaletteName palette = SXMChannelRules.DefaultPalette(fixture.Channel);
        Matrix processed = SXMRenderer.ProcessedMatrix(fixture.Matrix, processing);
        MatrixStatistics? stats = SXMRenderer.Statistics(processed)
            ?? throw SmokeFailureException.Contract($"{fixture.Filename} produced no finite render statistics.");

        HistogramDistribution histogram = SXMRenderer.Histogram(processed, stats, 128);
        (double vmin, double vmax) = SXMRenderer.AutomaticScale(stats);
        RenderedImage image = SXMRenderer.RenderProcessedImage(
            processed,
            new RenderOptions(
                Channel: fixture.Channel,
                Direction: fixture.Direction,
                Processing: processing,
                Palette: palette,
                Vmin: vmin,
                Vmax: vmax));

        if (stats.Count <= 0
            || histogram.Bins != 128
            || histogram.Counts.Length != 128
            || histogram.Edges.Length != 129
            || histogram.Counts.Sum() != stats.Count)
        {
            throw SmokeFailureException.Contract($"{fixture.Filename} produced inconsistent histogram results.");
        }

        if (image.Width != fixture.Matrix.Width || image.Height != fixture.Matrix.Height)
        {
            throw SmokeFailureException.Contract(
                $"{fixture.Filename} rendered at {image.Width}x{image.Height}; expected {fixture.Matrix.Width}x{fixture.Matrix.Height}.");
        }

        return (stats.Count, histogram.Bins, $"{image.Width}x{image.Height}");
    }

    private static void RunSmoke(string[] args)
    {
        string folder = CanonicalSampleFolder(args);

        PaletteName[] expectedPalettes =
        [
            PaletteName.Gwyddion,
            PaletteName.DuskViolet,
            PaletteName.BlueViolet,
            PaletteName.Ember,
            PaletteName.Gray
        ];
        int validPaletteCount = SXMValueExtensions.AllPalettes.Count(
            p => PaletteStore.Shared.Stops(p).Count >= 2);
        if (SXMValueExtensions.AllPalettes.Count != expectedPalettes.Length
            || !new HashSet<PaletteName>(SXMValueExtensions.AllPalettes).SetEquals(expectedPalettes)
            || validPaletteCount != expectedPalettes.Length)
        {
            throw SmokeFailureException.Contract(
                $"The embedded palette catalog is incomplete; expected={expectedPalettes.Length} actual={validPaletteCount}.");
        }

        float[] rampValues = new float[257];
        for (int i = 0; i <= 256; i++)
        {
            rampValues[i] = i / 256.0f;
        }
        var paletteRamp = new Matrix(257, 1, rampValues);

        foreach (PaletteName palette in new[]
        {
            PaletteName.Gwyddion,
            PaletteName.BlueViolet,
            PaletteName.DuskViolet,
            PaletteName.Ember
        })
        {
            var options = new RenderOptions("Z", ScanDirection.Fwd, ProcessingMode.Raw, palette, Vmin: 0.0, Vmax: 1.0);
            byte[] png = SXMRenderer.PngData(paletteRamp, options);
            var decoded = PngCodec.DecodeRgba8888(png);
            if (!decoded.HasSrgbChunk || decoded.Width != paletteRamp.Width || decoded.Height != paletteRamp.Height)
            {
                throw SmokeFailureException.Contract($"Palette {palette.ToRawValue()} did not produce a valid sRGB PNG.");
            }
            var lowRgba = decoded.RgbaBytes.AsSpan(0, 4);
            var highRgba = decoded.RgbaBytes.AsSpan((paletteRamp.Width - 1) * 4, 4);
            if (lowRgba.SequenceEqual(highRgba))
            {
                throw SmokeFailureException.Contract($"Palette {palette.ToRawValue()} did not produce a valid PNG gradient.");
            }
        }

        var sxmParser = new SXMParser();
        var spectroscopyParser = new SpectroscopyParser();
        ScanReport<SXMMetadata> sxmReport;
        ScanReport<SpectroscopyFile> spectroscopyReport;
        try
        {
            sxmReport = sxmParser.ScanFolder(folder);
            spectroscopyReport = spectroscopyParser.ScanFolder(folder);
        }
        catch (Exception ex)
        {
            throw SmokeFailureException.Contract($"Could not scan the canonical sample: {ex.Message}");
        }

        Console.WriteLine($"canonical_sample={folder}");
        Console.WriteLine($"palettes={validPaletteCount}/{expectedPalettes.Length}");
        Console.WriteLine($"sxm_files={sxmReport.Items.Count} sxm_issues={sxmReport.Issues.Count}");
        Console.WriteLine($"dat_files={spectroscopyReport.Items.Count} dat_issues={spectroscopyReport.Issues.Count}");

        if (sxmReport.Issues.Count > 0)
        {
            string details = string.Join(" | ", sxmReport.Issues.Select(
                i => $"{Path.GetFileName(i.FilePath)}:{i.Stage.ToRawValue()}:{i.Reason}"));
            throw SmokeFailureException.Contract($"SXM scan issues: {details}");
        }
        if (spectroscopyReport.Issues.Count > 0)
        {
            string details = string.Join(" | ", spectroscopyReport.Issues.Select(
                i => $"{Path.GetFileName(i.FilePath)}:{i.Stage.ToRawValue()}:{i.Reason}"));
            throw SmokeFailureException.Contract($"DAT scan issues: {details}");
        }

        VerifyCanonicalNames(sxmReport.Items.Select(f => f.Filename).ToArray(), [.. ExpectedSxmDimensions.Keys], "SXM");
        VerifyCanonicalNames(spectroscopyReport.Items.Select(f => f.Filename).ToArray(), ExpectedDatNames, "DAT");

        var sxmValidation = ValidateSxmFiles(sxmReport.Items, sxmParser);
        int datCurveCount = ValidateSpectroscopyFiles(spectroscopyReport.Items);
        var renderValidation = ValidateFirstRender(sxmValidation.FirstRender);

        // Also verify all 18 DAT files associate cleanly with the 6 SXM files
        SpectrumAssociationResult assoc = SpectrumAssociationResolver.AssociateSpectra(
            spectroscopyReport.Items, sxmReport.Items);
        if (assoc.UnassociatedSpectrumIds.Count != 0)
        {
            throw SmokeFailureException.Contract(
                $"Expected all canonical DAT files to associate, but {assoc.UnassociatedSpectrumIds.Count} remained unassociated.");
        }

        Console.WriteLine($"sxm_payloads={sxmValidation.PayloadCount} sxm_matrices={sxmValidation.MatrixCount}");
        Console.WriteLine($"dat_curves={datCurveCount}");
        Console.WriteLine(
            $"first_file={sxmValidation.FirstRender.Filename} first_channel={sxmValidation.FirstRender.Channel} first_direction={sxmValidation.FirstRender.Direction.ToRawValue()}");
        Console.WriteLine(
            $"first_statistics_count={renderValidation.StatisticsCount} first_histogram_bins={renderValidation.HistogramBins} first_image_size={renderValidation.ImageSize}");
        Console.WriteLine("smoke_result=passed");
    }

    private static void WriteFailure(int code, string reason)
    {
        string singleLine = reason.Replace("\r", " ").Replace("\n", " ");
        Console.Error.WriteLine("smoke_result=failed");
        Console.Error.WriteLine($"smoke_exit_code={code}");
        Console.Error.WriteLine($"smoke_error={singleLine}");
    }
}
