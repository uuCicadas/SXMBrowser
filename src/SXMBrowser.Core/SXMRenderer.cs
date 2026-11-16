using System;
using System.Collections.Generic;

namespace SXMBrowser.Core;

public enum SXMRenderErrorKind
{
    MissingMatrix,
    ImageCreationFailed
}

public sealed class SXMRenderException : Exception
{
    public SXMRenderErrorKind Kind { get; }

    public SXMRenderException(SXMRenderErrorKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }
}

public static class SXMRenderer
{
    public static Matrix ProcessedMatrix(Matrix matrix, ProcessingMode processing)
        => ProcessedMatrix(matrix, processing, CancellationCheckpoint.None);

    public static Matrix ProcessedMatrix(
        Matrix matrix,
        ProcessingMode processing,
        CancellationCheckpoint cancellation)
    {
        cancellation.Check();
        return processing switch
        {
            ProcessingMode.Raw => matrix,
            ProcessingMode.LineMean => LineMeanSubtract(matrix, cancellation),
            ProcessingMode.LineSlope => LineSlopeSubtract(matrix, cancellation),
            ProcessingMode.LineLinear => LineLinearFit(matrix, cancellation),
            ProcessingMode.LineDerivative => LineDifferentiate(matrix, cancellation),
            ProcessingMode.PlaneLinear => PlaneLinearFit(matrix, cancellation),
            _ => throw new ArgumentOutOfRangeException(nameof(processing), processing, null)
        };
    }

    public static MatrixStatistics? Statistics(Matrix matrix)
        => Statistics(matrix, CancellationCheckpoint.None);

    public static MatrixStatistics? Statistics(Matrix matrix, CancellationCheckpoint cancellation)
    {
        cancellation.Check();
        float[] values = matrix.Values;
        var finite = new List<float>(values.Length);

        double mean = 0.0;
        double sumOfSquaredDeviations = 0.0;

        for (int index = 0; index < values.Length; index++)
        {
            if (index % 4_096 == 0)
            {
                cancellation.Check();
            }
            float sample = values[index];
            if (!float.IsFinite(sample)) continue;
            finite.Add(sample);
            double value = sample;
            double count = finite.Count;
            double delta = value - mean;
            mean += delta / count;
            double adjustedDelta = value - mean;
            sumOfSquaredDeviations += delta * adjustedDelta;
        }

        if (finite.Count == 0) return null;

        cancellation.Check();
        finite.Sort();
        cancellation.Check();

        double minValue = finite[0];
        double maxValue = finite[^1];
        double variance = Math.Max(0.0, sumOfSquaredDeviations / finite.Count);

        return new MatrixStatistics(
            Count: finite.Count,
            Min: minValue,
            Max: maxValue,
            P1: Percentile(finite, 1.0),
            P99: Percentile(finite, 99.0),
            Mean: mean,
            Std: Math.Sqrt(variance));
    }

    public static HistogramDistribution Histogram(
        Matrix matrix,
        MatrixStatistics statistics,
        int requestedBins = 256)
        => Histogram(matrix, statistics, requestedBins, CancellationCheckpoint.None);

    public static HistogramDistribution Histogram(
        Matrix matrix,
        MatrixStatistics statistics,
        int requestedBins,
        CancellationCheckpoint cancellation)
    {
        cancellation.Check();
        int bins = Math.Max(16, Math.Min(2048, requestedBins));
        float[] values = matrix.Values;

        if (statistics.Max == statistics.Min)
        {
            int[] constHist = new int[bins];
            int finiteCount = 0;
            for (int index = 0; index < values.Length; index++)
            {
                if (index % 4_096 == 0)
                {
                    cancellation.Check();
                }
                if (float.IsFinite(values[index]))
                {
                    finiteCount++;
                }
            }
            constHist[bins / 2] = finiteCount;
            double[] constEdges = new double[bins + 1];
            Array.Fill(constEdges, statistics.Min);
            return new HistogramDistribution(bins, constHist, constEdges);
        }

        double width = (statistics.Max - statistics.Min) / bins;
        int[] hist = new int[bins];
        for (int index = 0; index < values.Length; index++)
        {
            if (index % 4_096 == 0)
            {
                cancellation.Check();
            }
            float sample = values[index];
            if (!float.IsFinite(sample)) continue;
            double value = sample;
            int idx = Math.Min(bins - 1, Math.Max(0, (int)((value - statistics.Min) / width)));
            hist[idx]++;
        }

        cancellation.Check();
        double[] edges = new double[bins + 1];
        for (int i = 0; i <= bins; i++)
        {
            edges[i] = statistics.Min + i * width;
        }

        return new HistogramDistribution(bins, hist, edges);
    }

    public static HistogramStats? Histogram(Matrix matrix, int requestedBins = 256)
        => Histogram(matrix, requestedBins, CancellationCheckpoint.None);

    public static HistogramStats? Histogram(
        Matrix matrix,
        int requestedBins,
        CancellationCheckpoint cancellation)
    {
        MatrixStatistics? stats = Statistics(matrix, cancellation);
        if (stats is null) return null;
        return new HistogramStats(
            stats,
            Histogram(matrix, stats, requestedBins, cancellation));
    }

    public static RenderedImage RenderImage(
        Matrix matrix,
        RenderOptions options,
        CancellationCheckpoint cancellation = default)
    {
        Matrix processed = ProcessedMatrix(matrix, options.Processing, cancellation);
        return RenderProcessedImage(processed, options, cancellation);
    }

    public static RenderedImage RenderProcessedImage(
        Matrix matrix,
        RenderOptions options,
        CancellationCheckpoint cancellation = default)
    {
        if (matrix.Width <= 0 || matrix.Height <= 0)
        {
            throw new SXMRenderException(
                SXMRenderErrorKind.ImageCreationFailed,
                "Could not create image.");
        }

        double? resolvedMin = options.Vmin;
        double? resolvedMax = options.Vmax;
        Matrix targetMatrix = matrix;

        if (options.OutputSize is int outSize && outSize > 0
            && Math.Max(matrix.Width, matrix.Height) > outSize * 2)
        {
            if (resolvedMin is null || resolvedMax is null)
            {
                (double Vmin, double Vmax)? auto = AutomaticScale(matrix, cancellation);
                resolvedMin ??= auto?.Vmin;
                resolvedMax ??= auto?.Vmax;
            }
            targetMatrix = DownsampleMatrix(matrix, outSize * 2, cancellation);
        }

        byte[] rgba = Colorize(
            targetMatrix,
            options.Palette,
            resolvedMin,
            resolvedMax,
            options.Invert,
            options.TransparentMissingValues,
            cancellation);
        cancellation.Check();

        if (options.OutputSize is int targetMaxSide && targetMaxSide > 0)
        {
            return ResizeRgbaImage(rgba, targetMatrix.Width, targetMatrix.Height, targetMaxSide, cancellation);
        }

        return new RenderedImage(targetMatrix.Width, targetMatrix.Height, rgba);
    }

    public static byte[] PngData(
        Matrix matrix,
        RenderOptions options,
        CancellationCheckpoint cancellation = default)
    {
        RenderedImage rendered = RenderImage(matrix, options, cancellation);
        cancellation.Check();
        byte[] png = PngCodec.EncodeRgba8888(rendered.Width, rendered.Height, rendered.RgbaBytes);
        cancellation.Check();
        return png;
    }

    public static (double Vmin, double Vmax)? AutomaticScale(Matrix matrix)
        => AutomaticScale(matrix, CancellationCheckpoint.None);

    public static (double Vmin, double Vmax)? AutomaticScale(
        Matrix matrix,
        CancellationCheckpoint cancellation)
    {
        MatrixStatistics? stats = Statistics(matrix, cancellation);
        return stats is null ? null : AutomaticScale(stats);
    }

    public static (double Vmin, double Vmax) AutomaticScale(MatrixStatistics statistics)
        => (statistics.Min, statistics.Max);

    public static byte[] Colorize(
        Matrix matrix,
        PaletteName palette,
        double? vmin,
        double? vmax,
        bool invert,
        bool transparentMissingValues = false)
        => Colorize(matrix, palette, vmin, vmax, invert, transparentMissingValues, CancellationCheckpoint.None);

    public static byte[] Colorize(
        Matrix matrix,
        PaletteName palette,
        double? vmin,
        double? vmax,
        bool invert,
        bool transparentMissingValues,
        CancellationCheckpoint cancellation)
    {
        (double Vmin, double Vmax)? auto = (vmin is null || vmax is null)
            ? AutomaticScale(matrix, cancellation)
            : null;
        double lo = vmin ?? auto?.Vmin ?? 0.0;
        double hi = vmax ?? auto?.Vmax ?? 1.0;
        bool hasSpan = double.IsFinite(lo) && double.IsFinite(hi) && hi > lo;

        cancellation.Check();
        PaletteLookup lookup = PaletteStore.Shared.Lookup(palette);
        int count = matrix.Width * matrix.Height;
        byte[] rgba = new byte[count * 4];
        double span = hi - lo;
        float[] values = matrix.Values;
        int safeCount = Math.Min(values.Length, count);

        for (int idx = 0; idx < safeCount; idx++)
        {
            if (idx % 4_096 == 0)
            {
                cancellation.Check();
            }
            float value = values[idx];
            int baseIdx = idx * 4;
            if (!float.IsFinite(value) && transparentMissingValues)
            {
                rgba[baseIdx] = 0;
                rgba[baseIdx + 1] = 0;
                rgba[baseIdx + 2] = 0;
                rgba[baseIdx + 3] = 0;
                continue;
            }

            double scaled = float.IsFinite(value)
                ? (hasSpan ? (value - lo) / span : 0.5)
                : 0.0;
            scaled = Math.Min(1.0, Math.Max(0.0, scaled));
            if (invert) scaled = 1.0 - scaled;

            (double r, double g, double b) = lookup.ColorAt(scaled);
            rgba[baseIdx] = ClampByte(r);
            rgba[baseIdx + 1] = ClampByte(g);
            rgba[baseIdx + 2] = ClampByte(b);
            rgba[baseIdx + 3] = 255;
        }

        cancellation.Check();
        return rgba;
    }

    private static byte ClampByte(double unit)
    {
        double rounded = Math.Round(unit * 255.0, MidpointRounding.AwayFromZero);
        if (rounded <= 0.0) return 0;
        if (rounded >= 255.0) return 255;
        return (byte)rounded;
    }

    private static Matrix LineMeanSubtract(Matrix matrix, CancellationCheckpoint cancellation)
    {
        Matrix output = matrix.Clone();
        int width = matrix.Width;
        int height = matrix.Height;

        for (int y = 0; y < height; y++)
        {
            cancellation.Check();
            double sum = 0.0;
            double count = 0.0;
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                float value = matrix[x, y];
                if (float.IsFinite(value))
                {
                    sum += value;
                    count += 1.0;
                }
            }
            if (count <= 0.0) continue;
            float mean = (float)(sum / count);
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                output[x, y] = matrix[x, y] - mean;
            }
        }
        return output;
    }

    private static Matrix LineLinearFit(Matrix matrix, CancellationCheckpoint cancellation)
    {
        Matrix output = matrix.Clone();
        int width = matrix.Width;
        int height = matrix.Height;

        for (int y = 0; y < height; y++)
        {
            cancellation.Check();
            double valid = 0.0;
            double sx = 0.0;
            double sy = 0.0;
            double sxx = 0.0;
            double sxy = 0.0;
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                float value = matrix[x, y];
                if (float.IsFinite(value))
                {
                    double dx = x;
                    double dy = value;
                    valid += 1.0;
                    sx += dx;
                    sy += dy;
                    sxx += dx * dx;
                    sxy += dx * dy;
                }
            }
            if (valid < 2.0) continue;
            double denominator = valid * sxx - sx * sx;
            double slope = Math.Abs(denominator) < NumericalConstants.DoubleUlpOfOne
                ? 0.0
                : (valid * sxy - sx * sy) / denominator;
            double intercept = (sy - slope * sx) / valid;
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                output[x, y] = (float)((double)matrix[x, y] - (slope * (double)x + intercept));
            }
        }
        return output;
    }

    private static Matrix LineSlopeSubtract(Matrix matrix, CancellationCheckpoint cancellation)
    {
        Matrix output = matrix.Clone();
        int width = matrix.Width;
        int height = matrix.Height;

        for (int y = 0; y < height; y++)
        {
            cancellation.Check();
            double valid = 0.0;
            double sx = 0.0;
            double sy = 0.0;
            double sxx = 0.0;
            double sxy = 0.0;
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                float value = matrix[x, y];
                if (float.IsFinite(value))
                {
                    double dx = x;
                    double dy = value;
                    valid += 1.0;
                    sx += dx;
                    sy += dy;
                    sxx += dx * dx;
                    sxy += dx * dy;
                }
            }
            if (valid < 2.0) continue;
            double denominator = valid * sxx - sx * sx;
            double slope = Math.Abs(denominator) < NumericalConstants.DoubleUlpOfOne
                ? 0.0
                : (valid * sxy - sx * sy) / denominator;
            double meanX = sx / valid;
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                output[x, y] = matrix[x, y] - (float)(slope * ((double)x - meanX));
            }
        }
        return output;
    }

    private static Matrix LineDifferentiate(Matrix matrix, CancellationCheckpoint cancellation)
    {
        Matrix output = matrix.Clone();
        int width = matrix.Width;
        int height = matrix.Height;

        for (int y = 0; y < height; y++)
        {
            cancellation.Check();
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                float current = matrix[x, y];
                if (!float.IsFinite(current))
                {
                    output[x, y] = float.NaN;
                    continue;
                }
                float left = x > 0 ? matrix[x - 1, y] : float.NaN;
                float right = x + 1 < width ? matrix[x + 1, y] : float.NaN;
                if (float.IsFinite(left) && float.IsFinite(right))
                {
                    output[x, y] = (right - left) / 2.0f;
                }
                else if (float.IsFinite(right))
                {
                    output[x, y] = right - current;
                }
                else if (float.IsFinite(left))
                {
                    output[x, y] = current - left;
                }
                else
                {
                    output[x, y] = 0.0f;
                }
            }
        }
        return output;
    }

    private static Matrix PlaneLinearFit(Matrix matrix, CancellationCheckpoint cancellation)
    {
        int width = matrix.Width;
        int height = matrix.Height;
        double xScale = Math.Max(1, width - 1);
        double yScale = Math.Max(1, height - 1);

        double? referenceHeight = null;
        double count = 0.0;
        double sumX = 0.0;
        double sumY = 0.0;
        double sumZ = 0.0;

        for (int y = 0; y < height; y++)
        {
            cancellation.Check();
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                float value = matrix[x, y];
                if (!float.IsFinite(value)) continue;
                double z = value;
                referenceHeight ??= z;
                count += 1.0;
                sumX += x / xScale;
                sumY += y / yScale;
                sumZ += z - referenceHeight.Value;
            }
        }

        if (count < 3.0 || referenceHeight is null)
        {
            return matrix.Clone();
        }

        double refH = referenceHeight.Value;
        double meanX = sumX / count;
        double meanY = sumY / count;
        double meanZ = sumZ / count;

        double xx = 0.0;
        double xy = 0.0;
        double yy = 0.0;
        double xz = 0.0;
        double yz = 0.0;

        for (int y = 0; y < height; y++)
        {
            cancellation.Check();
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                float value = matrix[x, y];
                if (!float.IsFinite(value)) continue;
                double dx = x / xScale - meanX;
                double dy = y / yScale - meanY;
                double dz = ((double)value - refH) - meanZ;
                xx += dx * dx;
                xy += dx * dy;
                yy += dy * dy;
                xz += dx * dz;
                yz += dy * dz;
            }
        }

        double determinant = xx * yy - xy * xy;
        if (!(xx > 0.0 && yy > 0.0 && determinant > 64.0 * NumericalConstants.DoubleUlpOfOne * xx * yy))
        {
            return matrix.Clone();
        }

        double slopeX = (xz * yy - yz * xy) / determinant;
        double slopeY = (yz * xx - xz * xy) / determinant;

        Matrix output = matrix.Clone();
        for (int y = 0; y < height; y++)
        {
            cancellation.Check();
            for (int x = 0; x < width; x++)
            {
                if (x % 4_096 == 0)
                {
                    cancellation.Check();
                }
                float value = matrix[x, y];
                if (!float.IsFinite(value)) continue;
                double fittedOffset = meanZ
                    + slopeX * (x / xScale - meanX)
                    + slopeY * (y / yScale - meanY);
                output[x, y] = (float)(((double)value - refH) - fittedOffset);
            }
        }

        return output;
    }

    private static double Percentile(List<float> sorted, double p)
    {
        if (sorted.Count == 0) return 0.0;
        if (sorted.Count == 1) return sorted[0];
        double pos = (p / 100.0) * (sorted.Count - 1);
        int lo = (int)Math.Floor(pos);
        int hi = (int)Math.Ceiling(pos);
        if (lo == hi) return sorted[lo];
        double t = pos - lo;
        return (double)sorted[lo] * (1.0 - t) + (double)sorted[hi] * t;
    }

    private static Matrix DownsampleMatrix(
        Matrix matrix,
        int maxSide,
        CancellationCheckpoint cancellation)
    {
        int clampedMax = Math.Max(1, maxSide);
        int longest = Math.Max(matrix.Width, matrix.Height);
        if (longest <= clampedMax) return matrix;

        double scale = (double)clampedMax / longest;
        int targetWidth = Math.Max(1, (int)Math.Round(matrix.Width * scale, MidpointRounding.AwayFromZero));
        int targetHeight = Math.Max(1, (int)Math.Round(matrix.Height * scale, MidpointRounding.AwayFromZero));
        float[] output = new float[targetWidth * targetHeight];
        Array.Fill(output, float.NaN);

        for (int dy = 0; dy < targetHeight; dy++)
        {
            cancellation.Check();
            int srcYStart = (dy * matrix.Height) / targetHeight;
            int srcYEnd = Math.Max(srcYStart + 1, ((dy + 1) * matrix.Height) / targetHeight);
            int yLimit = Math.Min(matrix.Height, srcYEnd);

            for (int dx = 0; dx < targetWidth; dx++)
            {
                int srcXStart = (dx * matrix.Width) / targetWidth;
                int srcXEnd = Math.Max(srcXStart + 1, ((dx + 1) * matrix.Width) / targetWidth);
                int xLimit = Math.Min(matrix.Width, srcXEnd);

                double sum = 0.0;
                int count = 0;
                for (int sy = srcYStart; sy < yLimit; sy++)
                {
                    int rowOffset = sy * matrix.Width;
                    for (int sx = srcXStart; sx < xLimit; sx++)
                    {
                        float v = matrix.Values[rowOffset + sx];
                        if (float.IsFinite(v))
                        {
                            sum += v;
                            count++;
                        }
                    }
                }
                if (count > 0)
                {
                    output[dy * targetWidth + dx] = (float)(sum / count);
                }
            }
        }

        cancellation.Check();
        return new Matrix(targetWidth, targetHeight, output);
    }

    private static RenderedImage ResizeRgbaImage(
        byte[] srcRgba,
        int srcWidth,
        int srcHeight,
        int maxSide,
        CancellationCheckpoint cancellation)
    {
        cancellation.Check();
        int clampedMax = Math.Max(1, maxSide);
        int longest = Math.Max(srcWidth, srcHeight);
        if (longest <= clampedMax)
        {
            return new RenderedImage(srcWidth, srcHeight, srcRgba);
        }

        double scale = (double)clampedMax / longest;
        int targetWidth = Math.Max(1, (int)Math.Round(srcWidth * scale, MidpointRounding.AwayFromZero));
        int targetHeight = Math.Max(1, (int)Math.Round(srcHeight * scale, MidpointRounding.AwayFromZero));
        byte[] dst = new byte[targetWidth * targetHeight * 4];

        // Premultiplied alpha-aware area/bilinear resampling in sRGB matching CGContext high quality resize
        double xRatio = (double)srcWidth / targetWidth;
        double yRatio = (double)srcHeight / targetHeight;

        for (int dy = 0; dy < targetHeight; dy++)
        {
            cancellation.Check();
            double sy0 = dy * yRatio;
            double sy1 = (dy + 1) * yRatio;
            int iy0 = Math.Max(0, (int)Math.Floor(sy0));
            int iy1 = Math.Min(srcHeight - 1, (int)Math.Ceiling(sy1) - 1);
            if (iy1 < iy0) iy1 = iy0;

            for (int dx = 0; dx < targetWidth; dx++)
            {
                double sx0 = dx * xRatio;
                double sx1 = (dx + 1) * xRatio;
                int ix0 = Math.Max(0, (int)Math.Floor(sx0));
                int ix1 = Math.Min(srcWidth - 1, (int)Math.Ceiling(sx1) - 1);
                if (ix1 < ix0) ix1 = ix0;

                double rAcc = 0, gAcc = 0, bAcc = 0, aAcc = 0, wAcc = 0;
                for (int sy = iy0; sy <= iy1; sy++)
                {
                    double wy = Math.Min(sy + 1.0, sy1) - Math.Max((double)sy, sy0);
                    if (wy <= 0) wy = 1.0;
                    int rowBase = sy * srcWidth * 4;
                    for (int sx = ix0; sx <= ix1; sx++)
                    {
                        double wx = Math.Min(sx + 1.0, sx1) - Math.Max((double)sx, sx0);
                        if (wx <= 0) wx = 1.0;
                        double w = wx * wy;
                        int p = rowBase + sx * 4;
                        double a = srcRgba[p + 3] / 255.0;
                        rAcc += srcRgba[p] * a * w;
                        gAcc += srcRgba[p + 1] * a * w;
                        bAcc += srcRgba[p + 2] * a * w;
                        aAcc += srcRgba[p + 3] * w;
                        wAcc += w;
                    }
                }

                int outIdx = (dy * targetWidth + dx) * 4;
                if (wAcc > 0)
                {
                    double alpha = aAcc / wAcc;
                    if (alpha > 0.5)
                    {
                        double aNorm = alpha / 255.0;
                        dst[outIdx] = ClampRawByte((rAcc / wAcc) / aNorm);
                        dst[outIdx + 1] = ClampRawByte((gAcc / wAcc) / aNorm);
                        dst[outIdx + 2] = ClampRawByte((bAcc / wAcc) / aNorm);
                        dst[outIdx + 3] = ClampRawByte(alpha);
                    }
                }
            }
        }

        cancellation.Check();
        return new RenderedImage(targetWidth, targetHeight, dst);
    }

    private static byte ClampRawByte(double value)
    {
        double rounded = Math.Round(value, MidpointRounding.AwayFromZero);
        if (rounded <= 0.0) return 0;
        if (rounded >= 255.0) return 255;
        return (byte)rounded;
    }
}
