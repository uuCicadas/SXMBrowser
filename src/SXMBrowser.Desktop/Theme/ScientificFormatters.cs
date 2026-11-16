using System;
using System.Globalization;
using SXMBrowser.AppCore;
using SXMBrowser.Core;

namespace SXMBrowser.Desktop.Theme;

public static class ScientificFormatters
{
    private static readonly (int Exponent, string Symbol)[] SiPrefixes =
    [
        (9, "G"),
        (6, "M"),
        (3, "k"),
        (0, ""),
        (-3, "m"),
        (-6, "\u00B5"),
        (-9, "n"),
        (-12, "p"),
        (-15, "f")
    ];

    public static string FormatSi(double value, string unit = "", int sigFigs = 4)
    {
        if (!double.IsFinite(value)) return "\u2014";
        if (value == 0.0)
        {
            return string.IsNullOrWhiteSpace(unit) ? "0" : $"0 {unit.Trim()}";
        }

        double abs = Math.Abs(value);
        int exp = (int)Math.Floor(Math.Log10(abs) / 3.0) * 3;
        (int Exponent, string Symbol) chosen = SiPrefixes[^1];
        if (exp >= SiPrefixes[0].Exponent)
        {
            chosen = SiPrefixes[0];
        }
        else
        {
            foreach (var p in SiPrefixes)
            {
                if (exp >= p.Exponent)
                {
                    chosen = p;
                    break;
                }
            }
        }

        double scaled = value / Math.Pow(10.0, chosen.Exponent);
        string numText = scaled.ToString($"G{Math.Max(2, sigFigs)}", CultureInfo.InvariantCulture);
        string trimmedUnit = unit.Trim();
        string fullUnit = chosen.Symbol + trimmedUnit;
        return string.IsNullOrEmpty(fullUnit) ? numText : $"{numText} {fullUnit}";
    }

    public static string FormatCompactNumber(double value)
    {
        if (!double.IsFinite(value)) return "\u2014";
        if (value == 0.0) return "0";
        double abs = Math.Abs(value);
        if (abs >= 1e4 || abs < 1e-3)
        {
            return value.ToString("0.###e+0", CultureInfo.InvariantCulture);
        }
        return value.ToString("0.###", CultureInfo.InvariantCulture);
    }

    public static string FormatScanFootprint(InspectorCoordinatePair? rangeMeters)
    {
        if (rangeMeters is not { } r) return "\u2014";
        return $"{FormatSi(r.X, "m", 3)} \u00D7 {FormatSi(r.Y, "m", 3)}";
    }

    public static string FormatOffset(InspectorCoordinatePair? offsetMeters)
    {
        if (offsetMeters is not { } o) return "\u2014";
        return $"({FormatSi(o.X, "m", 3)}, {FormatSi(o.Y, "m", 3)})";
    }

    public static string FormatDuration(double? seconds)
    {
        if (seconds is not double s || !double.IsFinite(s) || s < 0.0) return "\u2014";
        if (s < 60.0) return $"{s.ToString("0.#", CultureInfo.InvariantCulture)} s";
        int totalSeconds = (int)Math.Round(s, MidpointRounding.AwayFromZero);
        int mins = totalSeconds / 60;
        int rem = totalSeconds % 60;
        if (mins < 60) return $"{mins}m {rem:D2}s";
        int hours = mins / 60;
        mins %= 60;
        return $"{hours}h {mins:D2}m";
    }

    public static string FormatTemperature(double? kelvin)
    {
        if (kelvin is not double k || !double.IsFinite(k)) return "\u2014";
        return $"{k.ToString("G4", CultureInfo.InvariantCulture)} K";
    }

    public static bool TryParseScaleInput(string text, string channelUnit, out double value)
    {
        value = 0.0;
        if (string.IsNullOrWhiteSpace(text)) return false;

        string candidate = text.Trim();
        string trimmedUnit = channelUnit.Trim();
        if (!string.IsNullOrEmpty(trimmedUnit)
            && candidate.EndsWith(trimmedUnit, StringComparison.OrdinalIgnoreCase)
            && candidate.Length > trimmedUnit.Length)
        {
            string withoutUnit = candidate[..^trimmedUnit.Length].Trim();
            if (SpectroscopyParser.ParseEngineeringDouble(withoutUnit) is double parsedWithoutUnit
                && double.IsFinite(parsedWithoutUnit))
            {
                value = parsedWithoutUnit;
                return true;
            }
        }

        if (SpectroscopyParser.ParseEngineeringDouble(candidate) is double parsed
            && double.IsFinite(parsed))
        {
            value = parsed;
            return true;
        }

        return false;
    }
}
