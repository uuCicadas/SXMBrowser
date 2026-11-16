using System;
using System.Collections.Generic;
using System.Linq;

namespace SXMBrowser.AppCore;

public sealed class FileDeletionPlan<TId> where TId : notnull
{
    public IReadOnlyList<TId> TargetIds { get; }

    public FileDeletionPlan(IReadOnlyList<TId> visibleIds, IReadOnlySet<TId> selectedIds)
    {
        var seen = new HashSet<TId>();
        var list = new List<TId>();
        foreach (TId id in visibleIds)
        {
            if (selectedIds.Contains(id) && seen.Add(id))
            {
                list.Add(id);
            }
        }
        TargetIds = list;
    }
}

public enum SelectionActionPlacement
{
    None,
    Overflow,
    ActionBar
}

public sealed class SelectionActionPresentation<TId> where TId : notnull
{
    public IReadOnlyList<TId> OrderedIds { get; }
    public SelectionActionPlacement Placement { get; }

    public SelectionActionPresentation(IReadOnlyList<TId> visibleIds, IReadOnlySet<TId> selectedIds)
    {
        OrderedIds = new FileDeletionPlan<TId>(visibleIds, selectedIds).TargetIds;
        Placement = OrderedIds.Count switch
        {
            0 => SelectionActionPlacement.None,
            1 => SelectionActionPlacement.Overflow,
            _ => SelectionActionPlacement.ActionBar
        };
    }
}

public sealed class SelectionState<TId> where TId : struct, IEquatable<TId>
{
    private readonly HashSet<TId> _selectedIds = [];

    public TId? PrimaryId { get; private set; }
    public IReadOnlySet<TId> SelectedIds => _selectedIds;
    public TId? AnchorId { get; private set; }

    public void Clear()
    {
        PrimaryId = null;
        _selectedIds.Clear();
        AnchorId = null;
    }

    public void SelectOnly(TId id, IReadOnlyList<TId> visibleIds)
    {
        if (!visibleIds.Contains(id)) return;
        PrimaryId = id;
        _selectedIds.Clear();
        _selectedIds.Add(id);
        AnchorId = id;
    }

    public void Toggle(TId id, IReadOnlyList<TId> visibleIds)
    {
        var visibleSet = new HashSet<TId>(visibleIds);
        if (!visibleSet.Contains(id)) return;

        _selectedIds.IntersectWith(visibleSet);
        if (_selectedIds.Remove(id))
        {
            if (_selectedIds.Count == 0)
            {
                Clear();
                return;
            }
            if (PrimaryId is not { } pid || pid.Equals(id) || !_selectedIds.Contains(pid))
            {
                PrimaryId = FirstInOrder(visibleIds, _selectedIds);
            }
            if (AnchorId is not { } aid || aid.Equals(id) || !visibleSet.Contains(aid))
            {
                AnchorId = PrimaryId;
            }
        }
        else
        {
            _selectedIds.Add(id);
            PrimaryId = id;
            AnchorId = id;
        }
    }

    public void SelectRange(TId toId, IReadOnlyList<TId> visibleIds)
    {
        int targetIndex = IndexOf(visibleIds, toId);
        if (targetIndex < 0) return;

        int anchorIndex = AnchorId is { } aid ? IndexOf(visibleIds, aid) : -1;
        if (anchorIndex < 0 && PrimaryId is { } pid)
        {
            anchorIndex = IndexOf(visibleIds, pid);
        }
        if (anchorIndex < 0)
        {
            anchorIndex = targetIndex;
        }

        int lo = Math.Min(anchorIndex, targetIndex);
        int hi = Math.Max(anchorIndex, targetIndex);
        TId anchor = visibleIds[anchorIndex];

        _selectedIds.Clear();
        for (int i = lo; i <= hi; i++)
        {
            _selectedIds.Add(visibleIds[i]);
        }
        PrimaryId = toId;
        AnchorId = anchor;
    }

    public void SelectAll(IReadOnlyList<TId> visibleIds)
    {
        if (visibleIds.Count == 0)
        {
            Clear();
            return;
        }
        var visibleSet = new HashSet<TId>(visibleIds);
        _selectedIds.Clear();
        foreach (TId id in visibleIds) _selectedIds.Add(id);

        if (PrimaryId is not { } pid || !visibleSet.Contains(pid))
        {
            PrimaryId = visibleIds[0];
        }
        if (AnchorId is not { } aid || !visibleSet.Contains(aid))
        {
            AnchorId = PrimaryId;
        }
    }

    public void Step(int delta, IReadOnlyList<TId> visibleIds)
    {
        if (delta == 0 || visibleIds.Count == 0) return;
        if (PrimaryId is not { } pid)
        {
            SelectOnly(visibleIds[0], visibleIds);
            return;
        }
        int currentIndex = IndexOf(visibleIds, pid);
        if (currentIndex < 0)
        {
            Reconcile(visibleIds, fallbackToFirst: true);
            return;
        }
        long target = (long)currentIndex + delta;
        if (target < 0 || target >= visibleIds.Count) return;
        SelectOnly(visibleIds[(int)target], visibleIds);
    }

    public void Extend(int delta, IReadOnlyList<TId> visibleIds)
    {
        if (delta == 0 || visibleIds.Count == 0) return;
        if (PrimaryId is not { } pid)
        {
            SelectOnly(visibleIds[0], visibleIds);
            return;
        }
        int currentIndex = IndexOf(visibleIds, pid);
        if (currentIndex < 0)
        {
            SelectOnly(visibleIds[0], visibleIds);
            return;
        }
        long target = (long)currentIndex + delta;
        if (target < 0 || target >= visibleIds.Count) return;
        SelectRange(visibleIds[(int)target], visibleIds);
    }

    public bool CanStep(int delta, IReadOnlyList<TId> visibleIds)
    {
        if (delta == 0 || PrimaryId is not { } pid) return false;
        int currentIndex = IndexOf(visibleIds, pid);
        if (currentIndex < 0) return false;
        long target = (long)currentIndex + delta;
        return target >= 0 && target < visibleIds.Count;
    }

    public void Reconcile(IReadOnlyList<TId> visibleIds, bool fallbackToFirst)
    {
        var visibleSet = new HashSet<TId>(visibleIds);
        _selectedIds.IntersectWith(visibleSet);

        if (_selectedIds.Count == 0)
        {
            if (fallbackToFirst && visibleIds.Count > 0)
            {
                SelectOnly(visibleIds[0], visibleIds);
            }
            else
            {
                Clear();
            }
            return;
        }

        if (PrimaryId is not { } pid || !_selectedIds.Contains(pid))
        {
            PrimaryId = FirstInOrder(visibleIds, _selectedIds);
        }
        if (AnchorId is not { } aid || !visibleSet.Contains(aid))
        {
            AnchorId = PrimaryId;
        }
    }

    public void ReconcileAfterRemoval(
        IReadOnlySet<TId> removedIds,
        IReadOnlyList<TId> oldVisibleIds,
        IReadOnlyList<TId> newVisibleIds)
    {
        TId? previousPrimary = PrimaryId;
        var newVisibleSet = new HashSet<TId>(newVisibleIds);
        _selectedIds.ExceptWith(removedIds);
        _selectedIds.IntersectWith(newVisibleSet);

        if (_selectedIds.Count > 0)
        {
            if (PrimaryId is not { } pid || !_selectedIds.Contains(pid))
            {
                PrimaryId = FirstInOrder(newVisibleIds, _selectedIds);
            }
            if (AnchorId is not { } aid || removedIds.Contains(aid) || !newVisibleSet.Contains(aid))
            {
                AnchorId = PrimaryId;
            }
            return;
        }

        if (previousPrimary is not { } prevId)
        {
            Clear();
            return;
        }
        int oldIndex = IndexOf(oldVisibleIds, prevId);
        if (oldIndex < 0)
        {
            Clear();
            return;
        }

        TId? replacement = null;
        for (int i = oldIndex + 1; i < oldVisibleIds.Count; i++)
        {
            if (newVisibleSet.Contains(oldVisibleIds[i]))
            {
                replacement = oldVisibleIds[i];
                break;
            }
        }
        if (replacement is null)
        {
            for (int i = oldIndex - 1; i >= 0; i--)
            {
                if (newVisibleSet.Contains(oldVisibleIds[i]))
                {
                    replacement = oldVisibleIds[i];
                    break;
                }
            }
        }

        if (replacement is { } r)
        {
            SelectOnly(r, newVisibleIds);
        }
        else
        {
            Clear();
        }
    }

    private static int IndexOf(IReadOnlyList<TId> list, TId item)
    {
        for (int i = 0; i < list.Count; i++)
        {
            if (list[i].Equals(item)) return i;
        }
        return -1;
    }

    private static TId? FirstInOrder(IReadOnlyList<TId> ordered, HashSet<TId> set)
    {
        for (int i = 0; i < ordered.Count; i++)
        {
            if (set.Contains(ordered[i])) return ordered[i];
        }
        return null;
    }
}
