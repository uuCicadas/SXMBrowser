using System;
using System.Collections.Generic;
using System.Linq;

namespace SXMBrowser.AppCore;

public static class TagReorderPlan
{
    public static int? DestinationIndexForMove(
        Guid sourceId,
        Guid targetId,
        IReadOnlyList<DatasetTagV1> tags)
    {
        bool hasSource = tags.Any(t => t.Id == sourceId);
        if (!hasSource)
        {
            throw new InvalidOperationException("The dragged tag no longer exists.");
        }
        int targetIndex = -1;
        for (int i = 0; i < tags.Count; i++)
        {
            if (tags[i].Id == targetId)
            {
                targetIndex = i;
                break;
            }
        }
        if (targetIndex < 0)
        {
            throw new InvalidOperationException("The destination tag no longer exists.");
        }
        if (sourceId == targetId) return null;
        return targetIndex;
    }
}

public static class TagPresentationProjection
{
    public static Guid? SuccessorTagId(Guid deletedTagId, IReadOnlyList<DatasetTagV1> tags)
    {
        int idx = -1;
        for (int i = 0; i < tags.Count; i++)
        {
            if (tags[i].Id == deletedTagId)
            {
                idx = i;
                break;
            }
        }
        if (idx < 0 || idx + 1 >= tags.Count) return null;
        return tags[idx + 1].Id;
    }

    public static Guid? ReconciledActiveTagId(Guid? activeTagId, IReadOnlyList<DatasetTagV1> tags)
    {
        if (activeTagId is not { } id) return null;
        return tags.Any(t => t.Id == id) ? id : null;
    }

    public static HashSet<Guid> FilteredExpandedTagIds(
        IEnumerable<Guid> expandedTagIds,
        IReadOnlyList<DatasetTagV1> tags)
    {
        var validIds = new HashSet<Guid>(tags.Select(t => t.Id));
        var filtered = new HashSet<Guid>();
        foreach (Guid id in expandedTagIds)
        {
            if (validIds.Contains(id))
            {
                filtered.Add(id);
            }
        }
        return filtered;
    }
}

public sealed class MetadataWarningPresentationState
{
    private readonly List<string> _messages = [];
    private readonly HashSet<string> _seen = new(StringComparer.Ordinal);

    public IReadOnlyList<string> Messages => _messages;
    public bool IsDismissed { get; private set; }
    public bool IsEmpty => _messages.Count == 0;
    public int Count => _messages.Count;
    public string DetailText => string.Join("\n\n", _messages);
    public bool IsPresented => _messages.Count > 0 && !IsDismissed;

    public bool Append(string? message)
    {
        string? normalized = Normalize(message);
        if (normalized is null || !_seen.Add(normalized))
        {
            return false;
        }
        _messages.Add(normalized);
        IsDismissed = false;
        return true;
    }

    public void Dismiss()
    {
        if (_messages.Count > 0)
        {
            IsDismissed = true;
        }
    }

    public void Reset(string? message = null)
    {
        _messages.Clear();
        _seen.Clear();
        IsDismissed = false;
        Append(message);
    }

    private static string? Normalize(string? message)
    {
        if (message is null) return null;
        string s = message
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace("\r", "\n", StringComparison.Ordinal);
        s = MetadataCanonical.SafeNormalizeNfc(s).Trim();
        return s.Length == 0 ? null : s;
    }
}
