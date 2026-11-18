using System;
using System.Collections.Generic;
using System.Linq;

namespace SXMBrowser.AppCore;

public enum ManualSpectrumAssociationKind
{
    AutomaticAllowed,
    Manual,
    MissingManualTarget
}

public readonly record struct ManualSpectrumAssociationResolution(
    ManualSpectrumAssociationKind Kind,
    Guid? SxmId = null,
    DatasetRelativePath? SxmPath = null)
{
    public bool AllowsAutomaticAssociation => Kind == ManualSpectrumAssociationKind.AutomaticAllowed;
}

public sealed class ManualSpectrumAssociationProjection
{
    private readonly DatasetPathIndex _pathIndex;

    public IReadOnlyDictionary<DatasetRelativePath, DatasetRelativePath> TargetPathByDatPath { get; }
    public IReadOnlyDictionary<Guid, Guid> ResolvedSxmIdByDatId { get; }
    public IReadOnlyDictionary<Guid, DatasetRelativePath> MissingTargetPathByDatId { get; }

    public ManualSpectrumAssociationProjection(
        IEnumerable<DatasetManualAssociationV1> associations,
        DatasetPathIndex pathIndex,
        ISet<Guid> availableSxmIds)
    {
        var targets = new Dictionary<DatasetRelativePath, DatasetRelativePath>();
        foreach (DatasetManualAssociationV1 assoc in associations)
        {
            targets[assoc.DatPath] = assoc.SxmPath;
        }

        var resolved = new Dictionary<Guid, Guid>();
        var missing = new Dictionary<Guid, DatasetRelativePath>();
        foreach ((Guid datId, DatasetRelativePath datPath) in pathIndex.DatPathById)
        {
            if (!targets.TryGetValue(datPath, out DatasetRelativePath? sxmPath)) continue;
            if (pathIndex.SxmId(sxmPath) is { } sxmId && availableSxmIds.Contains(sxmId))
            {
                resolved[datId] = sxmId;
            }
            else
            {
                missing[datId] = sxmPath;
            }
        }

        TargetPathByDatPath = targets;
        ResolvedSxmIdByDatId = resolved;
        MissingTargetPathByDatId = missing;
        _pathIndex = pathIndex;
    }

    public ManualSpectrumAssociationResolution ResolutionForDatId(Guid datId)
    {
        if (ResolvedSxmIdByDatId.TryGetValue(datId, out Guid sxmId))
        {
            return new ManualSpectrumAssociationResolution(ManualSpectrumAssociationKind.Manual, SxmId: sxmId);
        }
        if (MissingTargetPathByDatId.TryGetValue(datId, out DatasetRelativePath? missingPath))
        {
            return new ManualSpectrumAssociationResolution(
                ManualSpectrumAssociationKind.MissingManualTarget, SxmPath: missingPath);
        }
        if (_pathIndex.DatPath(datId) is { } datPath
            && TargetPathByDatPath.TryGetValue(datPath, out DatasetRelativePath? sxmPath))
        {
            return new ManualSpectrumAssociationResolution(
                ManualSpectrumAssociationKind.MissingManualTarget, SxmPath: sxmPath);
        }
        return new ManualSpectrumAssociationResolution(ManualSpectrumAssociationKind.AutomaticAllowed);
    }
}

public sealed class ManualAssociationUpdatePlan
{
    public IReadOnlyList<DatasetRelativePath> DatPaths { get; }
    public DatasetRelativePath SxmPath { get; }

    public ManualAssociationUpdatePlan(
        IReadOnlyList<Guid> datIds,
        Guid targetSxmId,
        DatasetPathIndex pathIndex)
    {
        if (datIds.Count == 0)
        {
            throw new InvalidOperationException("No spectroscopy files were selected for association.");
        }
        DatasetRelativePath? targetPath = pathIndex.SxmPath(targetSxmId)
            ?? throw new InvalidOperationException($"The SXM file {targetSxmId} is not in the active dataset.");

        var paths = new HashSet<DatasetRelativePath>();
        foreach (Guid id in datIds)
        {
            DatasetRelativePath path = pathIndex.DatPath(id)
                ?? throw new InvalidOperationException($"The spectroscopy file {id} is not in the active dataset.");
            paths.Add(path);
        }

        DatPaths = paths.OrderBy(p => p).ToArray();
        SxmPath = targetPath;
    }

    public List<DatasetManualAssociationV1> Applying(IEnumerable<DatasetManualAssociationV1> existing)
    {
        var replacements = new HashSet<DatasetRelativePath>(DatPaths);
        var updated = existing.Where(a => !replacements.Contains(a.DatPath)).ToList();
        foreach (DatasetRelativePath datPath in DatPaths)
        {
            updated.Add(new DatasetManualAssociationV1(datPath, SxmPath));
        }
        return updated
            .OrderBy(a => a.DatPath)
            .ThenBy(a => a.SxmPath)
            .ToList();
    }
}
