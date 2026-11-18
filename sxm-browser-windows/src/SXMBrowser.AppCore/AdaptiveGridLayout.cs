using System;
using System.Collections.Generic;

namespace SXMBrowser.AppCore;

public enum GridDensity
{
    Compact,
    Comfortable,
    Large
}

public static class GridDensityExtensions
{
    public static string ToRawValue(this GridDensity density) => density switch
    {
        GridDensity.Compact => "compact",
        GridDensity.Comfortable => "comfortable",
        GridDensity.Large => "large",
        _ => throw new ArgumentOutOfRangeException(nameof(density), density, null)
    };

    public static string Label(this GridDensity density) => density switch
    {
        GridDensity.Compact => "Compact",
        GridDensity.Comfortable => "Comfortable",
        GridDensity.Large => "Large",
        _ => throw new ArgumentOutOfRangeException(nameof(density), density, null)
    };

    public static double MinimumCardWidth(this GridDensity density) => density switch
    {
        GridDensity.Compact => 120.0,
        GridDensity.Comfortable => 160.0,
        GridDensity.Large => 220.0,
        _ => 160.0
    };

    public static bool TryParse(string? raw, out GridDensity density)
    {
        switch (raw)
        {
            case "compact":
                density = GridDensity.Compact;
                return true;
            case "comfortable":
                density = GridDensity.Comfortable;
                return true;
            case "large":
                density = GridDensity.Large;
                return true;
            default:
                density = GridDensity.Comfortable;
                return false;
        }
    }

    public static GridDensity Migrating(int legacyColumnCount) => legacyColumnCount switch
    {
        2 => GridDensity.Large,
        3 or 4 => GridDensity.Comfortable,
        >= 5 and <= 8 => GridDensity.Compact,
        _ => GridDensity.Comfortable
    };
}

public readonly record struct AdaptiveGridMetrics
{
    public const double DefaultHorizontalPadding = 18.0;
    public const double DefaultSpacing = 14.0;
    public const int MaximumColumnCount = 10_000;

    public GridDensity Density { get; }
    public double MinimumCardWidth { get; }
    public double HorizontalPadding { get; }
    public double Spacing { get; }
    public int ColumnCount { get; }

    public AdaptiveGridMetrics(
        double containerWidth,
        GridDensity density,
        double horizontalPadding = DefaultHorizontalPadding,
        double spacing = DefaultSpacing)
    {
        Density = density;
        MinimumCardWidth = density.MinimumCardWidth();
        HorizontalPadding = horizontalPadding;
        Spacing = spacing;

        if (!double.IsFinite(containerWidth)
            || !double.IsFinite(horizontalPadding) || horizontalPadding < 0.0
            || !double.IsFinite(spacing) || spacing < 0.0
            || containerWidth <= 0.0)
        {
            ColumnCount = 1;
            return;
        }

        double usableWidth = Math.Max(0.0, containerWidth - 2.0 * horizontalPadding);
        double rawCount = (usableWidth + spacing) / (MinimumCardWidth + spacing);
        double boundedCount = Math.Min(MaximumColumnCount, Math.Max(1.0, Math.Floor(rawCount)));
        ColumnCount = (int)boundedCount;
    }
}

public enum GridNavigationDirection
{
    Left,
    Right,
    Up,
    Down
}

public static class AdaptiveGridNavigation
{
    public static int SelectionDelta(GridNavigationDirection direction, int columnCount)
    {
        int columns = Math.Max(1, columnCount);
        return direction switch
        {
            GridNavigationDirection.Left => -1,
            GridNavigationDirection.Right => 1,
            GridNavigationDirection.Up => -columns,
            GridNavigationDirection.Down => columns,
            _ => 0
        };
    }

    public static TId? TargetFileId<TId>(
        TId? currentId,
        GridNavigationDirection direction,
        int columnCount,
        IReadOnlyList<TId?> itemFileIds) where TId : struct
    {
        if (itemFileIds.Count == 0) return null;
        int columns = Math.Max(1, columnCount);

        int currentIndex = -1;
        if (currentId is { } cid)
        {
            for (int i = 0; i < itemFileIds.Count; i++)
            {
                if (itemFileIds[i] is { } id && EqualityComparer<TId>.Default.Equals(id, cid))
                {
                    currentIndex = i;
                    break;
                }
            }
        }

        if (currentIndex < 0)
        {
            if (direction is GridNavigationDirection.Left or GridNavigationDirection.Up)
            {
                for (int i = itemFileIds.Count - 1; i >= 0; i--)
                {
                    if (itemFileIds[i] is { } last) return last;
                }
                return null;
            }
            for (int i = 0; i < itemFileIds.Count; i++)
            {
                if (itemFileIds[i] is { } first) return first;
            }
            return null;
        }

        switch (direction)
        {
            case GridNavigationDirection.Left:
                for (int i = currentIndex - 1; i >= 0; i--)
                {
                    if (itemFileIds[i] is { } candidate) return candidate;
                }
                return null;

            case GridNavigationDirection.Right:
                for (int i = currentIndex + 1; i < itemFileIds.Count; i++)
                {
                    if (itemFileIds[i] is { } candidate) return candidate;
                }
                return null;

            case GridNavigationDirection.Up:
            case GridNavigationDirection.Down:
                int totalRows = (itemFileIds.Count + columns - 1) / columns;
                int currentRow = currentIndex / columns;
                int currentCol = currentIndex % columns;
                int rowStep = direction == GridNavigationDirection.Up ? -1 : 1;
                int row = currentRow + rowStep;

                while (row >= 0 && row < totalRows)
                {
                    int rowStart = row * columns;
                    int rowEnd = Math.Min(itemFileIds.Count, rowStart + columns);
                    int preferredIdx = rowStart + currentCol;
                    if (preferredIdx < rowEnd && itemFileIds[preferredIdx] is { } preferred)
                    {
                        return preferred;
                    }

                    int? bestIndex = null;
                    int bestDistance = int.MaxValue;
                    for (int idx = rowStart; idx < rowEnd; idx++)
                    {
                        if (itemFileIds[idx] is null) continue;
                        int distance = Math.Abs((idx - rowStart) - currentCol);
                        if (distance < bestDistance)
                        {
                            bestDistance = distance;
                            bestIndex = idx;
                        }
                    }
                    if (bestIndex is { } bi && itemFileIds[bi] is { } snapped)
                    {
                        return snapped;
                    }

                    row += rowStep;
                }
                return null;

            default:
                return null;
        }
    }
}
