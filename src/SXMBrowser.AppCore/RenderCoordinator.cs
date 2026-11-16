using System;
using System.Threading;
using System.Threading.Tasks;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public interface ISxmMatrixReader
{
    Task<Matrix> LoadMatrixAsync(
        SXMMetadata metadata,
        MatrixKey key,
        CancellationToken cancellationToken);
}

public sealed class DefaultSxmMatrixReader : ISxmMatrixReader
{
    private readonly SXMParser _parser;

    public DefaultSxmMatrixReader(SXMParser? parser = null)
    {
        _parser = parser ?? new SXMParser();
    }

    public Task<Matrix> LoadMatrixAsync(
        SXMMetadata metadata,
        MatrixKey key,
        CancellationToken cancellationToken)
    {
        return CancellableDetachedWork.RunAsync(
            ct => _parser.LoadMatrix(metadata, key, ct),
            cancellationToken);
    }
}

public interface IRenderBackend<TImage>
{
    Task<Matrix> ProcessAsync(Matrix matrix, ProcessingMode mode, CancellationToken ct);
    Task<MatrixStatistics?> StatisticsAsync(Matrix matrix, CancellationToken ct);
    Task<HistogramDistribution> HistogramAsync(
        Matrix matrix,
        MatrixStatistics statistics,
        int bins,
        CancellationToken ct);
    Task<TImage> RenderImageAsync(Matrix matrix, RenderOptions options, CancellationToken ct);
}

public sealed class DefaultRenderBackend : IRenderBackend<RenderedImage>
{
    public Task<Matrix> ProcessAsync(Matrix matrix, ProcessingMode mode, CancellationToken ct)
        => CancellableDetachedWork.RunAsync(
            token => SXMRenderer.ProcessedMatrix(matrix, mode, CancellationCheckpoint.FromToken(token)),
            ct);

    public Task<MatrixStatistics?> StatisticsAsync(Matrix matrix, CancellationToken ct)
        => CancellableDetachedWork.RunAsync(
            token => SXMRenderer.Statistics(matrix, CancellationCheckpoint.FromToken(token)),
            ct);

    public Task<HistogramDistribution> HistogramAsync(
        Matrix matrix,
        MatrixStatistics statistics,
        int bins,
        CancellationToken ct)
        => CancellableDetachedWork.RunAsync(
            token => SXMRenderer.Histogram(matrix, statistics, bins, CancellationCheckpoint.FromToken(token)),
            ct);

    public Task<RenderedImage> RenderImageAsync(Matrix matrix, RenderOptions options, CancellationToken ct)
        => CancellableDetachedWork.RunAsync(
            token => SXMRenderer.RenderProcessedImage(matrix, options, CancellationCheckpoint.FromToken(token)),
            ct);
}

public sealed record CoordinatorRenderedFrame<TImage>(
    RenderRequestIdentity<Guid> Request,
    SelectedRenderConfiguration Configuration,
    TImage Image,
    HistogramStats? Stats,
    double? AutomaticScaleMin,
    double? AutomaticScaleMax);

public enum RenderFailureStage
{
    MatrixLoad,
    Processing,
    Statistics,
    Histogram,
    ImageRender
}

public sealed record RenderFailure(
    RenderRequestIdentity<Guid> Request,
    RenderFailureStage Stage,
    string Message);

public abstract record RenderCoordinatorEvent<TImage>
{
    public sealed record Started(
        RenderRequestIdentity<Guid> Request,
        SelectedRenderConfiguration Configuration) : RenderCoordinatorEvent<TImage>;

    public sealed record ImageReady(CoordinatorRenderedFrame<TImage> Frame) : RenderCoordinatorEvent<TImage>;

    public sealed record HistogramReady(CoordinatorRenderedFrame<TImage> Frame) : RenderCoordinatorEvent<TImage>;

    public sealed record Failed(RenderFailure Failure) : RenderCoordinatorEvent<TImage>;

    public sealed record Cleared : RenderCoordinatorEvent<TImage>
    {
        public static readonly Cleared Instance = new();
    }
}

/// <summary>
/// UI-thread-affinitized render orchestrator with single-slot processed matrix caching,
/// concurrent histogram calculation, and stale request rejection.
/// </summary>
public sealed class RenderCoordinator<TImage>
{
    private sealed record ActiveContext(Guid FileId, SelectedRenderConfiguration Configuration);
    private sealed record ProcessedPayload(Matrix Processed, MatrixStatistics? Statistics);
    private sealed record CachedHistogram(int Bins, HistogramStats? Stats);

    private sealed class ProcessedRenderCache
    {
        public ProcessedRenderKey<Guid> Key { get; }
        public ProcessedPayload Payload { get; }
        public CachedHistogram? Histogram { get; set; }

        public ProcessedRenderCache(ProcessedRenderKey<Guid> key, ProcessedPayload payload)
        {
            Key = key;
            Payload = payload;
        }
    }

    private sealed class ProcessedEntry
    {
        public bool IsLoading { get; }
        public ProcessedRenderKey<Guid> Key { get; }
        public Guid Token { get; }
        public CancellationTokenSource? Cts { get; }
        public ProcessedRenderCache? Cache { get; }

        private ProcessedEntry(
            bool isLoading,
            ProcessedRenderKey<Guid> key,
            Guid token,
            CancellationTokenSource? cts,
            ProcessedRenderCache? cache)
        {
            IsLoading = isLoading;
            Key = key;
            Token = token;
            Cts = cts;
            Cache = cache;
        }

        public static ProcessedEntry Loading(
            ProcessedRenderKey<Guid> key,
            Guid token,
            CancellationTokenSource cts) => new(true, key, token, cts, null);

        public static ProcessedEntry Ready(ProcessedRenderCache cache)
            => new(false, cache.Key, Guid.Empty, null, cache);
    }

    private sealed class PipelineFailureException : Exception
    {
        public RenderFailureStage Stage { get; }

        public PipelineFailureException(RenderFailureStage stage, string message)
            : base(message)
        {
            Stage = stage;
        }
    }

    private readonly ISxmMatrixReader _matrixReader;
    private readonly IRenderBackend<TImage> _backend;
    private readonly Func<MatrixLoadCache> _makeMatrixCache;
    private readonly Action<Action> _dispatchToUi;

    private MatrixLoadCache _matrixCache;
    private readonly RenderRequestGate<Guid> _renderRequestGate;
    private readonly HistogramRequestGate<Guid> _histogramRequestGate;

    private ActiveContext? _activeContext;
    private ProcessedEntry? _processedEntry;
    private CoordinatorRenderedFrame<TImage>? _frame;

    private CancellationTokenSource? _imageCts;
    private CancellationTokenSource? _histogramCts;

    public Action<RenderCoordinatorEvent<TImage>>? OnEvent { get; set; }
    public Guid DatasetRevision => _renderRequestGate.DatasetRevision;

    public RenderCoordinator(
        ISxmMatrixReader matrixReader,
        IRenderBackend<TImage> backend,
        Func<MatrixLoadCache>? makeMatrixCache = null,
        Action<Action>? dispatchToUi = null)
    {
        Guid revision = Guid.NewGuid();
        _matrixReader = matrixReader;
        _backend = backend;
        _makeMatrixCache = makeMatrixCache ?? (() => new MatrixLoadCache());
        _dispatchToUi = dispatchToUi ?? (action => action());
        _matrixCache = _makeMatrixCache();
        _renderRequestGate = new RenderRequestGate<Guid>(revision);
        _histogramRequestGate = new HistogramRequestGate<Guid>(revision);
    }

    public void BeginDataset(Guid? revision = null)
    {
        CancelImage();
        CancelHistogram();
        CancelAndDiscardProcessing();
        _activeContext = null;
        _frame = null;

        Guid nextRevision = revision ?? Guid.NewGuid();
        _renderRequestGate.BeginNewDataset(nextRevision);
        _histogramRequestGate.BeginNewDataset(nextRevision);

        MatrixLoadCache previousCache = _matrixCache;
        _matrixCache = _makeMatrixCache();
        _ = Task.Run(() => previousCache.Clear(cancelInFlight: true));

        OnEvent?.Invoke(RenderCoordinatorEvent<TImage>.Cleared.Instance);
    }

    public RenderRequestIdentity<Guid> Render(
        SXMMetadata file,
        SelectedRenderConfiguration configuration)
    {
        CancelImage();

        _activeContext = new ActiveContext(file.Id, configuration);
        RenderRequestIdentity<Guid> request = _renderRequestGate.Begin(file.Id, configuration);
        _frame = null;
        OnEvent?.Invoke(new RenderCoordinatorEvent<TImage>.Started(request, configuration));

        ProcessedRenderKey<Guid> processedKey = request.ProcessedKey;
        if (_processedEntry is not null && !_processedEntry.Key.Equals(processedKey))
        {
            CancelHistogram();
            CancelAndDiscardProcessing();
        }

        if (_processedEntry is { IsLoading: false, Cache: not null } readyEntry
            && readyEntry.Key.Equals(processedKey))
        {
            StartImageRender(processedKey);
        }
        else if (_processedEntry is { IsLoading: true } loadingEntry
                 && loadingEntry.Key.Equals(processedKey))
        {
            // Processing already in flight for this exact key; completion will pick up latest request.
        }
        else
        {
            StartProcessing(processedKey, file);
        }

        return request;
    }

    public void UpdateHistogram(Guid fileId, SelectedRenderConfiguration configuration)
    {
        if (_activeContext is null
            || _activeContext.FileId != fileId
            || _renderRequestGate.ActiveRequest is null
            || _renderRequestGate.ActiveRequest.FileId != fileId
            || !_renderRequestGate.ActiveRequest.Configuration.Equals(configuration.ImageConfiguration))
        {
            return;
        }

        _activeContext = _activeContext with { Configuration = configuration };
        RefreshHistogram(_renderRequestGate.ActiveRequest.ProcessedKey, fileId);
    }

    public void Invalidate(bool clearFrame)
    {
        CancelImage();
        CancelHistogram();
        CancelAndDiscardLoadingOnly();
        _renderRequestGate.Invalidate();
        _activeContext = null;

        if (clearFrame)
        {
            _frame = null;
            OnEvent?.Invoke(RenderCoordinatorEvent<TImage>.Cleared.Instance);
        }
    }

    public void DiscardProcessedData()
    {
        CancelImage();
        CancelHistogram();
        CancelAndDiscardProcessing();
    }

    public async Task<Matrix> GetMatrixAsync(
        SXMMetadata file,
        MatrixKey key,
        CancellationToken cancellationToken = default)
    {
        MatrixLoadCache cache = _matrixCache;
        Guid revision = _renderRequestGate.DatasetRevision;
        Matrix matrix = await LoadMatrixAsync(file, key, revision, cache, _matrixReader, cancellationToken)
            .ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (revision != _renderRequestGate.DatasetRevision || !ReferenceEquals(cache, _matrixCache))
        {
            throw new OperationCanceledException(cancellationToken);
        }
        return matrix;
    }

    public void RemoveMatrixEntriesForStandardizedPath(string path)
    {
        MatrixLoadCache cache = _matrixCache;
        _ = Task.Run(() => cache.RemoveEntriesForStandardizedPath(path));
    }

    private void StartProcessing(ProcessedRenderKey<Guid> key, SXMMetadata file)
    {
        CancelAndDiscardProcessing();
        Guid token = Guid.NewGuid();
        var cts = new CancellationTokenSource();
        _processedEntry = ProcessedEntry.Loading(key, token, cts);

        MatrixLoadCache cache = _matrixCache;
        var matrixKey = new MatrixKey(key.Configuration.Channel, key.Configuration.Direction);

        _ = Task.Run(async () =>
        {
            ProcessedPayload? payload = null;
            Exception? error = null;

            try
            {
                Matrix source;
                try
                {
                    source = await LoadMatrixAsync(
                        file, matrixKey, key.DatasetRevision, cache, _matrixReader, cts.Token)
                        .ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (SXMParserException ex) when (ex.Kind == SXMParserErrorKind.MatrixNotFound)
                {
                    throw new PipelineFailureException(
                        RenderFailureStage.MatrixLoad,
                        "Direction is not available for this channel.");
                }
                catch (Exception ex)
                {
                    throw new PipelineFailureException(RenderFailureStage.MatrixLoad, ex.Message);
                }

                cts.Token.ThrowIfCancellationRequested();

                Matrix processed;
                try
                {
                    processed = await _backend.ProcessAsync(source, key.Configuration.Processing, cts.Token)
                        .ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    throw new PipelineFailureException(RenderFailureStage.Processing, ex.Message);
                }

                cts.Token.ThrowIfCancellationRequested();

                MatrixStatistics? statistics;
                try
                {
                    statistics = await _backend.StatisticsAsync(processed, cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    throw new PipelineFailureException(RenderFailureStage.Statistics, ex.Message);
                }

                cts.Token.ThrowIfCancellationRequested();
                payload = new ProcessedPayload(processed, statistics);
            }
            catch (Exception ex)
            {
                error = ex;
            }

            _dispatchToUi(() =>
            {
                if (cts.IsCancellationRequested)
                {
                    cts.Dispose();
                    return;
                }
                cts.Dispose();
                FinishProcessing(payload, error, key, token);
            });
        });
    }

    private void FinishProcessing(
        ProcessedPayload? payload,
        Exception? error,
        ProcessedRenderKey<Guid> key,
        Guid token)
    {
        if (_processedEntry is not { IsLoading: true } entry
            || !entry.Key.Equals(key)
            || entry.Token != token)
        {
            return;
        }

        if (payload is not null)
        {
            _processedEntry = ProcessedEntry.Ready(new ProcessedRenderCache(key, payload));
            StartImageRender(key);
            return;
        }

        _processedEntry = null;
        if (error is OperationCanceledException)
        {
            return;
        }

        RenderRequestIdentity<Guid>? request = CurrentRenderRequest(key);
        if (request is null) return;

        if (error is PipelineFailureException failure)
        {
            PublishFailure(request, failure.Stage, failure.Message);
        }
        else
        {
            PublishFailure(request, RenderFailureStage.Processing, error?.Message ?? "Processing failed.");
        }
    }

    private static Task<Matrix> LoadMatrixAsync(
        SXMMetadata file,
        MatrixKey key,
        Guid datasetRevision,
        MatrixLoadCache cache,
        ISxmMatrixReader reader,
        CancellationToken ct)
    {
        var cacheKey = new MatrixCacheKey(datasetRevision, file.Id, file.Path, file.ModifiedTime, key);
        return cache.GetMatrixAsync(cacheKey, token => reader.LoadMatrixAsync(file, key, token), ct);
    }

    private void StartImageRender(ProcessedRenderKey<Guid> processedKey)
    {
        RenderRequestIdentity<Guid>? request = CurrentRenderRequest(processedKey);
        ProcessedRenderCache? cache = ReadyCache(processedKey);
        ActiveContext? context = _activeContext;
        if (request is null || cache is null || context is null) return;

        CancelImage();
        RefreshHistogram(processedKey, request.FileId);

        (double Vmin, double Vmax)? automaticScale = cache.Payload.Statistics is { } statsObj
            ? SXMRenderer.AutomaticScale(statsObj)
            : null;
        (double min, double max) = ResolvedBounds(request.Configuration.Scale, automaticScale);
        var options = new RenderOptions(
            Channel: request.Configuration.Processed.Channel,
            Direction: request.Configuration.Processed.Direction,
            Processing: request.Configuration.Processed.Processing,
            Palette: request.Configuration.Palette,
            Vmin: min,
            Vmax: max,
            OutputSize: null,
            Invert: request.Configuration.Invert,
            TransparentMissingValues: true);

        Matrix matrix = cache.Payload.Processed;
        SelectedRenderConfiguration expectedConfiguration = context.Configuration;
        var cts = new CancellationTokenSource();
        _imageCts = cts;

        _ = Task.Run(async () =>
        {
            TImage? image = default;
            Exception? error = null;
            try
            {
                image = await _backend.RenderImageAsync(matrix, options, cts.Token).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                error = ex;
            }

            _dispatchToUi(() =>
            {
                bool wasCancelled = cts.IsCancellationRequested;
                if (ReferenceEquals(_imageCts, cts))
                {
                    _imageCts = null;
                }
                cts.Dispose();

                if (wasCancelled || error is OperationCanceledException)
                {
                    return;
                }
                if (error is not null)
                {
                    PublishFailure(request, RenderFailureStage.ImageRender, error.Message);
                    return;
                }

                if (!AcceptsRenderRequest(request)
                    || _activeContext is null
                    || !_activeContext.Configuration.ImageConfiguration.Equals(expectedConfiguration.ImageConfiguration))
                {
                    return;
                }

                ProcessedRenderCache? currentCache = ReadyCache(processedKey);
                if (currentCache is null) return;

                HistogramStats? histStats =
                    currentCache.Histogram?.Bins == _activeContext.Configuration.HistogramBins
                        ? currentCache.Histogram.Stats
                        : null;

                var rendered = new CoordinatorRenderedFrame<TImage>(
                    request,
                    _activeContext.Configuration,
                    image!,
                    histStats,
                    automaticScale?.Vmin,
                    automaticScale?.Vmax);
                _frame = rendered;
                OnEvent?.Invoke(new RenderCoordinatorEvent<TImage>.ImageReady(rendered));
            });
        });
    }

    private void RefreshHistogram(ProcessedRenderKey<Guid> processedKey, Guid fileId)
    {
        ActiveContext? context = _activeContext;
        ProcessedRenderCache? cache = ReadyCache(processedKey);
        if (context is null || context.FileId != fileId || cache is null) return;

        HistogramRequestIdentity<Guid>? existingRequest = _histogramRequestGate.ActiveRequest;
        if (existingRequest is not null
            && existingRequest.ProcessedKey.Equals(processedKey)
            && _histogramRequestGate.Accepts(existingRequest, context.FileId, context.Configuration))
        {
            return;
        }

        CancelHistogram();

        if (cache.Histogram is not null && cache.Histogram.Bins == context.Configuration.HistogramBins)
        {
            PublishHistogram(cache.Histogram.Stats, processedKey);
            return;
        }

        MatrixStatistics? statistics = cache.Payload.Statistics;
        if (statistics is null)
        {
            cache.Histogram = new CachedHistogram(context.Configuration.HistogramBins, null);
            PublishHistogram(null, processedKey);
            return;
        }

        HistogramRequestIdentity<Guid> request = _histogramRequestGate.Begin(fileId, context.Configuration);
        Matrix matrix = cache.Payload.Processed;
        var cts = new CancellationTokenSource();
        _histogramCts = cts;

        _ = Task.Run(async () =>
        {
            HistogramDistribution? distribution = null;
            Exception? error = null;
            try
            {
                distribution = await _backend.HistogramAsync(
                    matrix,
                    statistics,
                    request.Configuration.Bins,
                    cts.Token).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                error = ex;
            }

            _dispatchToUi(() =>
            {
                bool wasCancelled = cts.IsCancellationRequested;
                if (ReferenceEquals(_histogramCts, cts))
                {
                    _histogramCts = null;
                }
                cts.Dispose();

                if (wasCancelled || error is not null || distribution is null)
                {
                    ClearFailedHistogramRequest(request);
                    return;
                }

                if (!AcceptsHistogramRequest(request))
                {
                    return;
                }
                ProcessedRenderCache? currentCache = ReadyCache(request.ProcessedKey);
                if (currentCache is null) return;

                var stats = new HistogramStats(statistics, distribution);
                currentCache.Histogram = new CachedHistogram(request.Configuration.Bins, stats);
                _histogramRequestGate.Invalidate();
                PublishHistogram(stats, request.ProcessedKey);
            });
        });
    }

    private void ClearFailedHistogramRequest(HistogramRequestIdentity<Guid> request)
    {
        if (!AcceptsHistogramRequest(request)) return;
        _histogramCts = null;
        _histogramRequestGate.Invalidate();
    }

    private ProcessedRenderCache? ReadyCache(ProcessedRenderKey<Guid> key)
    {
        return _processedEntry is { IsLoading: false, Cache: not null } entry
            && entry.Key.Equals(key)
            ? entry.Cache
            : null;
    }

    private void PublishHistogram(HistogramStats? stats, ProcessedRenderKey<Guid> processedKey)
    {
        if (_frame is null
            || !_frame.Request.ProcessedKey.Equals(processedKey)
            || !AcceptsRenderRequest(_frame.Request)
            || _activeContext is null)
        {
            return;
        }

        var updated = new CoordinatorRenderedFrame<TImage>(
            _frame.Request,
            _activeContext.Configuration,
            _frame.Image,
            stats,
            _frame.AutomaticScaleMin,
            _frame.AutomaticScaleMax);
        _frame = updated;
        OnEvent?.Invoke(new RenderCoordinatorEvent<TImage>.HistogramReady(updated));
    }

    private RenderRequestIdentity<Guid>? CurrentRenderRequest(ProcessedRenderKey<Guid> key)
    {
        RenderRequestIdentity<Guid>? req = _renderRequestGate.ActiveRequest;
        if (req is null || !req.ProcessedKey.Equals(key) || !AcceptsRenderRequest(req))
        {
            return null;
        }
        return req;
    }

    private bool AcceptsRenderRequest(RenderRequestIdentity<Guid> request) =>
        _activeContext is not null
        && _renderRequestGate.Accepts(request, _activeContext.FileId, _activeContext.Configuration);

    private bool AcceptsHistogramRequest(HistogramRequestIdentity<Guid> request) =>
        _activeContext is not null
        && _histogramRequestGate.Accepts(request, _activeContext.FileId, _activeContext.Configuration);

    private void PublishFailure(
        RenderRequestIdentity<Guid> request,
        RenderFailureStage stage,
        string message)
    {
        if (!AcceptsRenderRequest(request)) return;
        _renderRequestGate.Invalidate();
        CancelImage();
        CancelHistogram();
        _activeContext = null;
        _frame = null;
        OnEvent?.Invoke(new RenderCoordinatorEvent<TImage>.Failed(new RenderFailure(request, stage, message)));
    }

    private void CancelImage()
    {
        if (_imageCts is not null)
        {
            try { _imageCts.Cancel(); } catch (ObjectDisposedException) { }
            _imageCts = null;
        }
    }

    private void CancelHistogram()
    {
        if (_histogramCts is not null)
        {
            try { _histogramCts.Cancel(); } catch (ObjectDisposedException) { }
            _histogramCts = null;
        }
        _histogramRequestGate.Invalidate();
    }

    private void CancelAndDiscardLoadingOnly()
    {
        if (_processedEntry is { IsLoading: true } entry)
        {
            try { entry.Cts?.Cancel(); } catch (ObjectDisposedException) { }
            _processedEntry = null;
        }
    }

    private void CancelAndDiscardProcessing()
    {
        if (_processedEntry is { IsLoading: true } entry)
        {
            try { entry.Cts?.Cancel(); } catch (ObjectDisposedException) { }
        }
        _processedEntry = null;
    }

    private static (double Min, double Max) ResolvedBounds(
        RenderScaleRequest scale,
        (double Vmin, double Vmax)? automaticScale)
    {
        return scale switch
        {
            RenderScaleRequest.Automatic => (automaticScale?.Vmin ?? 0.0, automaticScale?.Vmax ?? 1.0),
            RenderScaleRequest.Locked(var min, var max) => (
                min ?? automaticScale?.Vmin ?? 0.0,
                max ?? automaticScale?.Vmax ?? 1.0),
            _ => (0.0, 1.0)
        };
    }
}
