using System;
using System.Collections.Generic;
using System.Linq;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public enum FileSortCriterion
{
    Name,
    ModifiedTime,
    RecordedTime
}

public sealed record FileSortValue(
    string Identity,
    string Filename,
    DateTimeOffset ModifiedTime,
    DateTimeOffset? RecordedTime);

public static class FileSortComparator
{
    public static int Compare(
        FileSortValue lhs,
        FileSortValue rhs,
        FileSortCriterion criterion,
        bool ascending)
    {
        if (string.Equals(lhs.Identity, rhs.Identity, StringComparison.Ordinal))
        {
            return 0;
        }

        if (criterion == FileSortCriterion.RecordedTime)
        {
            switch (lhs.RecordedTime, rhs.RecordedTime)
            {
                case (null, not null):
                    return 1; // nil recordedTime always sorts after present recordedTime
                case (not null, null):
                    return -1;
                case (DateTimeOffset lDate, DateTimeOffset rDate) when lDate != rDate:
                    int dtCmp = lDate.CompareTo(rDate);
                    return ascending ? dtCmp : -dtCmp;
            }
        }

        int primary = criterion switch
        {
            FileSortCriterion.Name => NaturalStringComparer.CompareFilenames(lhs.Filename, rhs.Filename),
            FileSortCriterion.ModifiedTime => lhs.ModifiedTime.CompareTo(rhs.ModifiedTime),
            FileSortCriterion.RecordedTime => 0,
            _ => 0
        };
        if (primary != 0)
        {
            return ascending ? primary : -primary;
        }

        int filenameCmp = NaturalStringComparer.CompareFilenames(lhs.Filename, rhs.Filename);
        if (filenameCmp != 0) return filenameCmp;
        return string.CompareOrdinal(lhs.Identity, rhs.Identity);
    }

    public static bool OrderedBefore(
        FileSortValue lhs,
        FileSortValue rhs,
        FileSortCriterion criterion,
        bool ascending) => Compare(lhs, rhs, criterion, ascending) < 0;
}

public sealed record FilenameSearchCandidate<TId>(
    TId Id,
    string SxmFilename,
    IReadOnlyList<string> AssociatedDatFilenames);

public sealed class FilenameSearchProjection<TId> where TId : notnull
{
    public string NormalizedQuery { get; }
    public IReadOnlyList<TId> MatchingIds { get; }
    public int ScopedCount { get; }
    public int MatchedCount => MatchingIds.Count;

    public FilenameSearchProjection(
        string query,
        IReadOnlyList<FilenameSearchCandidate<TId>> candidates)
    {
        NormalizedQuery = query.Trim();
        ScopedCount = candidates.Count;
        if (NormalizedQuery.Length == 0)
        {
            MatchingIds = candidates.Select(c => c.Id).ToArray();
            return;
        }

        var matches = new List<TId>();
        foreach (FilenameSearchCandidate<TId> candidate in candidates)
        {
            bool matchesSxm = candidate.SxmFilename.Contains(NormalizedQuery, StringComparison.OrdinalIgnoreCase);
            bool matchesDat = !matchesSxm && candidate.AssociatedDatFilenames.Any(d =>
                d.Contains(NormalizedQuery, StringComparison.OrdinalIgnoreCase));
            if (matchesSxm || matchesDat)
            {
                matches.Add(candidate.Id);
            }
        }
        MatchingIds = matches;
    }
}

public sealed record FilenameSearchRequest(Guid Id, string Query);

public sealed class FilenameSearchRequestGate
{
    public FilenameSearchRequest? ActiveRequest { get; private set; }

    public FilenameSearchRequest Begin(string query, Guid? id = null)
    {
        var req = new FilenameSearchRequest(id ?? Guid.NewGuid(), query);
        ActiveRequest = req;
        return req;
    }

    public void Cancel() => ActiveRequest = null;

    public bool Accepts(FilenameSearchRequest request) => Equals(ActiveRequest, request);
}
