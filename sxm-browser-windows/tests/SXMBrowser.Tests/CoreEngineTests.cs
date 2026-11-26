using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;
using System.Text;
using SXMBrowser.Core;
using Xunit;

namespace SXMBrowser.Tests;

public static class TestRepoPaths
{
    public static string ExampleGraphDir()
    {
        string? dir = AppContext.BaseDirectory;
        while (!string.IsNullOrEmpty(dir))
        {
            string candidate = Path.Combine(dir, "example-graph");
            if (File.Exists(Path.Combine(candidate, "Au1110145.sxm")))
            {
                return candidate;
            }
            dir = Path.GetDirectoryName(dir);
        }
        throw new DirectoryNotFoundException("Could not locate workspace example-graph directory.");
    }
}

public sealed class CoreEngineTests
{
    private static string WriteSyntheticSxm(
        string folder,
        string filename,
        string scanDir,
        int width,
        int height,
        float[] fwdRowMajor,
        float[]? bwdRowMajor = null,
        bool truncatePayload = false)
    {
        string dirLine = bwdRowMajor is null ? "forward" : "both";
        string header =
            ":NANONIS_VERSION:\n2\n" +
            ":SCANIT_TYPE:\nFLOAT MSBFIRST\n" +
            ":SCAN_PIXELS:\n" + $"{width} {height}\n" +
            ":SCAN_DIR:\n" + $"{scanDir}\n" +
            ":DATA_INFO:\n" +
            "Channel\tName\tUnit\tDirection\n" +
            $"0\tZ\tm\t{dirLine}\n" +
            ":SCANIT_END:\n";

        byte[] hdrBytes = Encoding.UTF8.GetBytes(header);
        byte[] marker = [0x1A, 0x04];
        string path = Path.Combine(folder, filename);
        using var fs = new FileStream(path, FileMode.Create, FileAccess.Write);
        fs.Write(hdrBytes);
        fs.Write(marker);

        void WriteFloats(float[] arr, int count)
        {
            Span<byte> buf = stackalloc byte[4];
            for (int i = 0; i < count; i++)
            {
                BinaryPrimitives.WriteSingleBigEndian(buf, arr[i]);
                fs.Write(buf);
            }
        }

        int fwdCount = truncatePayload ? Math.Max(1, fwdRowMajor.Length - 2) : fwdRowMajor.Length;
        WriteFloats(fwdRowMajor, fwdCount);
        if (bwdRowMajor is not null && !truncatePayload)
        {
            WriteFloats(bwdRowMajor, bwdRowMajor.Length);
        }
        return path;
    }

    [Fact]
    public void CanonicalExampleGraphSxmAndDatScanCleanly()
    {
        string folder = TestRepoPaths.ExampleGraphDir();
        var sxmParser = new SXMParser();
        var datParser = new SpectroscopyParser();

        ScanReport<SXMMetadata> sxm = sxmParser.ScanFolder(folder);
        ScanReport<SpectroscopyFile> dat = datParser.ScanFolder(folder);

        Assert.Equal(6, sxm.Items.Count);
        Assert.Empty(sxm.Issues);
        Assert.Equal(18, dat.Items.Count);
        Assert.Empty(dat.Issues);

        foreach (SXMMetadata item in sxm.Items)
        {
            SXMFullFile full = sxmParser.LoadFullFile(item);
            Assert.NotEmpty(full.Matrices);
        }
    }

    [Fact]
    public void SxmParserNormalizesUpwardAndBackwardScansAndPreservesNaN()
    {
        string temp = Path.Combine(Path.GetTempPath(), $"sxm-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temp);
        try
        {
            float[] rawFwd = [1f, 2f, float.NaN, 4f]; // 2x2: row0=[1,2], row1=[NaN,4]
            float[] rawBwd = [10f, 20f, 30f, 40f];
            string upPath = WriteSyntheticSxm(temp, "up.sxm", "up", 2, 2, rawFwd, rawBwd);
            string downPath = WriteSyntheticSxm(temp, "down.sxm", "down", 2, 2, rawFwd, rawBwd);

            var parser = new SXMParser();
            SXMMetadata upMeta = parser.LoadMetadata(upPath);
            SXMMetadata downMeta = parser.LoadMetadata(downPath);

            // Downward preserves raw row order ([1,2] then [NaN,4])
            Matrix downFwd = parser.LoadMatrix(downMeta, new MatrixKey("Z", ScanDirection.Fwd));
            Assert.Equal(1f, downFwd[0, 0]);
            Assert.Equal(2f, downFwd[1, 0]);
            Assert.True(float.IsNaN(downFwd[0, 1]));
            Assert.Equal(4f, downFwd[1, 1]);

            // Upward flips vertically so row 0 is [NaN, 4] (physical +Y)
            Matrix upFwd = parser.LoadMatrix(upMeta, new MatrixKey("Z", ScanDirection.Fwd));
            Assert.True(float.IsNaN(upFwd[0, 0]));
            Assert.Equal(4f, upFwd[1, 0]);
            Assert.Equal(1f, upFwd[0, 1]);
            Assert.Equal(2f, upFwd[1, 1]);

            // Bwd reverses columns horizontally ([20,10], [40,30] on down)
            Matrix downBwd = parser.LoadMatrix(downMeta, new MatrixKey("Z", ScanDirection.Bwd));
            Assert.Equal(20f, downBwd[0, 0]);
            Assert.Equal(10f, downBwd[1, 0]);
            Assert.Equal(40f, downBwd[0, 1]);
            Assert.Equal(30f, downBwd[1, 1]);
        }
        finally
        {
            Directory.Delete(temp, recursive: true);
        }
    }

    [Fact]
    public void SxmParserRejectsTruncatedPayload()
    {
        string temp = Path.Combine(Path.GetTempPath(), $"sxm-trunc-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temp);
        try
        {
            string bad = WriteSyntheticSxm(temp, "short.sxm", "down", 2, 2, [1f, 2f, 3f, 4f], truncatePayload: true);
            var parser = new SXMParser();
            SXMMetadata meta = parser.LoadMetadata(bad);
            SXMParserException ex = Assert.Throws<SXMParserException>(
                () => parser.LoadMatrix(meta, new MatrixKey("Z", ScanDirection.Fwd)));
            Assert.Equal(SXMParserErrorKind.ShortData, ex.Kind);
        }
        finally
        {
            Directory.Delete(temp, recursive: true);
        }
    }

    [Fact]
    public void RendererPlaneLinearAndPngCodecRoundtripPreservePrecision()
    {
        // Pure tilted plane + NaN sample: plane fit should flatten finite pixels near zero and preserve NaN.
        float[] vals = new float[16];
        for (int y = 0; y < 4; y++)
        {
            for (int x = 0; x < 4; x++)
            {
                vals[y * 4 + x] = 1000.0f + 2.5f * x - 1.25f * y;
            }
        }
        vals[5] = float.NaN;
        var matrix = new Matrix(4, 4, vals);

        Matrix flat = SXMRenderer.ProcessedMatrix(matrix, ProcessingMode.PlaneLinear);
        Assert.True(float.IsNaN(flat[1, 1]));
        for (int i = 0; i < flat.Values.Length; i++)
        {
            if (i == 5) continue;
            Assert.InRange(Math.Abs(flat.Values[i]), 0.0, 1e-3);
        }

        MatrixStatistics? stats = SXMRenderer.Statistics(flat);
        Assert.NotNull(stats);
        Assert.Equal(15, stats!.Count);
        HistogramDistribution hist = SXMRenderer.Histogram(flat, stats, 32);
        Assert.Equal(15, hist.Counts.Sum());

        byte[] png = SXMRenderer.PngData(
            matrix,
            new RenderOptions("Z", ScanDirection.Fwd, ProcessingMode.PlaneLinear, PaletteName.Gwyddion));
        var decoded = PngCodec.DecodeRgba8888(png);
        Assert.True(decoded.HasSrgbChunk);
        Assert.Equal(4, decoded.Width);
        Assert.Equal(4, decoded.Height);
    }

    [Fact]
    public void DatDuplicateColumnsPreserveNumberedChannelValues()
    {
        string path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path,
                "[DATA]\nBias\tCurrent\tCurrent\tCurrent (2)\tCurrent\n" +
                "0\t1\t2\t3\t4\n1\t5\t6\t7\t8\n");

            var curve = new SpectroscopyParser().LoadFile(path).Curve;

            Assert.Equal(["Bias", "Current", "Current (3)", "Current (2)", "Current (4)"], curve.Columns);
            Assert.Equal([1d, 5d], curve.ValuesByColumn["Current"]);
            Assert.Equal([2d, 6d], curve.ValuesByColumn["Current (3)"]);
            Assert.Equal([3d, 7d], curve.ValuesByColumn["Current (2)"]);
            Assert.Equal([4d, 8d], curve.ValuesByColumn["Current (4)"]);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void EngineeringDoubleParserAndNaturalSortBehaveDeterministically()
    {
        Assert.Equal(1.5e-9, SpectroscopyParser.ParseEngineeringDouble("1.5n")!.Value, 15);
        Assert.Equal(-2.25e-6, SpectroscopyParser.ParseEngineeringDouble("-2.25µ")!.Value, 12);
        Assert.Equal(4.0e3, SpectroscopyParser.ParseEngineeringDouble("4k")!.Value, 9);

        string[] items = ["scan10.sxm", "scan2.sxm", "scan1.sxm"];
        Array.Sort(items, NaturalStringComparer.CompareFilenames);
        Assert.Equal(["scan1.sxm", "scan2.sxm", "scan10.sxm"], items);
    }
}
