using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public readonly record struct InspectorCoordinatePair
{
    public double X { get; }
    public double Y { get; }

    private InspectorCoordinatePair(double x, double y)
    {
        X = x;
        Y = y;
    }

    public static InspectorCoordinatePair? TryCreate(double x, double y)
        => double.IsFinite(x) && double.IsFinite(y) ? new InspectorCoordinatePair(x, y) : null;
}

public sealed record InspectorHeaderEntry(string Key, string Value)
{
    public string Id => Key;
}

public readonly record struct FrequencyShiftBounds
{
    public double Min { get; }
    public double Max { get; }

    private FrequencyShiftBounds(double min, double max)
    {
        Min = min;
        Max = max;
    }

    public static FrequencyShiftBounds? TryCreate(double min, double max)
        => double.IsFinite(min) && double.IsFinite(max) && min <= max
            ? new FrequencyShiftBounds(min, max)
            : null;

    public static FrequencyShiftBounds? From(Matrix matrix)
        => From(matrix, CancellationCheckpoint.None);

    public static FrequencyShiftBounds? From(Matrix matrix, CancellationCheckpoint cancellation)
    {
        cancellation.Check();
        double minValue = double.PositiveInfinity;
        double maxValue = double.NegativeInfinity;
        float[] values = matrix.Values;
        for (int index = 0; index < values.Length; index++)
        {
            if (index % 4_096 == 0)
            {
                cancellation.Check();
            }
            float sample = values[index];
            if (!float.IsFinite(sample)) continue;
            double value = sample;
            if (value < minValue) minValue = value;
            if (value > maxValue) maxValue = value;
        }
        if (!double.IsFinite(minValue) || !double.IsFinite(maxValue))
        {
            return null;
        }
        return TryCreate(minValue, maxValue);
    }
}

public readonly record struct FrequencyShiftBoundsKey
{
    public Guid DatasetRevision { get; }
    public Guid FileId { get; }
    public string StandardizedPath { get; }
    public DateTimeOffset ModifiedTime { get; }
    public string Channel { get; }
    public ScanDirection Direction { get; }

    public FrequencyShiftBoundsKey(
        Guid datasetRevision,
        Guid fileId,
        string path,
        DateTimeOffset modifiedTime,
        string channel,
        ScanDirection direction)
    {
        DatasetRevision = datasetRevision;
        FileId = fileId;
        StandardizedPath = Path.GetFullPath(path);
        ModifiedTime = modifiedTime;
        Channel = channel;
        Direction = direction;
    }
}

public sealed class InspectorMetadataPresentation
{
    private readonly record struct ZControllerRow(
        string? Name,
        bool? IsActive,
        double? SetpointValue,
        string? SetpointUnit,
        string? SetpointRawText);

    public DateTimeOffset? RecordedTime { get; }
    public DateTimeOffset ModifiedTime { get; }
    public int PixelWidth { get; }
    public int PixelHeight { get; }
    public InspectorCoordinatePair? ScanRangeMeters { get; }
    public InspectorCoordinatePair? ScanOffsetMeters { get; }
    public double? ScanAngleDegrees { get; }
    public string ChannelName { get; }
    public string ChannelUnit { get; }
    public bool IsFrequencyShiftChannel { get; }
    public double? SampleBiasVolts { get; }
    public string? FeedbackControllerName { get; }
    public bool? IsFeedbackActive { get; }
    public double? SetpointValue { get; }
    public string? SetpointUnit { get; }
    public string? SetpointRawText { get; }
    public double? TemperatureKelvin { get; }
    public double? AcquisitionSeconds { get; }
    public double? ScanSpeedMetersPerSecond { get; }
    public string? Comment { get; }
    public IReadOnlyList<InspectorHeaderEntry> RawHeaderEntries { get; }

    public InspectorMetadataPresentation(SXMMetadata metadata, string selectedChannelName)
    {
        RecordedTime = metadata.RecordedTime;
        ModifiedTime = metadata.ModifiedTime;
        PixelWidth = Math.Max(0, metadata.Pixels.Width);
        PixelHeight = Math.Max(0, metadata.Pixels.Height);

        ScanRangeMeters = metadata.ScanRange is { } range && range.X > 0.0 && range.Y > 0.0
            ? InspectorCoordinatePair.TryCreate(range.X, range.Y)
            : null;
        ScanOffsetMeters = metadata.ScanOffset is { } offset
            ? InspectorCoordinatePair.TryCreate(offset.X, offset.Y)
            : null;
        ScanAngleDegrees = metadata.ScanAngle is { } angle && double.IsFinite(angle)
            ? angle
            : null;

        SXMChannel? selectedChannel = metadata.Channels.FirstOrDefault(
            c => string.Equals(c.Name, selectedChannelName, StringComparison.Ordinal));
        ChannelName = selectedChannel?.Name ?? selectedChannelName;
        ChannelUnit = selectedChannel?.Unit ?? string.Empty;
        IsFrequencyShiftChannel = SXMChannelRules.IsFrequencyShiftChannel(ChannelName);

        IReadOnlyDictionary<string, string> header = metadata.Header;
        if (HeaderValue(header, ["BIAS", "Bias>Bias (V)", "Bias>Bias"]) is { } rawBias
            && SpectroscopyParser.ParseEngineeringDouble(rawBias) is { } parsedBias
            && double.IsFinite(parsedBias))
        {
            SampleBiasVolts = parsedBias;
        }

        ZControllerRow zRow = ParseZControllerRow(HeaderValue(header, ["Z-CONTROLLER"]));
        FeedbackControllerName = HeaderValue(header, ["Z-Controller>Controller name"]) ?? zRow.Name;

        if (HeaderValue(header, ["Z-Controller>Controller status"]) is { } statusText
            && ParseBooleanStatus(statusText) is { } parsedStatus)
        {
            IsFeedbackActive = parsedStatus;
        }
        else
        {
            IsFeedbackActive = zRow.IsActive;
        }

        string? explicitSetpointText = HeaderValue(header, ["Z-Controller>Setpoint"]);
        string? explicitSetpointUnit = HeaderValue(header, ["Z-Controller>Setpoint unit"]);
        if (explicitSetpointText is not null
            && SpectroscopyParser.ParseEngineeringDouble(explicitSetpointText) is { } parsedSetpoint
            && double.IsFinite(parsedSetpoint))
        {
            SetpointValue = parsedSetpoint;
            SetpointUnit = explicitSetpointUnit ?? zRow.SetpointUnit;
            SetpointRawText = !string.IsNullOrEmpty(SetpointUnit)
                ? $"{explicitSetpointText} {SetpointUnit}"
                : explicitSetpointText;
        }
        else
        {
            SetpointValue = zRow.SetpointValue;
            SetpointUnit = explicitSetpointUnit ?? zRow.SetpointUnit;
            SetpointRawText = zRow.SetpointRawText ?? explicitSetpointText;
        }

        TemperatureKelvin = ParsePositiveFinite(
            header,
            ["Temperature 2>Temperature 2 (K)", "Temperature 1>Temperature 1 (K)", "REC_TEMP"],
            upperBound: 10_000.0);

        AcquisitionSeconds = ParsePositiveFinite(
            header,
            ["ACQ_TIME", "Acquisition time (s)"],
            upperBound: null);

        ScanSpeedMetersPerSecond = ParsePositiveFinite(
            header,
            ["Scan>speed forw. (m/s)", "Scan>Speed forw. (m/s)", "Scan>speed (m/s)"],
            upperBound: null);

        Comment = HeaderValue(header, ["COMMENT", "Comment"]);

        var normalizedEntries = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach ((string rawKey, string rawValue) in header)
        {
            string cleanKey = CleanHeaderKey(rawKey);
            string cleanValue = rawValue.Trim();
            if (cleanKey.Length == 0 || cleanValue.Length == 0) continue;
            if (!normalizedEntries.ContainsKey(cleanKey) || string.Equals(rawKey, cleanKey, StringComparison.Ordinal))
            {
                normalizedEntries[cleanKey] = cleanValue;
            }
        }

        RawHeaderEntries = normalizedEntries
            .Select(kv => new InspectorHeaderEntry(kv.Key, kv.Value))
            .OrderBy(e => e.Key, StringComparer.OrdinalIgnoreCase)
            .ThenBy(e => e.Key, StringComparer.Ordinal)
            .ToArray();
    }

    public IReadOnlyList<InspectorHeaderEntry> FilteredHeaderEntries(string query)
    {
        string trimmed = query.Trim();
        if (trimmed.Length == 0) return RawHeaderEntries;
        return RawHeaderEntries.Where(entry =>
            entry.Key.Contains(trimmed, StringComparison.OrdinalIgnoreCase)
            || entry.Value.Contains(trimmed, StringComparison.OrdinalIgnoreCase))
            .ToArray();
    }

    private static string CleanHeaderKey(string key)
    {
        string trimmed = key.Trim();
        if (trimmed.StartsWith(':') && trimmed.EndsWith(':') && trimmed.Length >= 2)
        {
            trimmed = trimmed[1..^1].Trim();
        }
        return trimmed;
    }

    private static string? HeaderValue(IReadOnlyDictionary<string, string> header, string[] keys)
    {
        foreach (string key in keys)
        {
            if (header.TryGetValue(key, out string? direct))
            {
                string trimmed = direct.Trim();
                if (trimmed.Length > 0) return trimmed;
            }
            if (header.TryGetValue($":{key}:", out string? wrapped))
            {
                string trimmed = wrapped.Trim();
                if (trimmed.Length > 0) return trimmed;
            }
        }
        return null;
    }

    private static double? ParsePositiveFinite(
        IReadOnlyDictionary<string, string> header,
        string[] keys,
        double? upperBound)
    {
        foreach (string key in keys)
        {
            string? text = HeaderValue(header, [key]);
            if (text is null) continue;
            double? parsed = SpectroscopyParser.ParseEngineeringDouble(text);
            if (parsed is null || !double.IsFinite(parsed.Value) || parsed.Value <= 0.0) continue;
            if (upperBound is { } upper && parsed.Value >= upper) continue;
            return parsed.Value;
        }
        return null;
    }

    private static bool? ParseBooleanStatus(string text) => text.Trim().ToLowerInvariant() switch
    {
        "1" or "on" or "true" or "yes" or "enabled" or "active" => true,
        "0" or "off" or "false" or "no" or "disabled" or "inactive" => false,
        _ => null
    };

    private static ZControllerRow ParseZControllerRow(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return default;

        var rows = raw.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(r => r.Trim())
            .Where(r => r.Length > 0)
            .ToList();
        if (rows.Count == 0) return default;

        string? dataRow = rows.FirstOrDefault(row =>
        {
            string[] fields = row.Split('\t').Select(f => f.Trim()).ToArray();
            if (fields.Length < 3) return false;
            bool headerLike = string.Equals(fields[0], "Name", StringComparison.OrdinalIgnoreCase)
                && string.Equals(fields[1], "on", StringComparison.OrdinalIgnoreCase);
            return !headerLike;
        });
        if (dataRow is null) return default;

        string[] dataFields = dataRow.Split('\t').Select(f => f.Trim()).ToArray();
        string? name = dataFields.Length > 0 && dataFields[0].Length > 0 ? dataFields[0] : null;
        bool? isActive = dataFields.Length > 1 ? ParseBooleanStatus(dataFields[1]) : null;
        string? rawSetpoint = dataFields.Length > 2 && dataFields[2].Length > 0 ? dataFields[2] : null;

        double? setpointValue = null;
        string? setpointUnit = null;
        if (rawSetpoint is not null)
        {
            string[] parts = rawSetpoint.Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length > 0
                && SpectroscopyParser.ParseEngineeringDouble(parts[0]) is { } parsed
                && double.IsFinite(parsed))
            {
                setpointValue = parsed;
                if (parts.Length > 1)
                {
                    setpointUnit = parts[1];
                }
            }
        }

        return new ZControllerRow(name, isActive, setpointValue, setpointUnit, rawSetpoint);
    }
}
