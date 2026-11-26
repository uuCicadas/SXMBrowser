using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using SXMBrowser.AppCore;
using SXMBrowser.Core;

namespace SXMBrowser.Desktop.Controllers;

public sealed partial class AppModel
{
    public SingleSpectroscopyState SingleSpectroscopy => _singleSpectroscopy;
    public SpectroscopyAxisState SpectroscopyAxes => _axisState;
    public IReadOnlySet<Guid> SelectedSidebarSpectrumIds => _selectedSidebarSpectrumIds;

    public SpectroscopyPresentationProjection SpectroscopyProjectionForFile(Guid fileId)
    {
        IReadOnlyList<SpectroscopyGroup> groups =
            _associationResult.GroupsByFileId.TryGetValue(fileId, out IReadOnlyList<SpectroscopyGroup>? list)
                ? list
                : Array.Empty<SpectroscopyGroup>();
        IReadOnlySet<Guid> hiddenIds = _hiddenProjection?.HiddenDatIds ?? new HashSet<Guid>();
        return new SpectroscopyPresentationProjection(groups, hiddenIds);
    }

    public SpectroscopyPresentationProjection SelectedFileSpectroscopy =>
        SelectedFile is { } file
            ? SpectroscopyProjectionForFile(file.Id)
            : new SpectroscopyPresentationProjection(Array.Empty<SpectroscopyGroup>(), new HashSet<Guid>());

    public SingleSpectroscopyDrawerPresentation SingleDrawerPresentation =>
        new(SelectedFileSpectroscopy.Groups, _singleSpectroscopy.ActiveGroupId);

    public IReadOnlyList<SidebarSpectrumRow> SidebarSpectrumRows
    {
        get
        {
            var sxmById = _allFiles.ToDictionary(f => f.Id);
            IReadOnlySet<Guid> hidden = _hiddenProjection?.HiddenDatIds ?? new HashSet<Guid>();
            var rows = new List<SidebarSpectrumRow>(_spectroscopyFiles.Count);

            foreach (SpectroscopyFile spectrum in _spectroscopyFiles)
            {
                ManualSpectrumAssociationResolution manual =
                    _manualProjection?.ResolutionForDatId(spectrum.Id)
                    ?? new ManualSpectrumAssociationResolution(ManualSpectrumAssociationKind.AutomaticAllowed);

                Guid? parentId = _associationResult.ParentIdBySpectrumId.TryGetValue(spectrum.Id, out Guid pid)
                    ? pid
                    : null;
                string? parentName = parentId is { } resolvedId && sxmById.TryGetValue(resolvedId, out SXMMetadata? sxm)
                    ? sxm.Filename
                    : null;

                rows.Add(new SidebarSpectrumRow(
                    Spectrum: spectrum,
                    IsVisible: !hidden.Contains(spectrum.Id),
                    ParentSxmId: parentId,
                    ParentSxmFilename: parentName,
                    IsManualAssociation: manual.Kind == ManualSpectrumAssociationKind.Manual,
                    HasMissingManualTarget: manual.Kind == ManualSpectrumAssociationKind.MissingManualTarget,
                    MissingTargetPath: manual.SxmPath));
            }
            return rows;
        }
    }

    private void RecomputeSpectroscopyAssociationsAndWarnings(bool isInitialOpen)
    {
        if (_activeSession is null)
        {
            _manualProjection = null;
            _hiddenProjection = null;
            _associationResult = new SpectrumAssociationResult(
                new Dictionary<Guid, IReadOnlyList<SpectroscopyGroup>>(),
                new Dictionary<Guid, Guid>(),
                new HashSet<Guid>());
            _axisState = new SpectroscopyAxisState();
            return;
        }

        DatasetRecordV1 record = _activeSession.VerifiedRecord;
        var sxmIdSet = new HashSet<Guid>(_allFiles.Select(f => f.Id));

        _manualProjection = new ManualSpectrumAssociationProjection(
            record.ManualAssociations,
            _activeSession.PathIndex,
            sxmIdSet);
        _hiddenProjection = new HiddenSpectrumProjection(
            record.HiddenDATPaths,
            _activeSession.PathIndex);
        _associationResult = SpectrumAssociationResolver.AssociateSpectra(
            _spectroscopyFiles,
            _allFiles,
            _manualProjection);

        List<SpectrumAxisRuntimeGroup> allGroups = _associationResult.GroupsByFileId.Values
            .SelectMany(list => list)
            .Select(g => new SpectrumAxisRuntimeGroup(g))
            .ToList();

        var axisProjection = new SpectrumAxisPreferenceProjection(
            record.SpectrumAxisPreferences,
            allGroups,
            _activeSession.PathIndex);
        _axisState = axisProjection.AxisState;

        if (isInitialOpen)
        {
            foreach (var missing in _manualProjection.MissingTargetPathByDatId.OrderBy(kv => kv.Key))
            {
                string datName = _activeSession.PathIndex.DatPath(missing.Key)?.RawValue ?? missing.Key.ToString();
                MetadataWarnings.Append(
                    $"Manual association for \u201C{datName}\u201D references missing SXM \u201C{missing.Value.RawValue}\u201D.");
            }
            foreach (DatasetRelativePath missingDat in _hiddenProjection.MissingDatPaths)
            {
                MetadataWarnings.Append($"Hidden spectrum path \u201C{missingDat.RawValue}\u201D is no longer in this folder.");
            }
            foreach (SpectrumAxisPreferenceRestoreIssue issue in axisProjection.Issues)
            {
                MetadataWarnings.Append(issue.Description);
            }
        }

        ReconcileSingleSpectroscopyDrawer();
    }

    private void ReconcileSingleSpectroscopyDrawer()
    {
        _singleSpectroscopy.Reconcile(SelectedFileSpectroscopy.Groups);
    }

    // --- Single Spectroscopy Drawer Controls ---

    public void SetSingleSpectroscopyExpanded(bool expanded)
    {
        if (_singleSpectroscopy.IsExpanded == expanded) return;
        _singleSpectroscopy.SetExpanded(expanded);
        SavePreferences(_prefs with { SingleSpectroscopyDrawerExpanded = expanded });
        RaiseStateChanged();
    }

    public void SetSingleSpectroscopyHeight(double height)
    {
        _singleSpectroscopy.SetHeight(height);
        SavePreferences(_prefs with { SingleSpectroscopyDrawerHeight = _singleSpectroscopy.Height });
        RaiseRenderStateChanged();
    }

    public void SelectSingleSpectroscopyGroup(string groupId)
    {
        _singleSpectroscopy.ActivateGroup(groupId);
        _singleSpectroscopy.Reconcile(SelectedFileSpectroscopy.Groups);
        RaiseStateChanged();
    }

    public void FocusSpectrumInDrawer(Guid spectrumId)
    {
        SpectrumFocusPlan? plan = SpectrumFocusPlan.Resolve(spectrumId, SelectedFileSpectroscopy.Groups);
        if (plan is null) return;
        _singleSpectroscopy.ActivateGroup(plan.GroupId);
        _singleSpectroscopy.FocusSpectrum(plan.SpectrumId);
        RaiseStateChanged();
    }

    public Task SetSpectrumXColumnAsync(SpectroscopyGroup group, string xColumn) =>
        SetSpectrumAxisColumnAsync(group, SpectrumAxis.X, xColumn);

    public Task SetSpectrumYColumnAsync(SpectroscopyGroup group, string yColumn) =>
        SetSpectrumAxisColumnAsync(group, SpectrumAxis.Y, yColumn);

    private async Task SetSpectrumAxisColumnAsync(
        SpectroscopyGroup group,
        SpectrumAxis axis,
        string column)
    {
        if (_activeSession is not { } session) return;
        AxisSelection current = _axisState.EnsureSelection(
            group.Id,
            group.AvailableColumns,
            group.XLabel,
            group.YLabel) ?? new AxisSelection(group.XLabel, group.YLabel);

        var runtimeGroup = new SpectrumAxisRuntimeGroup(group);
        var plan = new SpectrumAxisPreferenceUpdatePlan(
            runtimeGroup,
            axis,
            column,
            current,
            session.PathIndex);

        if (axis == SpectrumAxis.X)
        {
            _axisState.SetXColumn(plan.Selection.XColumn, group.Id, group.AvailableColumns, group.XLabel, group.YLabel);
        }
        else
        {
            _axisState.SetYColumn(plan.Selection.YColumn, group.Id, group.AvailableColumns, group.XLabel, group.YLabel);
        }
        RaiseStateChanged();

        await UpdateVerifiedSessionAsync(record =>
        {
            List<SpectrumAxisPreferenceV1> updated = plan.Applying(record.SpectrumAxisPreferences);
            record.ReplaceSpectrumAxisPreferences(updated, DateTimeOffset.UtcNow);
        }, recomputeSpectra: false);
    }

    // --- Sidebar Spectroscopy Interactions ---

    public void ClickSidebarSpectrum(Guid spectrumId, SpectrumRowModifier modifier)
    {
        bool isVisible = _hiddenProjection is null || !_hiddenProjection.HiddenDatIds.Contains(spectrumId);
        var plan = new SpectrumRowInteractionPlan(
            _selectedSidebarSpectrumIds,
            spectrumId,
            modifier,
            isVisible);

        _selectedSidebarSpectrumIds.Clear();
        foreach (Guid id in plan.AssociationIds)
        {
            _selectedSidebarSpectrumIds.Add(id);
        }

        if (plan.ShouldFocusClickedSpectrum && _associationResult.ParentIdBySpectrumId.TryGetValue(spectrumId, out Guid parentId))
        {
            if (_selection.PrimaryId != parentId)
            {
                _selection.SelectOnly(parentId, _visibleFiles.Select(f => f.Id).ToArray());
                SyncSelectionDefaults(resetScale: true);
                if (_mode == BrowserMode.Single)
                {
                    RefreshSelectedImage(resetScale: true);
                }
            }
            FocusSpectrumInDrawer(spectrumId);
        }

        RaiseStateChanged();
    }

    public async Task ToggleSpectrumVisibilityAsync(Guid spectrumId, bool visible)
    {
        if (_activeSession is not { } session) return;
        var plan = new HiddenSpectrumUpdatePlan(spectrumId, visible, session.PathIndex);

        await UpdateVerifiedSessionAsync(record =>
        {
            List<DatasetRelativePath> updated = plan.Applying(record.HiddenDATPaths);
            record.ReplaceHiddenDATPaths(updated, DateTimeOffset.UtcNow);
        }, recomputeSpectra: true);

        RebuildVisibleProjection(fallbackSelection: false);
    }

    public async Task AssociateSpectraToSelectedSxmAsync()
    {
        if (_activeSession is not { } session || SelectedFile is not { } targetSxm || _selectedSidebarSpectrumIds.Count == 0)
        {
            return;
        }

        var datIds = _selectedSidebarSpectrumIds.ToArray();
        var plan = new ManualAssociationUpdatePlan(datIds, targetSxm.Id, session.PathIndex);

        await UpdateVerifiedSessionAsync(record =>
        {
            List<DatasetManualAssociationV1> updated = plan.Applying(record.ManualAssociations);
            record.ReplaceManualAssociations(updated, DateTimeOffset.UtcNow);
        }, recomputeSpectra: true);

        RebuildVisibleProjection(fallbackSelection: false);
        PresentToast(
            "Updated Association",
            $"Associated {datIds.Length} spectr{(datIds.Length == 1 ? "um" : "a")} with {targetSxm.Filename}.");
    }

    public async Task ResetManualAssociationsAsync(IReadOnlyList<Guid>? datIds = null)
    {
        if (_activeSession is not { } session) return;
        Guid[] targetIds = datIds is { Count: > 0 } ? datIds.ToArray() : _selectedSidebarSpectrumIds.ToArray();
        if (targetIds.Length == 0) return;

        var pathsToClear = new HashSet<DatasetRelativePath>();
        foreach (Guid id in targetIds)
        {
            if (session.PathIndex.DatPath(id) is { } p)
            {
                pathsToClear.Add(p);
            }
        }
        if (pathsToClear.Count == 0) return;

        await UpdateVerifiedSessionAsync(record =>
        {
            List<DatasetManualAssociationV1> updated = record.ManualAssociations
                .Where(a => !pathsToClear.Contains(a.DatPath))
                .ToList();
            record.ReplaceManualAssociations(updated, DateTimeOffset.UtcNow);
        }, recomputeSpectra: true);

        RebuildVisibleProjection(fallbackSelection: false);
        PresentToast("Reset Association", "Restored automatic spectroscopy matching.");
    }

    // --- Tag Management ---

    public bool IsFileTagged(Guid fileId, Guid tagId)
    {
        if (_activeSession is not { } session) return false;
        DatasetTagV1? tag = session.VerifiedRecord.Tags.FirstOrDefault(t => t.Id == tagId);
        if (tag is null) return false;
        return session.PathIndex.SxmPath(fileId) is { } p && tag.SxmPaths.Contains(p);
    }

    public IReadOnlyList<DatasetTagV1> TagsForFile(Guid fileId)
    {
        if (_activeSession is not { } session || session.PathIndex.SxmPath(fileId) is not { } path)
        {
            return Array.Empty<DatasetTagV1>();
        }
        return session.VerifiedRecord.Tags.Where(t => t.SxmPaths.Contains(path)).ToArray();
    }

    public void ToggleTagExpanded(Guid tagId)
    {
        if (!_expandedTagIds.Remove(tagId))
        {
            _expandedTagIds.Add(tagId);
        }
        if (_activeSession is not null)
        {
            SavePreferences(_prefs.WithExpandedTagIds(_activeSession.DatasetId, _expandedTagIds));
        }
        RaiseStateChanged();
    }

    public async Task CreateTagAsync(string name, IReadOnlyList<Guid>? initialFileIds = null)
    {
        if (_activeSession is not { } session) return;
        var paths = new List<DatasetRelativePath>();
        if (initialFileIds is not null)
        {
            foreach (Guid fid in initialFileIds)
            {
                if (session.PathIndex.SxmPath(fid) is { } p) paths.Add(p);
            }
        }

        Guid newTagId = Guid.NewGuid();
        await UpdateVerifiedSessionAsync(record =>
        {
            record.CreateTag(newTagId, name, paths);
        }, recomputeSpectra: false);

        if (paths.Count > 0)
        {
            _expandedTagIds.Add(newTagId);
            SavePreferences(_prefs.WithExpandedTagIds(session.DatasetId, _expandedTagIds));
        }
        RaiseStateChanged();
    }

    public async Task RenameTagAsync(Guid tagId, string newName)
    {
        if (_activeSession is null) return;
        await UpdateVerifiedSessionAsync(record =>
        {
            record.RenameTag(tagId, newName);
        }, recomputeSpectra: false);
        RaiseStateChanged();
    }

    public async Task DeleteTagAsync(Guid tagId)
    {
        if (_activeSession is null) return;
        Guid? successor = TagPresentationProjection.SuccessorTagId(tagId, Tags);

        await UpdateVerifiedSessionAsync(record =>
        {
            record.DeleteTag(tagId);
        }, recomputeSpectra: false);

        _expandedTagIds.Remove(tagId);
        if (_activeScope is BrowserScope.Tag tagScope && tagScope.TagId == tagId)
        {
            _activeScope = successor is { } s ? new BrowserScope.Tag(s) : BrowserScope.All.Instance;
            RebuildVisibleProjection(fallbackSelection: true);
        }
        else
        {
            RaiseStateChanged();
        }
    }

    public async Task MoveTagAsync(Guid sourceId, Guid targetId)
    {
        if (_activeSession is null) return;
        int? dest = TagReorderPlan.DestinationIndexForMove(sourceId, targetId, Tags);
        if (dest is not { } destinationIndex) return;

        await UpdateVerifiedSessionAsync(record =>
        {
            record.MoveTag(sourceId, destinationIndex);
        }, recomputeSpectra: false);
        RaiseStateChanged();
    }

    public async Task AssignFilesToTagAsync(IReadOnlyList<Guid> fileIds, Guid tagId, bool assign)
    {
        if (_activeSession is not { } session || fileIds.Count == 0) return;
        var targetPaths = new HashSet<DatasetRelativePath>();
        foreach (Guid fid in fileIds)
        {
            if (session.PathIndex.SxmPath(fid) is { } p) targetPaths.Add(p);
        }
        if (targetPaths.Count == 0) return;

        await UpdateVerifiedSessionAsync(record =>
        {
            DatasetTagV1? tag = record.Tags.FirstOrDefault(t => t.Id == tagId);
            if (tag is null) return;
            var nextPaths = new HashSet<DatasetRelativePath>(tag.SxmPaths);
            if (assign)
            {
                foreach (DatasetRelativePath p in targetPaths) nextPaths.Add(p);
            }
            else
            {
                foreach (DatasetRelativePath p in targetPaths) nextPaths.Remove(p);
            }
            record.ReplaceTagMembers(tagId, nextPaths);
        }, recomputeSpectra: false);

        if (_activeScope is BrowserScope.Tag tagScope && tagScope.TagId == tagId)
        {
            RebuildVisibleProjection(fallbackSelection: true);
        }
        else
        {
            RaiseStateChanged();
        }
    }

    // --- File Deletion (Recycle Bin) & Explorer Reveal ---

    public void RevealSelectedInExplorer()
    {
        if (SelectedFile is not { } file) return;
        try
        {
            _fileService.RevealInFileExplorer(file.Path);
        }
        catch (Exception ex)
        {
            PresentToast("Could not reveal file", ex.Message, NoticeSeverity.Error);
        }
    }

    public void DeleteFilesToRecycleBin(IReadOnlyList<SXMMetadata> targets)
    {
        if (targets.Count == 0) return;
        string[] paths = targets.Select(t => t.Path).ToArray();
        var removedIds = new HashSet<Guid>(targets.Select(t => t.Id));
        IReadOnlyList<Guid> oldVisibleIds = _visibleFiles.Select(f => f.Id).ToArray();

        _fileService.MoveFilesToRecycleBin(paths);

        foreach (string path in paths)
        {
            RemoveCachedData(path);
        }
        foreach (Guid id in removedIds)
        {
            _thumbnails.RemoveEntriesForFile(id);
        }

        _allFiles = _allFiles.Where(f => !removedIds.Contains(f.Id)).ToArray();
        _inventoryRevisionId = Guid.NewGuid();

        // Update path index + spectroscopy associations without deleting preserved metadata in local store.
        if (_activeSession is { } session)
        {
            var nextPathIndex = new DatasetPathIndex(session.FolderPath, _allFiles, _spectroscopyFiles);
            var updatedSession = new ActiveDatasetSession(
                session.SessionId,
                session.DatasetId,
                session.FolderPath,
                session.VerifiedRecord,
                nextPathIndex);
            _activeSession = updatedSession;
            _sessionGate.Activate(updatedSession);
            RecomputeSpectroscopyAssociationsAndWarnings(isInitialOpen: false);
        }

        // Reconcile visible list and preserve neighbor selection
        RebuildVisibleProjection(fallbackSelection: false);
        IReadOnlyList<Guid> newVisibleIds = _visibleFiles.Select(f => f.Id).ToArray();
        _selection.ReconcileAfterRemoval(removedIds, oldVisibleIds, newVisibleIds);
        SyncSelectionDefaults(resetScale: true);

        if (_mode == BrowserMode.Single)
        {
            if (SelectedFile is not null)
            {
                RefreshSelectedImage(resetScale: true);
            }
            else
            {
                _mode = BrowserMode.Grid;
                InvalidateActiveRender(clearFrame: true);
            }
        }

        RaiseStateChanged();
        PresentToast(
            "Moved to Recycle Bin",
            $"Moved {targets.Count} scan file{(targets.Count == 1 ? "" : "s")} to Recycle Bin.");
    }

    // --- Metadata Export / Import ---

    public async Task ExportMetadataAsync(string outputPath, CancellationToken ct = default)
    {
        if (_activeSession is not { } session)
        {
            throw new InvalidOperationException("No active dataset is open.");
        }

        var transfer = new DatasetMetadataTransferV1(session.VerifiedRecord);
        var codec = new DatasetMetadataTransferCodec();
        byte[] bytes = codec.Encode(transfer);
        await File.WriteAllBytesAsync(outputPath, bytes, ct).ConfigureAwait(false);
        _dispatchToUi(() => PresentToast("Exported Metadata", Path.GetFileName(outputPath)));
    }

    public MetadataImportWorkflow PrepareMetadataImport(
        string sourceFilePath,
        DatasetMetadataImportPolicy? policy = null)
    {
        if (_activeSession is not { } session)
        {
            throw new InvalidOperationException("Open a dataset folder before importing metadata.");
        }

        DatasetMetadataImportPolicy resolvedPolicy = policy ?? DatasetMetadataImportPolicy.SafeDefault;
        var codec = new DatasetMetadataTransferCodec();
        DatasetMetadataTransferV1 transfer = codec.DecodeFromFile(sourceFilePath);
        DatasetMetadataImportInventory inventory = BuildImportInventory(session);
        DatasetInventorySignature signature = BuildInventorySignature(session);

        var planner = new DatasetMetadataImportPlanner();
        DatasetMetadataImportPlan plan = planner.Plan(
            transfer,
            session.VerifiedRecord,
            inventory,
            resolvedPolicy);

        return new MetadataImportWorkflow(
            Id: Guid.NewGuid(),
            SourceFilePath: sourceFilePath,
            SessionIdentity: session.Identity,
            Inventory: inventory,
            FileSignature: signature,
            Transfer: transfer,
            Policy: resolvedPolicy,
            Plan: plan,
            Phase: MetadataImportWorkflowPhase.Preview);
    }

    public MetadataImportWorkflow ReplanMetadataImport(
        MetadataImportWorkflow workflow,
        DatasetMetadataImportPolicy nextPolicy)
    {
        if (_activeSession is not { } session
            || !session.Matches(workflow.SessionIdentity)
            || workflow.Transfer is null
            || workflow.Inventory is null)
        {
            throw new InvalidOperationException("The active dataset changed after the import preview was opened.");
        }

        var planner = new DatasetMetadataImportPlanner();
        DatasetMetadataImportPlan plan = planner.Plan(
            workflow.Transfer,
            session.VerifiedRecord,
            workflow.Inventory,
            nextPolicy);

        return workflow with
        {
            Policy = nextPolicy,
            Plan = plan
        };
    }

    public async Task ApplyMetadataImportAsync(MetadataImportWorkflow workflow, CancellationToken ct = default)
    {
        if (_activeSession is not { } session || !session.Matches(workflow.SessionIdentity))
        {
            throw new InvalidOperationException("The active dataset changed before import could be applied.");
        }
        if (workflow.Plan is not { } plan)
        {
            throw new InvalidOperationException("No import plan is available.");
        }

        DatasetMetadataImportInventory currentInventory = BuildImportInventory(session);
        DatasetRecordV1 nextRecord = plan.Applying(session.VerifiedRecord, currentInventory, DateTimeOffset.UtcNow);

        DatasetRecordV1 verified = await _metadataStore.UpdateDatasetAsync(session.DatasetId, record =>
        {
            record.Tags.Clear();
            record.Tags.AddRange(nextRecord.Tags);
            record.ReplaceManualAssociations(nextRecord.ManualAssociations, nextRecord.UpdatedAt);
            record.ReplaceHiddenDATPaths(nextRecord.HiddenDATPaths, nextRecord.UpdatedAt);
            record.ReplaceSpectrumAxisPreferences(nextRecord.SpectrumAxisPreferences, nextRecord.UpdatedAt);
        }, nextRecord.UpdatedAt, ct).ConfigureAwait(false);

        var nextSession = new ActiveDatasetSession(
            session.SessionId,
            verified.Id,
            session.FolderPath,
            verified,
            session.PathIndex);

        await _invokeOnUiAsync(() =>
        {
            if (!_sessionGate.Activate(nextSession)) return;
            _activeSession = nextSession;
            RecomputeSpectroscopyAssociationsAndWarnings(isInitialOpen: false);
            RebuildVisibleProjection(fallbackSelection: false);
            PresentToast("Imported Metadata", $"Applied {plan.Summary.ActionCount} metadata update(s).");
        }).ConfigureAwait(false);
    }

    private DatasetMetadataImportInventory BuildImportInventory(ActiveDatasetSession session)
    {
        var sxmPaths = _allFiles
            .Select(f => session.PathIndex.SxmPath(f.Id))
            .Where(p => p is not null)
            .Select(p => p!)
            .ToArray();

        var sxmById = _allFiles.ToDictionary(f => f.Id);
        var sxmByTime = _allFiles.OrderBy(f => f.ModifiedTime)
            .ThenBy(f => f.Filename, NaturalStringComparer.Instance)
            .ToArray();
        var sxmByName = _allFiles.OrderByDescending(f => Path.GetFileNameWithoutExtension(f.Path).Length).ToArray();

        var datFiles = new List<DatasetMetadataImportDatFile>(_spectroscopyFiles.Count);
        foreach (SpectroscopyFile dat in _spectroscopyFiles)
        {
            if (session.PathIndex.DatPath(dat.Id) is not { } datPath) continue;
            SXMMetadata? autoParent = SpectrumAssociationResolver.AutomaticSpectrumParent(dat, sxmByTime, sxmByName);
            DatasetRelativePath? autoParentPath = autoParent is not null
                ? session.PathIndex.SxmPath(autoParent.Id)
                : null;

            datFiles.Add(new DatasetMetadataImportDatFile(
                datPath,
                dat.Kind,
                dat.Experiment,
                dat.ExperimentIdentity,
                dat.Curve.ColumnSchema.Fingerprint,
                dat.Curve.Columns,
                autoParentPath));
        }

        return new DatasetMetadataImportInventory(
            _inventoryRevisionId,
            session.SessionId,
            session.DatasetId,
            sxmPaths,
            datFiles);
    }

    private DatasetInventorySignature BuildInventorySignature(ActiveDatasetSession session)
    {
        var stamps = new List<DatasetInventoryFileStamp>(_allFiles.Count + _spectroscopyFiles.Count);
        foreach (SXMMetadata sxm in _allFiles)
        {
            if (session.PathIndex.SxmPath(sxm.Id) is not { } p) continue;
            var info = new FileInfo(sxm.Path);
            stamps.Add(new DatasetInventoryFileStamp(p, info.Exists ? (ulong)info.Length : 0UL, sxm.ModifiedTime));
        }
        foreach (SpectroscopyFile dat in _spectroscopyFiles)
        {
            if (session.PathIndex.DatPath(dat.Id) is not { } p) continue;
            var info = new FileInfo(dat.Path);
            stamps.Add(new DatasetInventoryFileStamp(p, info.Exists ? (ulong)info.Length : 0UL, dat.ModifiedTime));
        }
        return new DatasetInventorySignature(stamps);
    }

    // --- Shared Session Store Mutation ---

    private async Task UpdateVerifiedSessionAsync(
        Action<DatasetRecordV1> mutation,
        bool recomputeSpectra)
    {
        if (_activeSession is not { } session) return;
        DatasetRecordV1 verified = await _metadataStore.UpdateDatasetAsync(
            session.DatasetId,
            mutation).ConfigureAwait(false);

        var updatedSession = new ActiveDatasetSession(
            session.SessionId,
            verified.Id,
            session.FolderPath,
            verified,
            session.PathIndex);

        await _invokeOnUiAsync(() =>
        {
            if (!_sessionGate.Activate(updatedSession)) return;
            _activeSession = updatedSession;
            if (recomputeSpectra)
            {
                RecomputeSpectroscopyAssociationsAndWarnings(isInitialOpen: false);
            }
            RaiseStateChanged();
        }).ConfigureAwait(false);
    }
}
