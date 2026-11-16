using System;
using System.Collections.Generic;
using System.Globalization;

namespace SXMBrowser.AppCore;

public sealed record ScientificAxisTick(
    double Value,
    double Fraction,
    string Label);

public static class ScientificPlotTicks
{
    private static readonly double[] NiceMantissas = [1.0, 2.0, 5.0];

    public static IReadOnlyList<ScientificAxisTick> Ticks(
        double min,
        double max,
        int targetCount = 5)
    {
        if (!double.IsFinite(min) || !double.IsFinite(max) || max < min)
        {
            return Array.Empty<ScientificAxisTick>();
        }

        int desiredCount = Math.Max(2, Math.Min(12, targetCount));
        double span = max - min;
        double scaleFloor = Math.Max(1.0, Math.Max(Math.Abs(min), Math.Abs(max)));
        if (span <= scaleFloor * 1e-12)
        {
            return [new ScientificAxisTick(min, 0.5, FormatTickValue(min, step: null))];
        }

        double idealStep = span / (desiredCount - 1);
        int baseExponent = (int)Math.Floor(Math.Log10(idealStep));
        double? bestStep = null;
        List<double> bestValues = [];
        double bestScore = double.MaxValue;

        for (int expOffset = -1; expOffset <= 2; expOffset++)
        {
            double power = Math.Pow(10.0, baseExponent + expOffset);
            foreach (double mantissa in NiceMantissas)
            {
                double candidateStep = mantissa * power;
                if (!double.IsFinite(candidateStep) || candidateStep <= 0.0) continue;

                List<double> values = GenerateValues(min, max, candidateStep);
                if (values.Count == 0) continue;

                double score = Math.Abs((double)(values.Count - desiredCount));
                if (values.Count < 2)
                {
                    score += 100.0;
                }
                else if (values.Count > desiredCount + 2)
                {
                    score += 20.0;
                }
                score += values.Count * 0.01;

                if (score < bestScore)
                {
                    bestScore = score;
                    bestStep = candidateStep;
                    bestValues = values;
                }
            }
        }

        if (bestStep is not { } step || bestValues.Count == 0)
        {
            return
            [
                new ScientificAxisTick(min, 0.0, FormatTickValue(min, span)),
                new ScientificAxisTick(max, 1.0, FormatTickValue(max, span))
            ];
        }

        var result = new List<ScientificAxisTick>(bestValues.Count);
        foreach (double rawValue in bestValues)
        {
            double snapped = Math.Abs(rawValue) < step * 1e-6 ? 0.0 : rawValue;
            double fraction = Math.Min(1.0, Math.Max(0.0, (snapped - min) / span));
            result.Add(new ScientificAxisTick(snapped, fraction, FormatTickValue(snapped, step)));
        }
        return result;
    }

    public static string FormatTickValue(double value, double? step)
    {
        if (!double.IsFinite(value)) return "\u2014";
        double zeroThreshold = Math.Max(1e-30, (step ?? Math.Abs(value)) * 1e-6);
        if (value == 0.0 || Math.Abs(value) < zeroThreshold)
        {
            return "0";
        }

        double magnitude = Math.Abs(value);
        if (magnitude >= 1e4 || magnitude < 1e-3)
        {
            return FormatScientific(value, step);
        }
        return FormatFixed(value, step);
    }

    private static List<double> GenerateValues(double min, double max, double step)
    {
        double span = max - min;
        double epsilon = span * 1e-9;
        double startIndexDouble = Math.Ceiling((min - epsilon) / step);
        double endIndexDouble = Math.Floor((max + epsilon) / step);
        if (!double.IsFinite(startIndexDouble)
            || !double.IsFinite(endIndexDouble)
            || Math.Abs(startIndexDouble) >= 1e9
            || Math.Abs(endIndexDouble) >= 1e9)
        {
            return [];
        }

        int startIndex = (int)startIndexDouble;
        int endIndex = (int)endIndexDouble;
        if (startIndex > endIndex) return [];
        int count = endIndex - startIndex + 1;
        if (count > 32) return [];

        var values = new List<double>(count);
        for (int idx = startIndex; idx <= endIndex; idx++)
        {
            double v = idx * step;
            if (v >= min - epsilon && v <= max + epsilon)
            {
                values.Add(v);
            }
        }
        return values;
    }

    private static string FormatFixed(double value, double? step)
    {
        int decimalPlaces = step is { } s && s > 0.0 && double.IsFinite(s)
            ? Math.Min(6, Math.Max(0, -(int)Math.Floor(Math.Log10(s))))
            : 3;

        string formatted = value.ToString($"F{decimalPlaces}", CultureInfo.InvariantCulture);
        string trimmed = TrimTrailingDecimalZeros(formatted);
        return trimmed == "-0" ? "0" : trimmed;
    }

    private static string FormatScientific(double value, double? step)
    {
        string sign = value < 0.0 ? "-" : string.Empty;
        double magnitude = Math.Abs(value);
        int exponent = (int)Math.Floor(Math.Log10(magnitude));
        double scaled = magnitude / Math.Pow(10.0, exponent);

        int fractionalDigits = 2;
        if (step is { } s && s > 0.0 && double.IsFinite(s))
        {
            int stepExp = (int)Math.Floor(Math.Log10(s));
            fractionalDigits = Math.Min(4, Math.Max(0, exponent - stepExp));
        }

        string mantissaString = scaled.ToString($"F{fractionalDigits}", CultureInfo.InvariantCulture);
        int adjustedExponent = exponent;
        if (double.TryParse(mantissaString, NumberStyles.Float, CultureInfo.InvariantCulture, out double rounded)
            && rounded >= 10.0)
        {
            adjustedExponent += 1;
            mantissaString = (rounded / 10.0).ToString($"F{fractionalDigits}", CultureInfo.InvariantCulture);
        }

        mantissaString = TrimTrailingDecimalZeros(mantissaString);
        return $"{sign}{mantissaString}e{adjustedExponent}";
    }

    private static string TrimTrailingDecimalZeros(string text)
    {
        if (!text.Contains('.')) return text;
        int end = text.Length;
        while (end > 0 && text[end - 1] == '0') end--;
        if (end > 0 && text[end - 1] == '.') end--;
        return text[..end];
    }
}
