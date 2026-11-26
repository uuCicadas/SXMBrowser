using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Services;

namespace SXMBrowser.Desktop.Controllers;

public sealed record SidebarSpectrumRow(
    SpectroscopyFile Spectrum,
    bool IsVisible,
    Guid? ParentSxmId,
    string? ParentSxmFilename,
    bool IsManualAssociation,
    bool HasMissingManualTarget,
    DatasetRelativePath? MissingTargetPath);

public sealed partial class AppModel : INotifyPropertyChanged
{
    private readonly SXMParser _sxmParser = new();
    private readonly SpectroscopyParser _spectroscopyParser = new();
    private readonly DatasetMetadataStore _metadataStore;
    private readonly BrowserPreferencesStore _preferencesStore;
    private readonly IPlatformFileService _fileService;
    private readonly RenderCoordinator<WriteableBitmap> _renderCoordinator;
    private readonly ThumbnailPipeline _thumbnails;
    private readonly DatasetSessionGate _sessionGate = new();
    private readonly Action<Action> _dispatchToUi;
    private readonly Func<Action, Task> _invokeOnUiAsync;

    private readonly SelectionState<Guid> _selection = new();
    private readonly HashSet<Guid> _selectedSidebarSpectrumIds = [];
    private HashSet<Guid> _expandedTagIds = [];

    private CancellationTokenSource? _openCts;
    private CancellationTokenSource? _toastDismissCts;
    private Guid? _renderFailureNoticeId;
    private Guid? _datasetFailureNoticeId;
    private Guid? _scanIssueNoticeId;

    private BrowserPreferencesSnapshot _prefs;

    // Dataset state
    private DatasetLoadState _datasetState = DatasetLoadState.Idle.Instance;
    private string? _folderPath;
    private ActiveDatasetSession? _activeSession;
    private Guid _inventoryRevisionId = Guid.NewGuid();
    private IReadOnlyList<SXMMetadata> _allFiles = Array.Empty<SXMMetadata>();
    private IReadOnlyList<SpectroscopyFile> _spectroscopyFiles = Array.Empty<SpectroscopyFile>();
    private IReadOnlyList<ScanIssue> _scanIssues = Array.Empty<ScanIssue>();
    private IReadOnlyList<SXMMetadata> _visibleFiles = Array.Empty<SXMMetadata>();
    private IReadOnlyList<GridBrowserItem> _gridItems = Array.Empty<GridBrowserItem>();
    private SpectrumAssociationResult _associationResult = new(
        new Dictionary<Guid, IReadOnlyList<SpectroscopyGroup>>(),
        new Dictionary<Guid, Guid>(),
        new HashSet<Guid>());
    private ManualSpectrumAssociationProjection? _manualProjection;
    private HiddenSpectrumProjection? _hiddenProjection;
    private SpectroscopyAxisState _axisState = new();

    // Navigation & filter state
    private BrowserMode _mode = BrowserMode.Grid;
    private BrowserScope _activeScope = BrowserScope.All.Instance;
    private string _searchQuery = string.Empty;
    private string _status = "Open a folder to browse Nanonis .sxm and .dat files.";
    private bool _sidebarVisible;
    private bool _inspectorVisible;
    private double _sidebarWidth;
    private double _inspectorWidth;
    private GridDensity _gridDensity;
    private bool _showsGridSpectroscopyCards;
    private FileSortCriterion _sortCriterion;
    private bool _sortAscending;
    private ThemeAppearanceMode _themeMode;

    // Single spectroscopy drawer state
    private readonly SingleSpectroscopyState _singleSpectroscopy;

    // Viewer & Render state
    private string _selectedChannel = string.Empty;
    private ScanDirection _selectedDirection = ScanDirection.Fwd;
    private ProcessingMode _selectedProcessing = ProcessingMode.PlaneLinear;
    private PaletteName _selectedPalette = PaletteName.Gwyddion;
    private PaletteName _stmPreviewPalette = PaletteName.Gwyddion;
    private bool _invertPalette;
    private ScalePreset _scalePreset = ScalePreset.Full;
    private int _histogramBins = 256;
    private bool _scaleLocked;
    private double? _scaleMin;
    private double? _scaleMax;
    private CoordinatorRenderedFrame<WriteableBitmap>? _renderedFrame;
    private SelectedRenderState<Guid> _selectedRenderState = SelectedRenderState<Guid>.Idle.Instance;
    private ViewerTransform _viewerTransform = ViewerTransform.CreateDefault();
    private RenderRequestIdentity<Guid>? _inFlightCoalescedRequest;
    private bool _hasPendingScaleRender;
    private readonly object _frequencyShiftBoundsLock = new();
    private readonly Dictionary<FrequencyShiftBoundsKey, FrequencyShiftBounds?> _frequencyShiftBoundsCache = new();

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? StateChanged;
    public event Action? RenderStateChanged;
    public event Action? ThumbnailsInvalidated;

    public NoticePresentationState NoticeState { get; } = new();
    public MetadataWarningPresentationState MetadataWarnings { get; } = new();

    public AppModel(
        DatasetMetadataStore? metadataStore = null,
        BrowserPreferencesStore? preferencesStore = null,
        IPlatformFileService? fileService = null,
        IRenderBackend<WriteableBitmap>? renderBackend = null,
        Action<Action>? dispatchToUi = null,
        Func<Action, Task>? invokeOnUiAsync = null,
        ISxmMatrixReader? matrixReader = null)
    {
        _metadataStore = metadataStore ?? new DatasetMetadataStore();
        _preferencesStore = preferencesStore ?? new BrowserPreferencesStore();
        _fileService = fileService ?? new PlatformFileIntegration();
        _dispatchToUi = dispatchToUi ?? DefaultDispatchToUi;
        _invokeOnUiAsync = invokeOnUiAsync ?? (dispatchToUi is not null
            ? action => { dispatchToUi(action); return Task.CompletedTask; }
            : DefaultInvokeOnUiAsync);

        _prefs = _preferencesStore.Load();
        _stmPreviewPalette = _prefs.StmPreviewPalette;
        _selectedPalette = _prefs.StmPreviewPalette;
        _sortCriterion = _prefs.SortCriterion;
        _sortAscending = _prefs.SortAscending;
        _sidebarVisible = _prefs.SidebarVisible;
        _inspectorVisible = _prefs.InspectorVisible;
        _sidebarWidth = _prefs.SidebarWidth;
        _inspectorWidth = _prefs.InspectorWidth;
        _histogramBins = _prefs.HistogramBins;
        _gridDensity = _prefs.GridDensity;
        _showsGridSpectroscopyCards = _prefs.ShowsGridSpectroscopyCards;
        _themeMode = _prefs.ThemeMode;
        _singleSpectroscopy = new SingleSpectroscopyState(
            isExpanded: _prefs.SingleSpectroscopyDrawerExpanded,
            height: _prefs.SingleSpectroscopyDrawerHeight);

        _thumbnails = new ThumbnailPipeline(_sxmParser);
        _renderCoordinator = new RenderCoordinator<WriteableBitmap>(
            matrixReader ?? new DefaultSxmMatrixReader(_sxmParser),
            renderBackend ?? new AvaloniaRenderBackend(),
            dispatchToUi: _dispatchToUi);
        _renderCoordinator.OnEvent = HandleRenderCoordinatorEvent;
    }

    private static void DefaultDispatchToUi(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess())
        {
            action();
        }
        else
        {
            Dispatcher.UIThread.Post(action);
        }
    }

    private static async Task DefaultInvokeOnUiAsync(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess())
        {
            action();
            return;
        }
        await Dispatcher.UIThread.InvokeAsync(action);
    }

    // --- Public Properties ---

    public DatasetLoadState DatasetState
    {
        get => _datasetState;
        private set => SetField(ref _datasetState, value);
    }

    public string? FolderPath => _folderPath;
    public string FolderName => string.IsNullOrEmpty(_folderPath)
        ? "No Folder Open"
        : (Path.GetFileName(_folderPath) is { Length: > 0 } name ? name : _folderPath);

    public ActiveDatasetSession? ActiveSession => _activeSession;
    public DatasetRecordV1? ActiveDatasetRecord => _activeSession?.VerifiedRecord;
    public IReadOnlyList<DatasetTagV1> Tags =>
        (IReadOnlyList<DatasetTagV1>?)_activeSession?.VerifiedRecord.Tags ?? Array.Empty<DatasetTagV1>();
    public IReadOnlySet<Guid> ExpandedTagIds => _expandedTagIds;

    public IReadOnlyList<SXMMetadata> AllFiles => _allFiles;
    public IReadOnlyList<SXMMetadata> VisibleFiles => _visibleFiles;
    public IReadOnlyList<GridBrowserItem> GridItems => _gridItems;
    public IReadOnlyList<SpectroscopyFile> SpectroscopyFiles => _spectroscopyFiles;
    public IReadOnlyList<ScanIssue> ScanIssues => _scanIssues;

    public Guid? SelectedId => _selection.PrimaryId;
    public IReadOnlySet<Guid> SelectedIds => _selection.SelectedIds;
    public SXMMetadata? SelectedFile =>
        _selection.PrimaryId is { } sid ? _allFiles.FirstOrDefault(f => f.Id == sid) : null;
    public IReadOnlyList<SXMMetadata> SelectedFiles
    {
        get
        {
            if (_selection.SelectedIds.Count == 0) return Array.Empty<SXMMetadata>();
            return _visibleFiles.Where(f => _selection.SelectedIds.Contains(f.Id)).ToArray();
        }
    }

    public SelectionActionPresentation<Guid> SelectionActionBar =>
        new(_visibleFiles.Select(f => f.Id).ToArray(), _selection.SelectedIds);

    public BrowserMode Mode => _mode;
    public BrowserScope ActiveScope => _activeScope;
    public bool SearchIsActive => !string.IsNullOrWhiteSpace(_searchQuery);

    public string SearchQuery
    {
        get => _searchQuery;
        set
        {
            if (string.Equals(_searchQuery, value, StringComparison.Ordinal)) return;
            _searchQuery = value;
            OnPropertyChanged();
            RebuildVisibleProjection(fallbackSelection: true);
        }
    }

    public string Status
    {
        get => _status;
        private set => SetField(ref _status, value);
    }

    public bool SidebarVisible
    {
        get => _sidebarVisible;
        set
        {
            if (SetField(ref _sidebarVisible, value))
            {
                SavePreferences(_prefs with { SidebarVisible = value });
                RaiseStateChanged();
            }
        }
    }

    public bool InspectorVisible
    {
        get => _inspectorVisible;
        set
        {
            if (SetField(ref _inspectorVisible, value))
            {
                SavePreferences(_prefs with { InspectorVisible = value });
                RaiseStateChanged();
            }
        }
    }

    public double SidebarWidth
    {
        get => _sidebarWidth;
        set
        {
            double clamped = Math.Min(NativePaneLayout.SidebarMaxWidth, Math.Max(NativePaneLayout.SidebarMinWidth, value));
            if (Math.Abs(_sidebarWidth - clamped) > 0.5)
            {
                _sidebarWidth = clamped;
                OnPropertyChanged();
                SavePreferences(_prefs with { SidebarWidth = clamped });
            }
        }
    }

    public double InspectorWidth
    {
        get => _inspectorWidth;
        set
        {
            double clamped = Math.Min(NativePaneLayout.InspectorMaxWidth, Math.Max(NativePaneLayout.InspectorMinWidth, value));
            if (Math.Abs(_inspectorWidth - clamped) > 0.5)
            {
                _inspectorWidth = clamped;
                OnPropertyChanged();
                SavePreferences(_prefs with { InspectorWidth = clamped });
            }
        }
    }

    public GridDensity GridDensity
    {
        get => _gridDensity;
        set
        {
            if (SetField(ref _gridDensity, value))
            {
                SavePreferences(_prefs with { GridDensity = value });
                RaiseStateChanged();
            }
        }
    }

    public bool ShowsGridSpectroscopyCards
    {
        get => _showsGridSpectroscopyCards;
        set
        {
            if (SetField(ref _showsGridSpectroscopyCards, value))
            {
                SavePreferences(_prefs with { ShowsGridSpectroscopyCards = value });
                RebuildVisibleProjection(fallbackSelection: false);
            }
        }
    }

    public FileSortCriterion SortCriterion
    {
        get => _sortCriterion;
        set
        {
            if (SetField(ref _sortCriterion, value))
            {
                SavePreferences(_prefs with { SortCriterion = value });
                ResortAndRebuild();
            }
        }
    }

    public bool SortAscending
    {
        get => _sortAscending;
        set
        {
            if (SetField(ref _sortAscending, value))
            {
                SavePreferences(_prefs with { SortAscending = value });
                ResortAndRebuild();
            }
        }
    }

    public ThemeAppearanceMode ThemeMode
    {
        get => _themeMode;
        set
        {
            if (SetField(ref _themeMode, value))
            {
                SavePreferences(_prefs with { ThemeMode = value });
                RaiseStateChanged();
            }
        }
    }

    public BrowserContentState<Guid> ContentState => BrowserContentProjection.Resolve(
        _datasetState,
        _allFiles.Count,
        _visibleFiles.Count,
        SearchIsActive,
        _mode == BrowserMode.Single,
        _selection.PrimaryId,
        _selectedRenderState);

    public string? LastOpenedFolderPath => _prefs.LastOpenedFolderPath;
    public Guid DatasetRevision => _renderCoordinator.DatasetRevision;

    public void SetFilesForTesting(IReadOnlyList<SXMMetadata> files)
    {
        _allFiles = files.ToArray();
        _visibleFiles = _allFiles;
        _gridItems = _visibleFiles.Select(f => (GridBrowserItem)new GridBrowserItem.Sxm(f)).ToArray();
        _selection.Clear();
        RaiseStateChanged();
    }

    public void ResetDatasetRevision(Guid? revision = null)
    {
        _renderCoordinator.BeginDataset(revision);
        ClearFrequencyShiftBoundsCache();
    }

    // --- Folder Open & Rescan ---

    public async Task OpenFolderAsync(string folderPath, bool isRescan = false)
    {
        if (string.IsNullOrWhiteSpace(folderPath)) return;
        string canonicalPath;
        try
        {
            canonicalPath = DatasetMetadataStore.StandardizedFolderPath(folderPath);
        }
        catch (Exception ex)
        {
            PresentDatasetFailure($"Invalid folder path: {ex.Message}");
            return;
        }

        _openCts?.Cancel();
        _openCts?.Dispose();
        var cts = new CancellationTokenSource();
        _openCts = cts;
        CancellationToken ct = cts.Token;

        Guid sessionId = _sessionGate.Begin();
        bool sameFolder = string.Equals(_folderPath, canonicalPath,
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

        if (!isRescan || !sameFolder)
        {
            _activeScope = BrowserScope.All.Instance;
            _mode = BrowserMode.Grid;
            _selection.Clear();
            _selectedSidebarSpectrumIds.Clear();
            _axisState = new SpectroscopyAxisState();
        }

        _folderPath = canonicalPath;
        ClearDatasetNotices();
        MetadataWarnings.Reset();
        InvalidateActiveRender(clearFrame: true);
        _renderCoordinator.BeginDataset();
        ClearFrequencyShiftBoundsCache();
        _thumbnails.Reset(_renderCoordinator.DatasetRevision);
        DatasetState = DatasetLoadState.Loading.Instance;
        Status = $"Scanning {FolderName}...";
        RaiseStateChanged();

        try
        {
            (ScanReport<SXMMetadata> sxmReport, ScanReport<SpectroscopyFile> datReport) =
                await Task.Run(() =>
                {
                    ct.ThrowIfCancellationRequested();
                    ScanReport<SXMMetadata> s = _sxmParser.ScanFolder(canonicalPath, ct);
                    ct.ThrowIfCancellationRequested();
                    ScanReport<SpectroscopyFile> d = _spectroscopyParser.ScanFolder(canonicalPath, ct);
                    return (s, d);
                }, ct).ConfigureAwait(false);

            DatasetRecordV1 record = await _metadataStore.FindOrCreateDatasetAsync(
                canonicalPath,
                ct: ct).ConfigureAwait(false);

            var pathIndex = new DatasetPathIndex(canonicalPath, sxmReport.Items, datReport.Items);
            var session = new ActiveDatasetSession(
                sessionId,
                record.Id,
                canonicalPath,
                record,
                pathIndex);

            await _invokeOnUiAsync(() =>
            {
                if (ct.IsCancellationRequested || !_sessionGate.Activate(session))
                {
                    return;
                }

                ApplyOpenedDataset(session, sxmReport, datReport, preserveSelection: isRescan && sameFolder);
            }).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            await _invokeOnUiAsync(() =>
            {
                if (ct.IsCancellationRequested || !_sessionGate.AcceptsOpeningResult(sessionId))
                {
                    return;
                }
                _activeSession = null;
                _allFiles = Array.Empty<SXMMetadata>();
                _spectroscopyFiles = Array.Empty<SpectroscopyFile>();
                _visibleFiles = Array.Empty<SXMMetadata>();
                _gridItems = Array.Empty<GridBrowserItem>();
                DatasetState = new DatasetLoadState.Failed(ex.Message);
                PresentDatasetFailure(ex.Message);
                RaiseStateChanged();
            }).ConfigureAwait(false);
        }
    }

    public Task RescanAsync()
    {
        if (string.IsNullOrEmpty(_folderPath)) return Task.CompletedTask;
        return OpenFolderAsync(_folderPath, isRescan: true);
    }

    private void ApplyOpenedDataset(
        ActiveDatasetSession session,
        ScanReport<SXMMetadata> sxmReport,
        ScanReport<SpectroscopyFile> datReport,
        bool preserveSelection)
    {
        _activeSession = session;
        _inventoryRevisionId = Guid.NewGuid();
        Guid? prevSelectedId = preserveSelection ? _selection.PrimaryId : null;
        string? prevFilename = prevSelectedId is { } pid
            ? _allFiles.FirstOrDefault(f => f.Id == pid)?.Filename
            : null;

        _allFiles = SortFiles(sxmReport.Items);
        _spectroscopyFiles = datReport.Items
            .OrderBy(s => s.Filename, NaturalStringComparer.Instance)
            .ThenBy(s => s.Path, StringComparer.Ordinal)
            .ToArray();

        _scanIssues = sxmReport.Issues.Concat(datReport.Issues).ToArray();
        _expandedTagIds = TagPresentationProjection.FilteredExpandedTagIds(
            _prefs.GetExpandedTagIds(session.DatasetId),
            session.VerifiedRecord.Tags);

        SavePreferences(_prefs with { LastOpenedFolderPath = session.FolderPath });

        if (_activeScope is BrowserScope.Tag tagScope
            && TagPresentationProjection.ReconciledActiveTagId(tagScope.TagId, session.VerifiedRecord.Tags) is null)
        {
            _activeScope = BrowserScope.All.Instance;
        }

        DatasetState = DatasetLoadState.Ready.Instance;
        RecomputeSpectroscopyAssociationsAndWarnings(isInitialOpen: true);

        if (_scanIssues.Count > 0)
        {
            _scanIssueNoticeId = PresentBanner(
                title: $"{_scanIssues.Count} file issue{(_scanIssues.Count == 1 ? "" : "s")} skipped during scan",
                message: _scanIssues[0].Reason,
                severity: NoticeSeverity.Warning,
                actions: [NoticeAction.ShowScanIssues]);
        }

        RebuildVisibleProjection(fallbackSelection: false);

        if (preserveSelection && prevFilename is not null)
        {
            SXMMetadata? matched = _visibleFiles.FirstOrDefault(
                f => string.Equals(f.Filename, prevFilename, StringComparison.Ordinal));
            if (matched is not null)
            {
                _selection.SelectOnly(matched.Id, _visibleFiles.Select(f => f.Id).ToArray());
                SyncSelectionDefaults(resetScale: true);
            }
        }
        else if (_visibleFiles.Count > 0)
        {
            _selection.SelectOnly(_visibleFiles[0].Id, _visibleFiles.Select(f => f.Id).ToArray());
            SyncSelectionDefaults(resetScale: true);
        }

        Status = $"{_allFiles.Count} scan{(_allFiles.Count == 1 ? "" : "s")}, {_spectroscopyFiles.Count} spectr{(_spectroscopyFiles.Count == 1 ? "um" : "a")}";
        RaiseStateChanged();

        if (_mode == BrowserMode.Single && SelectedFile is not null)
        {
            RefreshSelectedImage(resetScale: true);
        }
    }

    // --- Sorting, Scope, Search, Selection ---

    public void SetScope(BrowserScope scope)
    {
        if (Equals(_activeScope, scope)) return;
        _activeScope = scope;
        RebuildVisibleProjection(fallbackSelection: true);
    }

    public void SelectAll()
    {
        _selection.SelectAll(_visibleFiles.Select(f => f.Id).ToArray());
        SyncSelectionDefaults(resetScale: true);
        RaiseStateChanged();
    }

    public void ClearSelection()
    {
        _selection.Clear();
        InvalidateActiveRender(clearFrame: true);
        RaiseStateChanged();
    }

    public void SelectOnly(Guid id)
    {
        _selection.SelectOnly(id, _visibleFiles.Select(f => f.Id).ToArray());
        SyncSelectionDefaults(resetScale: true);
        RaiseStateChanged();
        if (_mode == BrowserMode.Single)
        {
            RefreshSelectedImage(resetScale: true);
        }
    }

    public void ToggleSelection(Guid id)
    {
        _selection.Toggle(id, _visibleFiles.Select(f => f.Id).ToArray());
        SyncSelectionDefaults(resetScale: true);
        RaiseStateChanged();
        if (_mode == BrowserMode.Single)
        {
            RefreshSelectedImage(resetScale: true);
        }
    }

    public void SelectRange(Guid toId)
    {
        _selection.SelectRange(toId, _visibleFiles.Select(f => f.Id).ToArray());
        SyncSelectionDefaults(resetScale: true);
        RaiseStateChanged();
        if (_mode == BrowserMode.Single)
        {
            RefreshSelectedImage(resetScale: true);
        }
    }

    public void StepSelection(int delta)
    {
        IReadOnlyList<Guid> ids = _visibleFiles.Select(f => f.Id).ToArray();
        if (!_selection.CanStep(delta, ids)) return;
        _selection.Step(delta, ids);
        SyncSelectionDefaults(resetScale: true);
        RaiseStateChanged();
        if (_mode == BrowserMode.Single)
        {
            RefreshSelectedImage(resetScale: true);
        }
    }

    public bool CanStepSelection(int delta) =>
        _selection.CanStep(delta, _visibleFiles.Select(f => f.Id).ToArray());

    public void MoveGridSelection(GridNavigationDirection direction, int columnCount, bool extendSelection)
    {
        IReadOnlyList<Guid> visibleIds = _visibleFiles.Select(f => f.Id).ToArray();
        if (visibleIds.Count == 0) return;

        IReadOnlyList<Guid?> itemIds = _gridItems.Select<GridBrowserItem, Guid?>(item => item switch
        {
            GridBrowserItem.Sxm s => s.File.Id,
            _ => null
        }).ToArray();

        Guid? target = AdaptiveGridNavigation.TargetFileId(
            _selection.PrimaryId,
            direction,
            columnCount,
            itemIds);

        if (target is not { } targetId) return;
        if (extendSelection)
        {
            _selection.SelectRange(targetId, visibleIds);
        }
        else
        {
            _selection.SelectOnly(targetId, visibleIds);
        }
        SyncSelectionDefaults(resetScale: true);
        RaiseStateChanged();
    }

    public void OpenSingleView(Guid? fileId = null, string? groupId = null)
    {
        if (fileId is { } id)
        {
            _selection.SelectOnly(id, _visibleFiles.Select(f => f.Id).ToArray());
        }
        else if (_selection.PrimaryId is null && _visibleFiles.Count > 0)
        {
            _selection.SelectOnly(_visibleFiles[0].Id, _visibleFiles.Select(f => f.Id).ToArray());
        }

        _mode = BrowserMode.Single;
        SyncSelectionDefaults(resetScale: true);
        if (!string.IsNullOrEmpty(groupId))
        {
            _singleSpectroscopy.ActivateGroup(groupId);
        }
        ReconcileSingleSpectroscopyDrawer();
        RaiseStateChanged();
        RefreshSelectedImage(resetScale: true);
    }

    public void ShowGridView()
    {
        if (_mode == BrowserMode.Grid) return;
        _mode = BrowserMode.Grid;
        InvalidateActiveRender(clearFrame: true);
        RaiseStateChanged();
    }

    private void ResortAndRebuild()
    {
        _allFiles = SortFiles(_allFiles);
        RebuildVisibleProjection(fallbackSelection: true);
    }

    private IReadOnlyList<SXMMetadata> SortFiles(IReadOnlyList<SXMMetadata> files)
    {
        var valuesByFile = new Dictionary<Guid, FileSortValue>(files.Count);
        foreach (SXMMetadata f in files)
        {
            valuesByFile[f.Id] = new FileSortValue(f.Path, f.Filename, f.ModifiedTime, f.RecordedTime);
        }
        var sorted = files.ToList();
        sorted.Sort((a, b) => FileSortComparator.Compare(
            valuesByFile[a.Id],
            valuesByFile[b.Id],
            _sortCriterion,
            _sortAscending));
        return sorted;
    }

    private void RebuildVisibleProjection(bool fallbackSelection)
    {
        IEnumerable<SXMMetadata> scoped = _allFiles;
        if (_activeScope is BrowserScope.Tag tagScope && _activeSession is not null)
        {
            DatasetTagV1? tag = _activeSession.VerifiedRecord.Tags.FirstOrDefault(t => t.Id == tagScope.TagId);
            if (tag is not null)
            {
                var taggedIds = new HashSet<Guid>();
                foreach (DatasetRelativePath p in tag.SxmPaths)
                {
                    if (_activeSession.PathIndex.SxmId(p) is { } id)
                    {
                        taggedIds.Add(id);
                    }
                }
                scoped = scoped.Where(f => taggedIds.Contains(f.Id));
            }
            else
            {
                _activeScope = BrowserScope.All.Instance;
            }
        }

        var scopedList = scoped.ToList();
        var candidates = scopedList.Select(f =>
        {
            var groups = _associationResult.GroupsByFileId.TryGetValue(f.Id, out var gList)
                ? gList
                : Array.Empty<SpectroscopyGroup>();
            var datNames = groups
                .SelectMany(g => g.Spectra)
                .Select(s => s.Filename)
                .Distinct(StringComparer.Ordinal)
                .ToArray();
            return new FilenameSearchCandidate<Guid>(f.Id, f.Filename, datNames);
        }).ToArray();

        var search = new FilenameSearchProjection<Guid>(_searchQuery, candidates);
        var matchSet = new HashSet<Guid>(search.MatchingIds);
        _visibleFiles = scopedList.Where(f => matchSet.Contains(f.Id)).ToArray();

        // Build interleaved GridItems
        var items = new List<GridBrowserItem>(_visibleFiles.Count * 2);
        foreach (SXMMetadata file in _visibleFiles)
        {
            items.Add(new GridBrowserItem.Sxm(file));
            if (_showsGridSpectroscopyCards)
            {
                SpectroscopyPresentationProjection proj = SpectroscopyProjectionForFile(file.Id);
                foreach (PresentedSpectroscopyGroup group in proj.GridGroups)
                {
                    items.Add(new GridBrowserItem.Spectroscopy(group));
                }
            }
        }
        _gridItems = items;

        Guid? prevPrimary = _selection.PrimaryId;
        _selection.Reconcile(_visibleFiles.Select(f => f.Id).ToArray(), fallbackSelection);
        if (_selection.PrimaryId != prevPrimary)
        {
            SyncSelectionDefaults(resetScale: true);
            if (_mode == BrowserMode.Single)
            {
                RefreshSelectedImage(resetScale: true);
            }
        }
        ReconcileSingleSpectroscopyDrawer();
        RaiseStateChanged();
    }

    // --- Helpers ---

    private void SavePreferences(BrowserPreferencesSnapshot next)
    {
        _prefs = next;
        try
        {
            _preferencesStore.Save(next);
        }
        catch
        {
        }
    }

    private Guid PresentBanner(
        string title,
        string message,
        NoticeSeverity severity,
        IReadOnlyList<NoticeAction>? actions = null)
    {
        var notice = new UserNotice(title, message, severity, actions);
        NoticeState.PresentBanner(notice);
        OnPropertyChanged(nameof(NoticeState));
        RaiseStateChanged();
        return notice.Id;
    }

    public void PresentToast(
        string title,
        string message,
        NoticeSeverity severity = NoticeSeverity.Success,
        TimeSpan? duration = null)
    {
        _toastDismissCts?.Cancel();
        _toastDismissCts?.Dispose();
        var notice = new UserNotice(title, message, severity);
        NoticeState.PresentToast(notice);
        OnPropertyChanged(nameof(NoticeState));
        RaiseStateChanged();

        var cts = new CancellationTokenSource();
        _toastDismissCts = cts;
        TimeSpan delay = duration ?? TimeSpan.FromSeconds(3.5);
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(delay, cts.Token).ConfigureAwait(false);
                _dispatchToUi(() =>
                {
                    if (!cts.IsCancellationRequested && NoticeState.DismissToast(notice.Id))
                    {
                        RaiseStateChanged();
                    }
                });
            }
            catch (OperationCanceledException)
            {
            }
        });
    }

    public void DismissBanner(Guid id)
    {
        if (NoticeState.DismissBanner(id))
        {
            if (_renderFailureNoticeId == id) _renderFailureNoticeId = null;
            if (_datasetFailureNoticeId == id) _datasetFailureNoticeId = null;
            if (_scanIssueNoticeId == id) _scanIssueNoticeId = null;
            RaiseStateChanged();
        }
    }

    public void DismissToast(Guid id)
    {
        if (NoticeState.DismissToast(id))
        {
            RaiseStateChanged();
        }
    }

    public void DismissMetadataWarnings()
    {
        MetadataWarnings.Dismiss();
        RaiseStateChanged();
    }

    private void ClearDatasetNotices()
    {
        if (_renderFailureNoticeId is { } rId) NoticeState.DismissBanner(rId);
        if (_datasetFailureNoticeId is { } dId) NoticeState.DismissBanner(dId);
        if (_scanIssueNoticeId is { } sId) NoticeState.DismissBanner(sId);
        _renderFailureNoticeId = null;
        _datasetFailureNoticeId = null;
        _scanIssueNoticeId = null;
    }

    private void ClearRenderFailureNotice()
    {
        if (_renderFailureNoticeId is { } id && NoticeState.DismissBanner(id))
        {
            _renderFailureNoticeId = null;
            RaiseStateChanged();
        }
    }

    private void PresentDatasetFailure(string message)
    {
        _datasetFailureNoticeId = PresentBanner(
            title: "Could not open folder",
            message: message,
            severity: NoticeSeverity.Error,
            actions: string.IsNullOrEmpty(_folderPath) ? Array.Empty<NoticeAction>() : [NoticeAction.RetryFolder]);
    }

    private void RaiseStateChanged() => StateChanged?.Invoke();
    private void RaiseRenderStateChanged() => RenderStateChanged?.Invoke();

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
