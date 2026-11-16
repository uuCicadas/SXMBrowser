using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Services;

namespace SXMBrowser.Desktop.Controllers;

public sealed record ThumbnailCacheKey(
    Guid DatasetRevision,
    Guid FileId,
    DateTimeOffset ModifiedTime,
    string Channel,
    ScanDirection Direction,
    ProcessingMode Processing,
    PaletteName Palette,
    bool Invert,
    int OutputSize);

/// <summary>
/// Viewport-prioritized (LIFO) bounded thumbnail generator with LRU memory budget and
/// ref-counted in-flight deduplication.
/// </summary>
public sealed class ThumbnailPipeline
{
    private sealed class InFlightEntry
    {
        public CancellationTokenSource Cts { get; } = new();
        public List<TaskCompletionSource<WriteableBitmap?>> Waiters { get; } = [];
    }

    private const int DefaultByteBudget = 64 * 1024 * 1024;
    private const int DefaultMaxCount = 256;

    private readonly AsyncLimiter _limiter = new(4, AcquisitionOrder.Lifo);
    private readonly SXMParser _parser;
    private readonly ByteLRUCache<ThumbnailCacheKey, WriteableBitmap> _cache = new(DefaultByteBudget);
    private readonly Dictionary<ThumbnailCacheKey, InFlightEntry> _inFlight = [];
    private readonly object _gate = new();

    private Guid _datasetRevision = Guid.NewGuid();

    public ThumbnailPipeline(SXMParser? parser = null)
    {
        _parser = parser ?? new SXMParser();
    }

    public Guid DatasetRevision
    {
        get
        {
            lock (_gate)
            {
                return _datasetRevision;
            }
        }
    }

    public void Reset(Guid? nextRevision = null)
    {
        List<InFlightEntry> toCancel;
        lock (_gate)
        {
            _datasetRevision = nextRevision ?? Guid.NewGuid();
            _cache.RemoveAll();
            toCancel = [.. _inFlight.Values];
            _inFlight.Clear();
        }

        foreach (InFlightEntry entry in toCancel)
        {
            try { entry.Cts.Cancel(); } catch (ObjectDisposedException) { }
            foreach (TaskCompletionSource<WriteableBitmap?> waiter in entry.Waiters)
            {
                waiter.TrySetResult(null);
            }
        }
    }

    public void ClearCache(bool cancelInFlight = false)
    {
        List<InFlightEntry> toCancel = [];
        lock (_gate)
        {
            _cache.RemoveAll();
            if (cancelInFlight)
            {
                toCancel = [.. _inFlight.Values];
                _inFlight.Clear();
            }
        }

        foreach (InFlightEntry entry in toCancel)
        {
            try { entry.Cts.Cancel(); } catch (ObjectDisposedException) { }
            foreach (TaskCompletionSource<WriteableBitmap?> waiter in entry.Waiters)
            {
                waiter.TrySetResult(null);
            }
        }
    }

    public void RemoveEntriesForFile(Guid fileId)
    {
        var entriesToCancel = new List<InFlightEntry>();
        lock (_gate)
        {
            var keysToRemove = new List<ThumbnailCacheKey>();
            foreach (ThumbnailCacheKey key in _cache.KeysFromLeastToMostRecent)
            {
                if (key.FileId == fileId) keysToRemove.Add(key);
            }
            foreach (ThumbnailCacheKey key in keysToRemove)
            {
                _cache.TryRemoveValue(key, out _);
            }

            var inFlightKeys = new List<ThumbnailCacheKey>();
            foreach ((ThumbnailCacheKey key, InFlightEntry entry) in _inFlight)
            {
                if (key.FileId == fileId)
                {
                    inFlightKeys.Add(key);
                    entriesToCancel.Add(entry);
                }
            }
            foreach (ThumbnailCacheKey key in inFlightKeys)
            {
                _inFlight.Remove(key);
            }
        }

        foreach (InFlightEntry entry in entriesToCancel)
        {
            try { entry.Cts.Cancel(); } catch (ObjectDisposedException) { }
            foreach (TaskCompletionSource<WriteableBitmap?> waiter in entry.Waiters)
            {
                waiter.TrySetResult(null);
            }
        }
    }

    public bool TryGetCached(
        SXMMetadata file,
        string channel,
        ScanDirection direction,
        ProcessingMode processing,
        PaletteName palette,
        bool invert,
        int outputSize,
        out WriteableBitmap? bitmap)
    {
        lock (_gate)
        {
            var key = new ThumbnailCacheKey(
                _datasetRevision,
                file.Id,
                file.ModifiedTime,
                channel,
                direction,
                processing,
                palette,
                invert,
                outputSize);
            return _cache.TryGetValue(key, out bitmap);
        }
    }

    public async Task<WriteableBitmap?> ThumbnailAsync(
        SXMMetadata file,
        string channel,
        ScanDirection direction,
        ProcessingMode processing,
        PaletteName palette,
        bool invert = false,
        int outputSize = 260,
        CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested || string.IsNullOrEmpty(channel))
        {
            return null;
        }

        ThumbnailCacheKey key;
        InFlightEntry? entryToStart = null;
        var waiter = new TaskCompletionSource<WriteableBitmap?>(TaskCreationOptions.RunContinuationsAsynchronously);

        lock (_gate)
        {
            key = new ThumbnailCacheKey(
                _datasetRevision,
                file.Id,
                file.ModifiedTime,
                channel,
                direction,
                processing,
                palette,
                invert,
                outputSize);

            if (_cache.TryGetValue(key, out WriteableBitmap? cached))
            {
                return cached;
            }

            if (_inFlight.TryGetValue(key, out InFlightEntry? existing))
            {
                existing.Waiters.Add(waiter);
            }
            else
            {
                entryToStart = new InFlightEntry();
                entryToStart.Waiters.Add(waiter);
                _inFlight[key] = entryToStart;
            }
        }

        if (entryToStart is not null)
        {
            _ = RunWorkerAsync(key, file, entryToStart);
        }

        if (!cancellationToken.CanBeCanceled)
        {
            return await waiter.Task.ConfigureAwait(false);
        }

        using CancellationTokenRegistration reg = cancellationToken.Register(() =>
        {
            InFlightEntry? cancelEntry = null;
            lock (_gate)
            {
                if (_inFlight.TryGetValue(key, out InFlightEntry? active) && active.Waiters.Remove(waiter))
                {
                    if (active.Waiters.Count == 0)
                    {
                        _inFlight.Remove(key);
                        cancelEntry = active;
                    }
                }
            }

            waiter.TrySetResult(null);
            if (cancelEntry is not null)
            {
                try { cancelEntry.Cts.Cancel(); } catch (ObjectDisposedException) { }
            }
        });

        return await waiter.Task.ConfigureAwait(false);
    }

    private async Task RunWorkerAsync(
        ThumbnailCacheKey key,
        SXMMetadata file,
        InFlightEntry entry)
    {
        WriteableBitmap? result = null;
        CancellationToken ct = entry.Cts.Token;

        try
        {
            bool acquired = await _limiter.AcquireAsync(ct).ConfigureAwait(false);
            if (!acquired)
            {
                FinishEntry(key, entry, null);
                return;
            }

            try
            {
                if (!ct.IsCancellationRequested)
                {
                    RenderedImage rendered = await Task.Run(() =>
                    {
                        ct.ThrowIfCancellationRequested();
                        var mKey = new MatrixKey(key.Channel, key.Direction);
                        Matrix matrix = _parser.LoadMatrix(file, mKey, ct);
                        var opts = new RenderOptions(
                            Channel: key.Channel,
                            Direction: key.Direction,
                            Processing: key.Processing,
                            Palette: key.Palette,
                            Vmin: null,
                            Vmax: null,
                            OutputSize: key.OutputSize,
                            Invert: key.Invert,
                            TransparentMissingValues: true);
                        return SXMRenderer.RenderImage(matrix, opts, CancellationCheckpoint.FromToken(ct));
                    }, ct).ConfigureAwait(false);

                    if (!ct.IsCancellationRequested)
                    {
                        if (Dispatcher.UIThread.CheckAccess())
                        {
                            result = BitmapBridge.CreateWriteableBitmap(rendered);
                        }
                        else
                        {
                            result = await Dispatcher.UIThread.InvokeAsync(
                                () => BitmapBridge.CreateWriteableBitmap(rendered),
                                DispatcherPriority.Background,
                                ct);
                        }
                    }
                }
            }
            finally
            {
                _limiter.Release();
            }
        }
        catch (OperationCanceledException)
        {
            result = null;
        }
        catch
        {
            result = null;
        }

        FinishEntry(key, entry, result);
    }

    private void FinishEntry(ThumbnailCacheKey key, InFlightEntry entry, WriteableBitmap? result)
    {
        List<TaskCompletionSource<WriteableBitmap?>> waiters;
        lock (_gate)
        {
            bool stillActive = _inFlight.TryGetValue(key, out InFlightEntry? active) && ReferenceEquals(active, entry);
            if (stillActive)
            {
                _inFlight.Remove(key);
            }

            if (result is not null && key.DatasetRevision == _datasetRevision && !entry.Cts.IsCancellationRequested)
            {
                while (_cache.Count >= DefaultMaxCount && _cache.KeysFromLeastToMostRecent.Count > 0)
                {
                    _cache.TryRemoveValue(_cache.KeysFromLeastToMostRecent[0], out _);
                }
                int costBytes = Math.Max(4, result.PixelSize.Width * result.PixelSize.Height * 4);
                _cache.Insert(result, key, costBytes);
            }

            waiters = [.. entry.Waiters];
            entry.Waiters.Clear();
        }

        entry.Cts.Dispose();
        foreach (TaskCompletionSource<WriteableBitmap?> waiter in waiters)
        {
            waiter.TrySetResult(result);
        }
    }
}
