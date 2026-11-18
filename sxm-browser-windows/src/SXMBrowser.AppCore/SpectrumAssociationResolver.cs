using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public sealed record SpectrumAssociationResult(
    IReadOnlyDictionary<Guid, IReadOnlyList<SpectroscopyGroup>> GroupsByFileId,
    IReadOnlyDictionary<Guid, Guid> ParentIdBySpectrumId,
    IReadOnlySet<Guid> UnassociatedSpectrumIds);

public static class SpectrumAssociationResolver
{
    public static SpectrumAssociationResult AssociateSpectra(
        IReadOnlyList<SpectroscopyFile> spectra,
        IReadOnlyList<SXMMetadata> sxmFiles,
        ManualSpectrumAssociationProjection? manualProjection = null)
    {
        if (sxmFiles.Count == 0)
        {
            return new SpectrumAssociationResult(
                new Dictionary<Guid, IReadOnlyList<SpectroscopyGroup>>(),
                new Dictionary<Guid, Guid>(),
                new HashSet<Guid>(spectra.Select(s => s.Id)));
        }

        var sxmByTime = sxmFiles.OrderBy(f => f.ModifiedTime)
            .ThenBy(f => f.Filename, NaturalStringComparer.Instance)
            .ToArray();
        var sxmByName = sxmFiles.OrderByDescending(f => SxmBasename(f).Length).ToArray();
        var sxmById = sxmFiles.ToDictionary(f => f.Id);

        var buckets = new Dictionary<Guid, List<SpectroscopyFile>>();
        var parents = new Dictionary<Guid, Guid>();
        var unassociated = new HashSet<Guid>();

        foreach (SpectroscopyFile spectrum in spectra.OrderBy(s => s.Filename, NaturalStringComparer.Instance))
        {
            ManualSpectrumAssociationResolution resolution =
                manualProjection?.ResolutionForDatId(spectrum.Id)
                ?? new ManualSpectrumAssociationResolution(ManualSpectrumAssociationKind.AutomaticAllowed);

            SXMMetadata? parent = resolution.Kind switch
            {
                ManualSpectrumAssociationKind.AutomaticAllowed =>
                    AutomaticSpectrumParent(spectrum, sxmByTime, sxmByName),
                ManualSpectrumAssociationKind.Manual when resolution.SxmId is { } sid
                    && sxmById.TryGetValue(sid, out SXMMetadata? manualFile) => manualFile,
                _ => null
            };

            if (parent is null)
            {
                unassociated.Add(spectrum.Id);
                continue;
            }

            parents[spectrum.Id] = parent.Id;
            if (!buckets.TryGetValue(parent.Id, out List<SpectroscopyFile>? list))
            {
                list = [];
                buckets[parent.Id] = list;
            }
            list.Add(spectrum);
        }

        var groups = new Dictionary<Guid, IReadOnlyList<SpectroscopyGroup>>();
        foreach (SXMMetadata file in sxmFiles)
        {
            if (buckets.TryGetValue(file.Id, out List<SpectroscopyFile>? fileSpectra))
            {
                groups[file.Id] = SpectroscopyGroup.CompatibleGroups(file, fileSpectra);
            }
        }

        return new SpectrumAssociationResult(groups, parents, unassociated);
    }

    public static SXMMetadata? AutomaticSpectrumParent(
        SpectroscopyFile spectrum,
        IReadOnlyList<SXMMetadata> sxmFilesByTime,
        IReadOnlyList<SXMMetadata> sxmFilesByDescendingBasenameLength)
    {
        return SxmMatchingFilename(spectrum, sxmFilesByDescendingBasenameLength)
            ?? sxmFilesByTime.LastOrDefault(s => s.ModifiedTime <= spectrum.ModifiedTime)
            ?? NearestSxm(spectrum, sxmFilesByTime);
    }

    private static SXMMetadata? SxmMatchingFilename(
        SpectroscopyFile spectrum,
        IReadOnlyList<SXMMetadata> sxmFilesByDescendingBasenameLength)
    {
        string spectrumBase = Path.GetFileNameWithoutExtension(spectrum.Path).ToLowerInvariant();
        foreach (SXMMetadata file in sxmFilesByDescendingBasenameLength)
        {
            if (spectrumBase.StartsWith(SxmBasename(file).ToLowerInvariant(), StringComparison.Ordinal))
            {
                return file;
            }
        }
        return null;
    }

    private static string SxmBasename(SXMMetadata file) =>
        Path.GetFileNameWithoutExtension(file.Path);

    private static SXMMetadata? NearestSxm(
        SpectroscopyFile spectrum,
        IReadOnlyList<SXMMetadata> sxmFiles)
    {
        SXMMetadata? best = null;
        double bestDelta = double.PositiveInfinity;
        foreach (SXMMetadata file in sxmFiles)
        {
            double delta = Math.Abs((file.ModifiedTime - spectrum.ModifiedTime).TotalSeconds);
            if (delta < bestDelta)
            {
                bestDelta = delta;
                best = file;
            }
        }
        return best;
    }
}
