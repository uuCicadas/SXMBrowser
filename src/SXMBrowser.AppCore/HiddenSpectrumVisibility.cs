using System;
using System.Collections.Generic;
using System.Linq;

namespace SXMBrowser.AppCore;

public sealed class HiddenSpectrumProjection
{
    public IReadOnlyList<DatasetRelativePath> PersistedDatPaths { get; }
    public IReadOnlySet<Guid> HiddenDatIds { get; }
    public IReadOnlyList<DatasetRelativePath> MissingDatPaths { get; }

    public HiddenSpectrumProjection(
        IEnumerable<DatasetRelativePath> hiddenDatPaths,
        DatasetPathIndex pathIndex)
    {
        var persisted = hiddenDatPaths.Distinct().OrderBy(p => p).ToArray();
        var hiddenIds = new HashSet<Guid>();
        var missing = new List<DatasetRelativePath>();

        foreach (DatasetRelativePath p in persisted)
        {
            if (pathIndex.DatId(p) is { } id)
            {
                hiddenIds.Add(id);
            }
            else
            {
                missing.Add(p);
            }
        }

        PersistedDatPaths = persisted;
        HiddenDatIds = hiddenIds;
        MissingDatPaths = missing;
    }
}

public sealed class HiddenSpectrumUpdatePlan
{
    public DatasetRelativePath DatPath { get; }
    public bool Visible { get; }

    public HiddenSpectrumUpdatePlan(Guid datId, bool visible, DatasetPathIndex pathIndex)
    {
        DatPath = pathIndex.DatPath(datId)
            ?? throw new InvalidOperationException($"The spectroscopy file {datId} is not in the active dataset.");
        Visible = visible;
    }

    public List<DatasetRelativePath> Applying(IEnumerable<DatasetRelativePath> existing)
    {
        var updated = new HashSet<DatasetRelativePath>(
            existing.Select(p => p.Validated(DatasetFileKind.Dat)));
        if (Visible)
        {
            updated.Remove(DatPath);
        }
        else
        {
            updated.Add(DatPath);
        }
        return updated.OrderBy(p => p).ToList();
    }
}
