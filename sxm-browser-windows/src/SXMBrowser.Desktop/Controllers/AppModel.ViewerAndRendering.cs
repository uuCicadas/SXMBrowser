using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using SXMBrowser.AppCore;
using SXMBrowser.Core;

namespace SXMBrowser.Desktop.Controllers;

public sealed partial class AppModel
{
    private static readonly double[] ViewerZoomPresets = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0];

    public string SelectedChannel
    {
        get => _selectedChannel;
        set
        {
            if (SetField(ref _selectedChannel, value))
            {
                ChannelChanged();
            }
        }
    }

    public ScanDirection SelectedDirection
    {
        get => _selectedDirection;
        set
        {
            if (SetField(ref _selectedDirection, value))
            {
                ControlsChanged(resetScale: false);
            }
        }
    }

    public ProcessingMode SelectedProcessing
    {
        get => _selectedProcessing;
        set
        {
            if (SetField(ref _selectedProcessing, value))
            {
                ControlsChanged(resetScale: true);
            }
        }
    }

    public PaletteName SelectedPalette
    {
        get => _selectedPalette;
        set
        {
            if (SetField(ref _selectedPalette, value))
            {
                ControlsChanged(resetScale: false);
            }
        }
    }

    public PaletteName StmPreviewPalette
    {
        get => _stmPreviewPalette;
        set
        {
            if (!SetField(ref _stmPreviewPalette, value)) return;
            SavePreferences(_prefs with { StmPreviewPalette = value });

            if (!string.IsNullOrEmpty(_selectedChannel) && UsesStmPalette(_selectedChannel))
            {
                _selectedPalette = value;
                OnPropertyChanged(nameof(SelectedPalette));
                if (_mode == BrowserMode.Single)
                {
                    RefreshSelectedImage(resetScale: false);
                }
            }

            ThumbnailsInvalidated?.Invoke();
            RaiseStateChanged();
            RaiseRenderStateChanged();
        }
    }

    public bool InvertPalette
    {
        get => _invertPalette;
        set
        {
            if (SetField(ref _invertPalette, value))
            {
                ControlsChanged(resetScale: false);
            }
        }
    }

    public ScalePreset ScalePreset
    {
        get => _scalePreset;
        private set => SetField(ref _scalePreset, value);
    }

    public int HistogramBins
    {
        get => _histogramBins;
        set
        {
            int clamped = value is 64 or 128 or 256 or 512 ? value : 256;
            if (!SetField(ref _histogramBins, clamped)) return;
            SavePreferences(_prefs with { HistogramBins = clamped });
            HistogramBinsChanged();
            RaiseRenderStateChanged();
        }
    }

    public bool ScaleLocked => _scaleLocked;
    public double? ScaleMin => _scaleMin;
    public double? ScaleMax => _scaleMax;
    public CoordinatorRenderedFrame<WriteableBitmap>? RenderedFrame => _renderedFrame;
    public SelectedRenderState<Guid> SelectedRenderState => _selectedRenderState;
    public MatrixStatistics? SelectedStats => _renderedFrame?.Stats?.Statistics;
    public HistogramStats? SelectedHistogramStats => _renderedFrame?.Stats;
    public ViewerTransform ViewerTransform => _viewerTransform;

    public SelectedRenderConfiguration CurrentRenderConfiguration => new(
        Channel: _selectedChannel,
        Direction: _selectedDirection,
        Processing: _selectedProcessing,
        Palette: _selectedPalette,
        Invert: _invertPalette,
        HistogramBins: _histogramBins,
        Scale: _scaleLocked
            ? new RenderScaleRequest.Locked(_scaleMin, _scaleMax)
            : RenderScaleRequest.Automatic.Instance);

    public string FormattedZoomLabel
    {
        get
        {
            double pct = _viewerTransform.ZoomPercentage;
            string formatted = pct.ToString("0.#", CultureInfo.InvariantCulture);
            return _viewerTransform.Mode == ViewerScaleMode.Fit
                ? $"Fit \u00B7 {formatted}%"
                : $"{formatted}%";
        }
    }

    public PaletteName PreviewPaletteForChannel(string channelName) =>
        UsesStmPalette(channelName) ? _stmPreviewPalette : PaletteName.Gray;

    private static bool UsesStmPalette(string channelName) =>
        SXMChannelRules.ClassifyChannel(channelName).UsesSTMPalette();

    public FrequencyShiftBoundsKey? GetFrequencyShiftBoundsKey(
        SXMMetadata file,
        string channel,
        ScanDirection direction)
    {
        if (!SXMChannelRules.IsFrequencyShiftChannel(channel))
        {
            return null;
        }
        SXMChannel? channelInfo = file.Channels.FirstOrDefault(
            c => string.Equals(c.Name, channel, StringComparison.Ordinal));
        if (channelInfo is null || channelInfo.Directions.Count == 0)
        {
            return null;
        }
        ScanDirection resolvedDirection = channelInfo.Directions.Contains(direction)
            ? direction
            : channelInfo.Directions[0];
        return new FrequencyShiftBoundsKey(
            _renderCoordinator.DatasetRevision,
            file.Id,
            file.Path,
            file.ModifiedTime,
            channelInfo.Name,
            resolvedDirection);
    }

    public FrequencyShiftBounds? GetCachedFrequencyShiftBounds(FrequencyShiftBoundsKey key)
    {
        lock (_frequencyShiftBoundsLock)
        {
            return _frequencyShiftBoundsCache.TryGetValue(key, out FrequencyShiftBounds? cached)
                ? cached
                : null;
        }
    }

    public async Task<FrequencyShiftBounds?> LoadFrequencyShiftBoundsAsync(
        SXMMetadata file,
        FrequencyShiftBoundsKey key,
        CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested
            || key.DatasetRevision != _renderCoordinator.DatasetRevision
            || key.FileId != file.Id
            || !SXMChannelRules.IsFrequencyShiftChannel(key.Channel))
        {
            return null;
        }

        lock (_frequencyShiftBoundsLock)
        {
            if (_frequencyShiftBoundsCache.TryGetValue(key, out FrequencyShiftBounds? cached))
            {
                return cached;
            }
        }

        try
        {
            Matrix matrix = await _renderCoordinator.GetMatrixAsync(
                file,
                new MatrixKey(key.Channel, key.Direction),
                cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();

            FrequencyShiftBounds? bounds = await CancellableDetachedWork.RunAsync(
                ct => FrequencyShiftBounds.From(matrix, CancellationCheckpoint.FromToken(ct)),
                cancellationToken).ConfigureAwait(false);

            if (cancellationToken.IsCancellationRequested
                || key.DatasetRevision != _renderCoordinator.DatasetRevision)
            {
                return null;
            }

            lock (_frequencyShiftBoundsLock)
            {
                _frequencyShiftBoundsCache[key] = bounds;
            }
            return bounds;
        }
        catch
        {
            return null;
        }
    }

    public void ClearFrequencyShiftBoundsCache()
    {
        lock (_frequencyShiftBoundsLock)
        {
            _frequencyShiftBoundsCache.Clear();
        }
    }

    public void RemoveFrequencyShiftBoundsEntriesForStandardizedPath(string path)
    {
        string standardized = Path.GetFullPath(path);
        StringComparison cmp = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        lock (_frequencyShiftBoundsLock)
        {
            var keysToRemove = _frequencyShiftBoundsCache.Keys
                .Where(k => string.Equals(k.StandardizedPath, standardized, cmp))
                .ToArray();
            foreach (FrequencyShiftBoundsKey key in keysToRemove)
            {
                _frequencyShiftBoundsCache.Remove(key);
            }
        }
    }

    public void RemoveCachedData(string path)
    {
        string standardized = Path.GetFullPath(path);
        StringComparison cmp = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        _renderCoordinator.RemoveMatrixEntriesForStandardizedPath(standardized);
        RemoveFrequencyShiftBoundsEntriesForStandardizedPath(standardized);
        if (SelectedFile is { } selected
            && string.Equals(Path.GetFullPath(selected.Path), standardized, cmp))
        {
            _renderCoordinator.DiscardProcessedData();
        }
    }

    public Task<WriteableBitmap?> ThumbnailForAsync(
        SXMMetadata file,
        CancellationToken ct = default)
    {
        (string channel, ScanDirection dir, ProcessingMode proc, PaletteName palette) =
            ThumbnailParamsForFile(file);
        return _thumbnails.ThumbnailAsync(file, channel, dir, proc, palette, invert: false, outputSize: 260, ct);
    }

    public bool TryGetCachedThumbnail(SXMMetadata file, out WriteableBitmap? bitmap)
    {
        (string channel, ScanDirection dir, ProcessingMode proc, PaletteName palette) =
            ThumbnailParamsForFile(file);
        return _thumbnails.TryGetCached(file, channel, dir, proc, palette, invert: false, outputSize: 260, out bitmap);
    }

    private (string Channel, ScanDirection Direction, ProcessingMode Processing, PaletteName Palette)
        ThumbnailParamsForFile(SXMMetadata file)
    {
        string defaultChannel = file.DefaultChannel ?? file.Channels.FirstOrDefault()?.Name ?? string.Empty;
        SXMChannel? info = file.Channels.FirstOrDefault(c => string.Equals(c.Name, defaultChannel, StringComparison.Ordinal))
            ?? file.Channels.FirstOrDefault();
        ScanDirection direction = info?.Directions.FirstOrDefault() ?? ScanDirection.Fwd;
        ProcessingMode processing = SXMChannelRules.DefaultProcessing(defaultChannel);
        PaletteName palette = PreviewPaletteForChannel(defaultChannel);
        return (defaultChannel, direction, processing, palette);
    }

    private void SyncSelectionDefaults(bool resetScale)
    {
        SXMMetadata? file = SelectedFile;
        if (file is null)
        {
            _selectedChannel = string.Empty;
            _selectedDirection = ScanDirection.Fwd;
            _selectedProcessing = ProcessingMode.PlaneLinear;
            _selectedPalette = _stmPreviewPalette;
            if (resetScale)
            {
                _scalePreset = ScalePreset.Full;
                _scaleLocked = false;
                _scaleMin = null;
                _scaleMax = null;
            }
            return;
        }

        string? keptChannel = file.Channels.FirstOrDefault(
            c => string.Equals(c.Name, _selectedChannel, StringComparison.Ordinal))?.Name;
        string channel = keptChannel ?? file.DefaultChannel ?? file.Channels.FirstOrDefault()?.Name ?? string.Empty;
        SXMChannel? channelInfo = file.Channels.FirstOrDefault(
            c => string.Equals(c.Name, channel, StringComparison.Ordinal));

        _selectedChannel = channel;
        if (channelInfo is not null && !channelInfo.Directions.Contains(_selectedDirection))
        {
            _selectedDirection = channelInfo.Directions.FirstOrDefault();
        }
        else if (channelInfo is null)
        {
            _selectedDirection = ScanDirection.Fwd;
        }

        _selectedProcessing = SXMChannelRules.DefaultProcessing(channel);
        _selectedPalette = PreviewPaletteForChannel(channel);
        _invertPalette = false;

        if (resetScale)
        {
            _scalePreset = ScalePreset.Full;
            _scaleLocked = false;
            _scaleMin = null;
            _scaleMax = null;
        }

        OnPropertyChanged(nameof(SelectedChannel));
        OnPropertyChanged(nameof(SelectedDirection));
        OnPropertyChanged(nameof(SelectedProcessing));
        OnPropertyChanged(nameof(SelectedPalette));
        OnPropertyChanged(nameof(InvertPalette));
        OnPropertyChanged(nameof(ScalePreset));
    }

    public void ChannelChanged()
    {
        SXMMetadata? file = SelectedFile;
        SXMChannel? channel = file?.Channels.FirstOrDefault(
            c => string.Equals(c.Name, _selectedChannel, StringComparison.Ordinal));
        if (channel is null) return;

        if (!channel.Directions.Contains(_selectedDirection))
        {
            _selectedDirection = channel.Directions.FirstOrDefault();
            OnPropertyChanged(nameof(SelectedDirection));
        }

        _selectedPalette = PreviewPaletteForChannel(_selectedChannel);
        _selectedProcessing = SXMChannelRules.DefaultProcessing(_selectedChannel);
        OnPropertyChanged(nameof(SelectedPalette));
        OnPropertyChanged(nameof(SelectedProcessing));

        if (_mode == BrowserMode.Single)
        {
            RefreshSelectedImage(resetScale: true);
        }
        else
        {
            InvalidateActiveRender(clearFrame: true);
        }
    }

    public void ControlsChanged(bool resetScale = false)
    {
        if (_mode == BrowserMode.Single)
        {
            RefreshSelectedImage(resetScale: resetScale);
        }
        else
        {
            InvalidateActiveRender(clearFrame: true);
        }
    }

    public void RefreshSelectedImage(bool resetScale = false)
    {
        if (resetScale)
        {
            _scalePreset = ScalePreset.Full;
            _scaleLocked = false;
            _scaleMin = null;
            _scaleMax = null;
            OnPropertyChanged(nameof(ScalePreset));
        }

        CancelCoalescedScaleRender();

        if (_mode != BrowserMode.Single || SelectedFile is not { } file || string.IsNullOrEmpty(_selectedChannel))
        {
            _selectedRenderState = SelectedRenderState<Guid>.Idle.Instance;
            InvalidateActiveRender(clearFrame: true);
            RaiseRenderStateChanged();
            return;
        }

        _renderCoordinator.Render(file, CurrentRenderConfiguration);
    }

    public void ApplyScalePreset(ScalePreset preset)
    {
        switch (preset)
        {
            case ScalePreset.Full:
                SetFullScale();
                break;
            case ScalePreset.Percentile:
                SetPercentileScale();
                break;
            case ScalePreset.Sigma:
                SetSigmaScale();
                break;
            case ScalePreset.Manual:
                ScalePreset = ScalePreset.Manual;
                break;
        }
    }

    public void SetFullScale()
    {
        if (SelectedStats is not { } stats) return;
        _scalePreset = ScalePreset.Full;
        _scaleLocked = true;
        _scaleMin = stats.Min;
        _scaleMax = stats.Max;
        OnPropertyChanged(nameof(ScalePreset));
        RefreshSelectedImage(resetScale: false);
    }

    public void SetPercentileScale()
    {
        if (SelectedStats is not { } stats) return;
        _scalePreset = ScalePreset.Percentile;
        _scaleLocked = true;
        _scaleMin = stats.P1;
        _scaleMax = stats.P99;
        OnPropertyChanged(nameof(ScalePreset));
        RefreshSelectedImage(resetScale: false);
    }

    public void SetSigmaScale(double sigma = 2.5)
    {
        if (SelectedStats is not { } stats) return;
        _scalePreset = ScalePreset.Sigma;
        _scaleLocked = true;
        _scaleMin = stats.Mean - sigma * stats.Std;
        _scaleMax = stats.Mean + sigma * stats.Std;
        OnPropertyChanged(nameof(ScalePreset));
        RefreshSelectedImage(resetScale: false);
    }

    /// <summary>
    /// Stepless real-time contrast scaling used by histogram handle dragging and SI bounds edits.
    /// Coalesces in-flight renders instead of cancelling them so dragging produces smooth updates.
    /// </summary>
    public void UpdateScale(double min, double max)
    {
        if (!double.IsFinite(min) || !double.IsFinite(max) || max <= min) return;
        _scalePreset = ScalePreset.Manual;
        _scaleLocked = true;
        _scaleMin = min;
        _scaleMax = max;
        OnPropertyChanged(nameof(ScalePreset));
        RaiseRenderStateChanged();
        ScheduleCoalescedScaleRender();
    }

    private void ScheduleCoalescedScaleRender()
    {
        if (_inFlightCoalescedRequest is not null)
        {
            _hasPendingScaleRender = true;
            return;
        }
        DispatchCoalescedScaleRender();
    }

    private void DispatchCoalescedScaleRender()
    {
        if (_mode != BrowserMode.Single || SelectedFile is not { } file || string.IsNullOrEmpty(_selectedChannel))
        {
            CancelCoalescedScaleRender();
            _selectedRenderState = SelectedRenderState<Guid>.Idle.Instance;
            InvalidateActiveRender(clearFrame: true);
            RaiseRenderStateChanged();
            return;
        }

        _hasPendingScaleRender = false;
        RenderRequestIdentity<Guid> request = _renderCoordinator.Render(file, CurrentRenderConfiguration);
        _inFlightCoalescedRequest = request;
    }

    public void HistogramBinsChanged()
    {
        if (_mode != BrowserMode.Single || SelectedFile is not { } file) return;
        _renderCoordinator.UpdateHistogram(file.Id, CurrentRenderConfiguration);
    }

    private void CancelCoalescedScaleRender()
    {
        _inFlightCoalescedRequest = null;
        _hasPendingScaleRender = false;
    }

    public void InvalidateActiveRender(bool clearFrame)
    {
        CancelCoalescedScaleRender();
        _renderCoordinator.Invalidate(clearFrame);
        if (clearFrame)
        {
            _renderedFrame = null;
            _selectedRenderState = SelectedRenderState<Guid>.Idle.Instance;
            RaiseRenderStateChanged();
        }
    }

    private bool AcceptsCoordinatorRequest(
        RenderRequestIdentity<Guid> request,
        SelectedRenderConfiguration configuration)
    {
        return _mode == BrowserMode.Single
            && _selection.PrimaryId == request.FileId
            && configuration.Equals(CurrentRenderConfiguration)
            && request.Configuration.Equals(configuration.ImageConfiguration);
    }

    private bool AcceptsCoordinatorFrame(CoordinatorRenderedFrame<WriteableBitmap> frame)
    {
        if (AcceptsCoordinatorRequest(frame.Request, frame.Configuration))
        {
            return true;
        }

        if (!Equals(_inFlightCoalescedRequest, frame.Request)
            || _mode != BrowserMode.Single
            || _selection.PrimaryId != frame.Request.FileId
            || !frame.Request.Configuration.Equals(frame.Configuration.ImageConfiguration))
        {
            return false;
        }

        SelectedRenderConfiguration current = CurrentRenderConfiguration;
        return frame.Configuration.ProcessedConfiguration.Equals(current.ProcessedConfiguration)
            && frame.Configuration.Palette == current.Palette
            && frame.Configuration.Invert == current.Invert
            && frame.Configuration.HistogramBins == current.HistogramBins;
    }

    private void HandleRenderCoordinatorEvent(RenderCoordinatorEvent<WriteableBitmap> evt)
    {
        switch (evt)
        {
            case RenderCoordinatorEvent<WriteableBitmap>.Started started:
                if (!AcceptsCoordinatorRequest(started.Request, started.Configuration)) return;
                ClearRenderFailureNotice();
                if (_renderedFrame is not null && _renderedFrame.Request.ProcessedKey.Equals(started.Request.ProcessedKey))
                {
                    _selectedRenderState = new SelectedRenderState<Guid>.Ready(started.Request.FileId);
                }
                else
                {
                    _renderedFrame = null;
                    _selectedRenderState = new SelectedRenderState<Guid>.Loading(started.Request.FileId);
                    string filename = _allFiles.FirstOrDefault(f => f.Id == started.Request.FileId)?.Filename ?? "image";
                    Status = $"Rendering {filename}...";
                }
                RaiseRenderStateChanged();
                break;

            case RenderCoordinatorEvent<WriteableBitmap>.ImageReady ready:
                if (!AcceptsCoordinatorFrame(ready.Frame)) return;
                ClearRenderFailureNotice();

                bool finishedCoalesced = Equals(_inFlightCoalescedRequest, ready.Frame.Request);
                if (finishedCoalesced)
                {
                    _inFlightCoalescedRequest = null;
                }

                // Keep existing histogram stats across same-processed-matrix scale drags if Stats is still computing.
                CoordinatorRenderedFrame<WriteableBitmap> mergedFrame = ready.Frame;
                if (mergedFrame.Stats is null
                    && _renderedFrame?.Stats is { } existingStats
                    && _renderedFrame.Request.ProcessedKey.Equals(mergedFrame.Request.ProcessedKey)
                    && _renderedFrame.Configuration.HistogramBins == mergedFrame.Configuration.HistogramBins)
                {
                    mergedFrame = mergedFrame with { Stats = existingStats };
                }

                _renderedFrame = mergedFrame;
                _selectedRenderState = new SelectedRenderState<Guid>.Ready(mergedFrame.Request.FileId);

                if (mergedFrame.Configuration.Scale is RenderScaleRequest.Automatic)
                {
                    _scaleMin = mergedFrame.AutomaticScaleMin;
                    _scaleMax = mergedFrame.AutomaticScaleMax;
                }

                ApplyViewerGeometry(
                    new ViewerSize(mergedFrame.Image.PixelSize.Width, mergedFrame.Image.PixelSize.Height),
                    _viewerTransform.ViewportSize);

                Status = _allFiles.FirstOrDefault(f => f.Id == mergedFrame.Request.FileId)?.Filename ?? "Image rendered.";
                RaiseRenderStateChanged();

                if (finishedCoalesced && _hasPendingScaleRender)
                {
                    DispatchCoalescedScaleRender();
                }
                break;

            case RenderCoordinatorEvent<WriteableBitmap>.HistogramReady histReady:
                if (!AcceptsCoordinatorFrame(histReady.Frame)) return;
                _renderedFrame = histReady.Frame;
                _selectedRenderState = new SelectedRenderState<Guid>.Ready(histReady.Frame.Request.FileId);
                RaiseRenderStateChanged();
                break;

            case RenderCoordinatorEvent<WriteableBitmap>.Failed failed:
                bool wasInFlightCoalesced = Equals(_inFlightCoalescedRequest, failed.Failure.Request);
                if (!((_mode == BrowserMode.Single
                       && _selection.PrimaryId == failed.Failure.Request.FileId
                       && failed.Failure.Request.Configuration.Equals(CurrentRenderConfiguration.ImageConfiguration))
                      || wasInFlightCoalesced))
                {
                    return;
                }

                if (wasInFlightCoalesced && _hasPendingScaleRender)
                {
                    _inFlightCoalescedRequest = null;
                    DispatchCoalescedScaleRender();
                    return;
                }

                CancelCoalescedScaleRender();
                _renderedFrame = null;
                _selectedRenderState = new SelectedRenderState<Guid>.Failed(
                    failed.Failure.Request.FileId,
                    failed.Failure.Message);
                Status = failed.Failure.Message;
                _renderFailureNoticeId = PresentBanner(
                    title: "Image could not be rendered",
                    message: failed.Failure.Message,
                    severity: NoticeSeverity.Error,
                    actions: [NoticeAction.RetryRender, NoticeAction.ShowInFinder]);
                RaiseRenderStateChanged();
                break;

            case RenderCoordinatorEvent<WriteableBitmap>.Cleared:
                _renderedFrame = null;
                _selectedRenderState = SelectedRenderState<Guid>.Idle.Instance;
                RaiseRenderStateChanged();
                break;
        }
    }

    // --- Viewer Zoom & Pan ---

    public void ReconcileViewerGeometry(ViewerSize imageSize, ViewerSize viewportSize)
    {
        ApplyViewerGeometry(imageSize, viewportSize);
    }

    private void ApplyViewerGeometry(ViewerSize imageSize, ViewerSize viewportSize)
    {
        ViewerTransform next = _viewerTransform;
        next.Reconcile(imageSize, viewportSize);
        if (!next.Equals(_viewerTransform))
        {
            _viewerTransform = next;
            OnPropertyChanged(nameof(ViewerTransform));
            OnPropertyChanged(nameof(FormattedZoomLabel));
            RaiseRenderStateChanged();
        }
    }

    public void FitViewer()
    {
        ViewerTransform next = _viewerTransform;
        next.Fit();
        _viewerTransform = next;
        OnPropertyChanged(nameof(ViewerTransform));
        OnPropertyChanged(nameof(FormattedZoomLabel));
        RaiseRenderStateChanged();
    }

    public void ShowActualSize(ViewerPoint? anchor = null)
    {
        ViewerTransform next = _viewerTransform;
        next.ShowActualSize(anchor);
        _viewerTransform = next;
        OnPropertyChanged(nameof(ViewerTransform));
        OnPropertyChanged(nameof(FormattedZoomLabel));
        RaiseRenderStateChanged();
    }

    public void ZoomViewer(double factor, ViewerPoint? anchor = null)
    {
        ViewerTransform next = _viewerTransform;
        next.Zoom(factor, anchor ?? next.ViewportSize.Center);
        _viewerTransform = next;
        OnPropertyChanged(nameof(ViewerTransform));
        OnPropertyChanged(nameof(FormattedZoomLabel));
        RaiseRenderStateChanged();
    }

    public void StepViewerZoom(bool zoomIn)
    {
        double current = _viewerTransform.Scale;
        const double tolerance = 1e-6;
        double? target = zoomIn
            ? ViewerZoomPresets.FirstOrDefault(p => p > current + tolerance)
            : ViewerZoomPresets.LastOrDefault(p => p < current - tolerance);
        if (target is not { } nextScale || nextScale <= 0.0) return;

        ViewerTransform next = _viewerTransform;
        next.SetCustomScale(nextScale, next.ViewportSize.Center);
        _viewerTransform = next;
        OnPropertyChanged(nameof(ViewerTransform));
        OnPropertyChanged(nameof(FormattedZoomLabel));
        RaiseRenderStateChanged();
    }

    public void ToggleFitOrActualSize(ViewerPoint? anchor = null)
    {
        if (_viewerTransform.Mode == ViewerScaleMode.Fit)
        {
            ShowActualSize(anchor);
        }
        else
        {
            FitViewer();
        }
    }

    public void PanViewer(ViewerPoint delta)
    {
        ViewerTransform next = _viewerTransform;
        next.Pan(delta);
        _viewerTransform = next;
        OnPropertyChanged(nameof(ViewerTransform));
        RaiseRenderStateChanged();
    }

    // --- PNG Export ---

    public async Task ExportPngAsync(string destinationPath, CancellationToken ct = default)
    {
        if (SelectedFile is not { } file || string.IsNullOrEmpty(_selectedChannel))
        {
            throw new InvalidOperationException("No rendered channel is selected for PNG export.");
        }

        SelectedRenderConfiguration config = CurrentRenderConfiguration;
        Matrix matrix = await _renderCoordinator.GetMatrixAsync(
            file,
            new MatrixKey(config.Channel, config.Direction),
            ct).ConfigureAwait(false);

        (double? vmin, double? vmax) = config.Scale switch
        {
            RenderScaleRequest.Locked(var min, var max) => (min, max),
            _ => (null, null)
        };

        byte[] pngBytes = await Task.Run(() => SXMRenderer.PngData(
            matrix,
            new RenderOptions(
                Channel: config.Channel,
                Direction: config.Direction,
                Processing: config.Processing,
                Palette: config.Palette,
                Vmin: vmin,
                Vmax: vmax,
                OutputSize: null,
                Invert: config.Invert,
                TransparentMissingValues: false),
            CancellationCheckpoint.FromToken(ct)), ct).ConfigureAwait(false);

        await File.WriteAllBytesAsync(destinationPath, pngBytes, ct).ConfigureAwait(false);
        _dispatchToUi(() => PresentToast("Exported PNG", Path.GetFileName(destinationPath)));
    }
}
