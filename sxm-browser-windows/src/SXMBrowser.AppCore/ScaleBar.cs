using System;
using System.Collections.Generic;
using System.Globalization;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public sealed record ScaleBar(
    double PhysicalLengthMeters,
    double ScreenLengthPoints,
    string Label)
{
    public const double TargetVisibleFraction = 0.25;
    public const double PreferredMinimumScreenLengthPoints = 48.0;
    public const double MaximumScreenLengthPoints = 180.0;

    private readonly record struct Candidate(double PhysicalLength, double ScreenLength);

    private static readonly (int Exponent, string Symbol)[] SiPrefixes =
    [
        (30, "Q"), (27, "R"), (24, "Y"), (21, "Z"), (18, "E"), (15, "P"),
        (12, "T"), (9, "G"), (6, "M"), (3, "k"), (0, ""),
        (-3, "m"), (-6, "\u00B5"), (-9, "n"), (-12, "p"), (-15, "f"),
        (-18, "a"), (-21, "z"), (-24, "y"), (-27, "r"), (-30, "q")
    ];

    public static ScaleBar? Resolve(
        double scanRangeX,
        int sourcePixelWidth,
        ViewerTransform viewerTransform,
        double availableWidth)
    {
        if (!double.IsFinite(scanRangeX) || scanRangeX <= 0.0
            || sourcePixelWidth <= 0
            || !viewerTransform.ImageSize.IsUsable
            || !viewerTransform.ViewportSize.IsUsable
            || !double.IsFinite(viewerTransform.Scale) || viewerTransform.Scale <= 0.0
            || !double.IsFinite(availableWidth) || availableWidth <= 0.0)
        {
            return null;
        }

        double scaledImageWidth = sourcePixelWidth * viewerTransform.Scale;
        if (!double.IsFinite(scaledImageWidth) || scaledImageWidth <= 0.0) return null;

        double visibleImageSpan = Math.Min(
            scaledImageWidth,
            Math.Min(availableWidth, viewerTransform.ViewportSize.Width));
        if (!double.IsFinite(visibleImageSpan) || visibleImageSpan <= 0.0) return null;

        double pointsPerMeter = scaledImageWidth / scanRangeX;
        if (!double.IsFinite(pointsPerMeter) || pointsPerMeter <= 0.0) return null;

        double maximumLength = Math.Min(MaximumScreenLengthPoints, visibleImageSpan);
        double preferredMinimum = visibleImageSpan >= PreferredMinimumScreenLengthPoints
            ? PreferredMinimumScreenLengthPoints
            : 0.0;
        double targetLength = Math.Min(
            maximumLength,
            Math.Max(preferredMinimum, visibleImageSpan * TargetVisibleFraction));
        double targetPhysicalLength = targetLength / pointsPerMeter;
        if (!double.IsFinite(targetPhysicalLength) || targetPhysicalLength <= 0.0) return null;

        var candidates = new List<Candidate>();
        foreach (double physicalLength in NiceLengths(targetPhysicalLength))
        {
            double screenLength = physicalLength * pointsPerMeter;
            if (double.IsFinite(screenLength)
                && screenLength > 0.0
                && screenLength <= maximumLength + ComparisonTolerance(maximumLength))
            {
                candidates.Add(new Candidate(physicalLength, screenLength));
            }
        }
        if (candidates.Count == 0) return null;

        var preferredCandidates = new List<Candidate>();
        double minTol = ComparisonTolerance(preferredMinimum);
        foreach (Candidate c in candidates)
        {
            if (c.ScreenLength + minTol >= preferredMinimum)
            {
                preferredCandidates.Add(c);
            }
        }

        List<Candidate> eligible = preferredCandidates.Count == 0 ? candidates : preferredCandidates;
        Candidate selected = eligible[0];
        for (int i = 1; i < eligible.Count; i++)
        {
            if (IsPreferred(eligible[i], selected, targetLength))
            {
                selected = eligible[i];
            }
        }

        return new ScaleBar(selected.PhysicalLength, selected.ScreenLength, SiLabel(selected.PhysicalLength));
    }

    private static List<double> NiceLengths(double target)
    {
        double logarithm = Math.Log10(target);
        if (!double.IsFinite(logarithm)) return [];
        double centerExponent = Math.Floor(logarithm);
        var candidates = new List<double>(27);

        for (int offset = -4; offset <= 4; offset++)
        {
            double power = Math.Pow(10.0, centerExponent + offset);
            if (!double.IsFinite(power) || power <= 0.0) continue;
            foreach (double multiplier in new[] { 1.0, 2.0, 5.0 })
            {
                double length = multiplier * power;
                if (double.IsFinite(length) && length > 0.0)
                {
                    candidates.Add(length);
                }
            }
        }
        return candidates;
    }

    private static bool IsPreferred(Candidate lhs, Candidate rhs, double targetScreenLength)
    {
        double lhsDistance = Math.Abs(lhs.ScreenLength - targetScreenLength);
        double rhsDistance = Math.Abs(rhs.ScreenLength - targetScreenLength);
        double tolerance = ComparisonTolerance(targetScreenLength);
        if (Math.Abs(lhsDistance - rhsDistance) <= tolerance)
        {
            return lhs.PhysicalLength > rhs.PhysicalLength;
        }
        return lhsDistance < rhsDistance;
    }

    private static double ComparisonTolerance(double value) =>
        Math.Max(1.0, Math.Abs(value)) * NumericalConstants.DoubleUlpOfOne * 32.0;

    private static string SiLabel(double meters)
    {
        double logarithm = Math.Log10(meters);
        int engineeringExponent = (int)Math.Floor(logarithm / 3.0) * 3;
        (int Exponent, string Symbol) prefix = SiPrefixes[^1];
        foreach (var entry in SiPrefixes)
        {
            if (entry.Exponent <= engineeringExponent)
            {
                prefix = entry;
                break;
            }
        }

        double divisor = Math.Pow(10.0, prefix.Exponent);
        double value = meters / divisor;
        double rounded = Math.Round(value, MidpointRounding.AwayFromZero);
        double tolerance = Math.Max(1.0, Math.Abs(value)) * NumericalConstants.DoubleUlpOfOne * 64.0;
        string valueText;
        if (double.IsFinite(rounded)
            && Math.Abs(value - rounded) <= tolerance
            && rounded >= int.MinValue
            && rounded <= int.MaxValue)
        {
            valueText = ((int)rounded).ToString(CultureInfo.InvariantCulture);
        }
        else
        {
            valueText = value.ToString("G3", CultureInfo.InvariantCulture);
        }

        return $"{valueText} {prefix.Symbol}m";
    }
}
