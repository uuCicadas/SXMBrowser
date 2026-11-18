using System;
using System.Collections.Generic;
using System.Linq;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public sealed record AxisSelection(string XColumn, string YColumn);

public sealed class SpectroscopyAxisState
{
    private readonly Dictionary<string, AxisSelection> _selectionsByGroupId;

    public SpectroscopyAxisState(Dictionary<string, AxisSelection>? initial = null)
    {
        _selectionsByGroupId = initial is null
            ? new Dictionary<string, AxisSelection>(StringComparer.Ordinal)
            : new Dictionary<string, AxisSelection>(initial, StringComparer.Ordinal);
    }

    public AxisSelection? SelectionForGroupId(string groupId) =>
        _selectionsByGroupId.TryGetValue(groupId, out AxisSelection? sel) ? sel : null;

    public AxisSelection? EnsureSelection(
        string groupId,
        IReadOnlyList<string> availableColumns,
        string preferredX,
        string preferredY)
    {
        if (availableColumns.Count == 0)
        {
            _selectionsByGroupId.Remove(groupId);
            return null;
        }

        string fallbackX = CanonicalColumn(preferredX, availableColumns) ?? availableColumns[0];
        string fallbackY = CanonicalColumn(preferredY, availableColumns)
            ?? (availableColumns.Count > 1 ? availableColumns[1] : fallbackX);

        AxisSelection? existing = SelectionForGroupId(groupId);
        var selection = new AxisSelection(
            (existing is not null ? CanonicalColumn(existing.XColumn, availableColumns) : null) ?? fallbackX,
            (existing is not null ? CanonicalColumn(existing.YColumn, availableColumns) : null) ?? fallbackY);
        _selectionsByGroupId[groupId] = selection;
        return selection;
    }

    public bool SetXColumn(
        string column,
        string groupId,
        IReadOnlyList<string> availableColumns,
        string preferredX,
        string preferredY)
    {
        string? canonical = CanonicalColumn(column, availableColumns);
        AxisSelection? current = EnsureSelection(groupId, availableColumns, preferredX, preferredY);
        if (canonical is null || current is null) return false;
        _selectionsByGroupId[groupId] = new AxisSelection(canonical, current.YColumn);
        return true;
    }

    public bool SetYColumn(
        string column,
        string groupId,
        IReadOnlyList<string> availableColumns,
        string preferredX,
        string preferredY)
    {
        string? canonical = CanonicalColumn(column, availableColumns);
        AxisSelection? current = EnsureSelection(groupId, availableColumns, preferredX, preferredY);
        if (canonical is null || current is null) return false;
        _selectionsByGroupId[groupId] = new AxisSelection(current.XColumn, canonical);
        return true;
    }

    public void Clear() => _selectionsByGroupId.Clear();

    private static string? CanonicalColumn(string requested, IReadOnlyList<string> availableColumns)
    {
        foreach (string col in availableColumns)
        {
            if (string.Equals(col, requested, StringComparison.Ordinal)) return col;
        }
        string normalized = SpectroscopyColumnSchema.Normalize(requested);
        string? match = null;
        int matchCount = 0;
        foreach (string col in availableColumns)
        {
            if (string.Equals(SpectroscopyColumnSchema.Normalize(col), normalized, StringComparison.Ordinal))
            {
                match = col;
                matchCount++;
                if (matchCount > 1) return null;
            }
        }
        return matchCount == 1 ? match : null;
    }
}

public sealed record PresentedSpectroscopyGroup(
    SpectroscopyGroup Group,
    IReadOnlyList<SpectroscopyFile> VisibleSpectra)
{
    public string Id => Group.Id;
    public IReadOnlyList<SpectroscopyFile> AllSpectra => Group.Spectra;
    public bool ShouldShowGridCard => VisibleSpectra.Count > 0;
    public string VisibleCurveCountText =>
        VisibleSpectra.Count == 1 ? "1 curve" : $"{VisibleSpectra.Count} curves";
    public string ColumnSummary => string.Join(" \u2192 ", Group.AvailableColumns);
    public string RenderId =>
        $"{Group.Id}|{string.Join(',', VisibleSpectra.Select(s => s.Id.ToString("D").ToUpperInvariant()))}";
}

public sealed class SpectroscopyPresentationProjection
{
    public IReadOnlyList<PresentedSpectroscopyGroup> Groups { get; }
    public IReadOnlyList<PresentedSpectroscopyGroup> GridGroups { get; }
    public IReadOnlyList<SpectroscopyFile> MarkerSpectra { get; }

    public SpectroscopyPresentationProjection(
        IReadOnlyList<SpectroscopyGroup> groups,
        IReadOnlySet<Guid> hiddenSpectrumIds)
    {
        Groups = groups.Select(g => new PresentedSpectroscopyGroup(
            g,
            g.Spectra.Where(s => !hiddenSpectrumIds.Contains(s.Id)).ToArray())).ToArray();
        GridGroups = Groups.Where(g => g.ShouldShowGridCard).ToArray();
        MarkerSpectra = Groups.SelectMany(g => g.VisibleSpectra).ToArray();
    }
}

public enum SingleSpectroscopyDrawerAvailability
{
    NoAssociatedSpectra,
    ActiveGroupHasNoVisibleCurves,
    Ready
}

public sealed class SingleSpectroscopyDrawerPresentation
{
    public IReadOnlyList<PresentedSpectroscopyGroup> Groups { get; }
    public PresentedSpectroscopyGroup? ActiveGroup { get; }

    public SingleSpectroscopyDrawerPresentation(
        IReadOnlyList<PresentedSpectroscopyGroup> groups,
        string? activeGroupId)
    {
        Groups = groups;
        ActiveGroup = groups.FirstOrDefault(g => string.Equals(g.Id, activeGroupId, StringComparison.Ordinal))
            ?? groups.FirstOrDefault();
    }

    public SingleSpectroscopyDrawerAvailability Availability => ActiveGroup switch
    {
        null => SingleSpectroscopyDrawerAvailability.NoAssociatedSpectra,
        { VisibleSpectra.Count: 0 } => SingleSpectroscopyDrawerAvailability.ActiveGroupHasNoVisibleCurves,
        _ => SingleSpectroscopyDrawerAvailability.Ready
    };

    public int VisibleCount => ActiveGroup?.VisibleSpectra.Count ?? 0;
    public int TotalCount => ActiveGroup?.AllSpectra.Count ?? 0;
    public string VisibleCountText => $"{VisibleCount} of {TotalCount} visible";
}

public sealed class SingleSpectroscopyState
{
    public const double DefaultHeight = 260.0;
    public const double MinHeight = 180.0;
    public const double MaxHeight = 420.0;

    public bool IsExpanded { get; private set; }
    public double Height { get; private set; }
    public string? ActiveGroupId { get; private set; }
    public Guid? FocusedSpectrumId { get; private set; }

    public SingleSpectroscopyState(
        bool isExpanded = true,
        double height = DefaultHeight,
        string? activeGroupId = null,
        Guid? focusedSpectrumId = null)
    {
        IsExpanded = isExpanded;
        Height = ClampedHeight(height);
        ActiveGroupId = activeGroupId;
        FocusedSpectrumId = focusedSpectrumId;
    }

    public void SetExpanded(bool value) => IsExpanded = value;

    public void SetHeight(double value)
    {
        if (double.IsFinite(value)) Height = ClampedHeight(value);
    }

    public void ActivateGroup(string? id)
    {
        if (string.Equals(ActiveGroupId, id, StringComparison.Ordinal)) return;
        ActiveGroupId = id;
        FocusedSpectrumId = null;
    }

    public void FocusSpectrum(Guid? id) => FocusedSpectrumId = id;

    public void Reconcile(IReadOnlyList<PresentedSpectroscopyGroup> groups)
    {
        if (groups.Count == 0)
        {
            ActiveGroupId = null;
            FocusedSpectrumId = null;
            return;
        }

        PresentedSpectroscopyGroup? retainedGroup = groups.FirstOrDefault(
            g => string.Equals(g.Id, ActiveGroupId, StringComparison.Ordinal));
        PresentedSpectroscopyGroup activeGroup = retainedGroup ?? groups[0];
        bool retainedActive = retainedGroup is not null;
        ActiveGroupId = activeGroup.Id;

        if (activeGroup.VisibleSpectra.Count == 0)
        {
            FocusedSpectrumId = null;
            return;
        }

        if (retainedActive && FocusedSpectrumId is { } fid)
        {
            if (activeGroup.VisibleSpectra.Any(s => s.Id == fid)) return;

            int focusedIndex = -1;
            for (int i = 0; i < activeGroup.AllSpectra.Count; i++)
            {
                if (activeGroup.AllSpectra[i].Id == fid)
                {
                    focusedIndex = i;
                    break;
                }
            }
            if (focusedIndex >= 0)
            {
                var visibleIds = new HashSet<Guid>(activeGroup.VisibleSpectra.Select(s => s.Id));
                for (int i = focusedIndex + 1; i < activeGroup.AllSpectra.Count; i++)
                {
                    if (visibleIds.Contains(activeGroup.AllSpectra[i].Id))
                    {
                        FocusedSpectrumId = activeGroup.AllSpectra[i].Id;
                        return;
                    }
                }
                for (int i = focusedIndex - 1; i >= 0; i--)
                {
                    if (visibleIds.Contains(activeGroup.AllSpectra[i].Id))
                    {
                        FocusedSpectrumId = activeGroup.AllSpectra[i].Id;
                        return;
                    }
                }
            }
        }

        FocusedSpectrumId = activeGroup.VisibleSpectra[0].Id;
    }

    public static double ClampedHeight(double value) =>
        double.IsFinite(value) ? Math.Min(MaxHeight, Math.Max(MinHeight, value)) : DefaultHeight;

    public static double ResizedHeight(double startingAt, double verticalTranslation) =>
        ClampedHeight(startingAt - verticalTranslation);
}

public enum SpectrumRowModifier
{
    Plain,
    Command,
    Shift
}

public sealed class SpectrumRowInteractionPlan
{
    public HashSet<Guid> AssociationIds { get; }
    public bool ShouldFocusClickedSpectrum { get; }

    public SpectrumRowInteractionPlan(
        IReadOnlySet<Guid> existingAssociationIds,
        Guid clickedId,
        SpectrumRowModifier modifier,
        bool clickedIsVisible)
    {
        if (modifier == SpectrumRowModifier.Plain)
        {
            AssociationIds = [clickedId];
            ShouldFocusClickedSpectrum = clickedIsVisible;
        }
        else
        {
            var updated = new HashSet<Guid>(existingAssociationIds);
            if (!updated.Remove(clickedId))
            {
                updated.Add(clickedId);
            }
            AssociationIds = updated;
            ShouldFocusClickedSpectrum = false;
        }
    }
}

public sealed record SpectrumFocusPlan(string GroupId, Guid SpectrumId)
{
    public static SpectrumFocusPlan? Resolve(
        Guid spectrumId,
        IReadOnlyList<PresentedSpectroscopyGroup> groups)
    {
        PresentedSpectroscopyGroup? group = groups.FirstOrDefault(
            g => g.AllSpectra.Any(s => s.Id == spectrumId));
        if (group is null || !group.VisibleSpectra.Any(s => s.Id == spectrumId))
        {
            return null;
        }
        return new SpectrumFocusPlan(group.Id, spectrumId);
    }
}

public readonly record struct SpectrumPaletteColor(string Name, byte Red, byte Green, byte Blue)
{
    public double NormalizedRed => Red / 255.0;
    public double NormalizedGreen => Green / 255.0;
    public double NormalizedBlue => Blue / 255.0;
}

public sealed record SpectrumLinePattern(string Name, double[] DashLengths);

public readonly record struct SpectrumVisualStyle(
    int CycleIndex,
    int PaletteIndex,
    int PatternIndex,
    SpectrumPaletteColor Color,
    SpectrumLinePattern Pattern)
{
    public static readonly IReadOnlyList<SpectrumPaletteColor> Palette =
    [
        new("Blue", 0x00, 0x72, 0xB2),
        new("Vermilion", 0xD5, 0x5E, 0x00),
        new("Bluish green", 0x00, 0x9E, 0x73),
        new("Reddish purple", 0xCC, 0x79, 0xA7),
        new("Orange", 0xE6, 0x9F, 0x00),
        new("Sky blue", 0x56, 0xB4, 0xE9),
        new("Black", 0x00, 0x00, 0x00)
    ];

    public static readonly IReadOnlyList<SpectrumLinePattern> Patterns =
    [
        new("solid line", Array.Empty<double>()),
        new("dashed line", [8.0, 4.0]),
        new("dotted line", [1.0, 3.0]),
        new("dash-dot line", [8.0, 3.0, 1.0, 3.0])
    ];

    public static int CycleLength => Palette.Count * Patterns.Count; // 28

    public static SpectrumVisualStyle ForIndex(int index)
    {
        int paletteIndex = EuclideanModulo(index, Palette.Count);
        int patternIndex = EuclideanModulo(index, Patterns.Count);
        int cycleIndex = EuclideanModulo(index, CycleLength);
        return new SpectrumVisualStyle(
            cycleIndex,
            paletteIndex,
            patternIndex,
            Palette[paletteIndex],
            Patterns[patternIndex]);
    }

    private static int EuclideanModulo(int value, int modulus)
    {
        int remainder = value % modulus;
        return remainder >= 0 ? remainder : remainder + modulus;
    }
}
