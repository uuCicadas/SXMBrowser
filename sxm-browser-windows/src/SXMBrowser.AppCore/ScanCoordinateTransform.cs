using System;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public readonly record struct NormalizedScanCoordinate
{
    public double U { get; }
    public double V { get; }

    private NormalizedScanCoordinate(double u, double v)
    {
        U = u;
        V = v;
    }

    public static NormalizedScanCoordinate? TryCreate(double u, double v)
        => double.IsFinite(u) && double.IsFinite(v) ? new NormalizedScanCoordinate(u, v) : null;
}

public readonly record struct PhysicalScanCoordinate
{
    public double X { get; }
    public double Y { get; }

    private PhysicalScanCoordinate(double x, double y)
    {
        X = x;
        Y = y;
    }

    public static PhysicalScanCoordinate? TryCreate(double x, double y)
        => double.IsFinite(x) && double.IsFinite(y) ? new PhysicalScanCoordinate(x, y) : null;
}

public enum ScanVerticalDirection
{
    Up,
    Down
}

public sealed class ScanCoordinateTransform : IEquatable<ScanCoordinateTransform>
{
    public double RangeX { get; }
    public double RangeY { get; }
    public PhysicalScanCoordinate Offset { get; }
    public double AngleDegrees { get; }
    public ScanVerticalDirection VerticalDirection { get; }

    private readonly double _cosine;
    private readonly double _sine;

    private ScanCoordinateTransform(
        double rangeX,
        double rangeY,
        PhysicalScanCoordinate offset,
        double angleDegrees,
        ScanVerticalDirection verticalDirection,
        double cosine,
        double sine)
    {
        RangeX = rangeX;
        RangeY = rangeY;
        Offset = offset;
        AngleDegrees = angleDegrees;
        VerticalDirection = verticalDirection;
        _cosine = cosine;
        _sine = sine;
    }

    public static ScanCoordinateTransform? TryCreate(
        double rangeX,
        double rangeY,
        double offsetX,
        double offsetY,
        double angleDegrees = 0.0,
        string? scanDirection = null)
    {
        if (!double.IsFinite(rangeX) || !double.IsFinite(rangeY)
            || rangeX <= 0.0 || rangeY <= 0.0
            || !double.IsFinite(angleDegrees))
        {
            return null;
        }
        PhysicalScanCoordinate? offset = PhysicalScanCoordinate.TryCreate(offsetX, offsetY);
        if (offset is null) return null;

        double radians = angleDegrees * Math.PI / 180.0;
        if (!double.IsFinite(radians)) return null;
        double cosine = Math.Cos(radians);
        double sine = Math.Sin(radians);
        if (!double.IsFinite(cosine) || !double.IsFinite(sine)) return null;

        ScanVerticalDirection vertical = SXMChannelRules.IsUpwardScanDirection(scanDirection)
            ? ScanVerticalDirection.Up
            : ScanVerticalDirection.Down;

        return new ScanCoordinateTransform(
            rangeX,
            rangeY,
            offset.Value,
            angleDegrees,
            vertical,
            cosine,
            sine);
    }

    public NormalizedScanCoordinate? NormalizedCoordinate(PhysicalScanCoordinate physical)
    {
        double dx = physical.X - Offset.X;
        double dy = physical.Y - Offset.Y;
        double scanX = _cosine * dx - _sine * dy;
        double scanY = _sine * dx + _cosine * dy;
        double u = 0.5 + scanX / RangeX;
        // SXMParser normalizes both downward and upward scans so row 0 (v = 0)
        // always sits at physical +scanY.
        double v = 0.5 - scanY / RangeY;
        return NormalizedScanCoordinate.TryCreate(u, v);
    }

    public PhysicalScanCoordinate? PhysicalCoordinate(NormalizedScanCoordinate normalized)
    {
        double scanX = (normalized.U - 0.5) * RangeX;
        double scanY = (0.5 - normalized.V) * RangeY;
        double dx = _cosine * scanX + _sine * scanY;
        double dy = -_sine * scanX + _cosine * scanY;
        return PhysicalScanCoordinate.TryCreate(Offset.X + dx, Offset.Y + dy);
    }

    public bool Equals(ScanCoordinateTransform? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return RangeX == other.RangeX
            && RangeY == other.RangeY
            && Offset.Equals(other.Offset)
            && AngleDegrees == other.AngleDegrees
            && VerticalDirection == other.VerticalDirection;
    }

    public override bool Equals(object? obj) => Equals(obj as ScanCoordinateTransform);

    public override int GetHashCode() =>
        HashCode.Combine(RangeX, RangeY, Offset, AngleDegrees, VerticalDirection);
}
