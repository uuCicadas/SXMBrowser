using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public readonly record struct MatrixCacheKey
{
    public Guid DatasetRevision { get; }
    public Guid FileId { get; }
    public string StandardizedPath { get; }
    public DateTimeOffset ModifiedTime { get; }
    public MatrixKey MatrixKey { get; }

    public MatrixCacheKey(
        Guid datasetRevision,
        Guid fileId,
        string path,
        DateTimeOffset modifiedTime,
        MatrixKey matrixKey)
    {
        DatasetRevision = datasetRevision;
        FileId = fileId;
        StandardizedPath = Path.GetFullPath(path);
        ModifiedTime = modifiedTime;
        MatrixKey = matrixKey;
    }
}

/// <summary>
/// Thread-safe byte-bounded LRU cache for raw SXM matrices with single-flight deduplication
/// and reference-counted waiter cancellation.
/// </summary>
public sealed class MatrixLoadCache
{
    private sealed class InFlight
    {
        public readonly Guid Token;
        public readonly ulong Generation;
        public readonly CancellationTokenSource WorkerCts;
        public readonly Task<Matrix> Task;
        public int WaiterCount;

        public InFlight(
            Guid token,
            ulong generation,
            CancellationTokenSource workerCts,
            Task<Matrix> task)
        {
            Token = token;
            Generation = generation;
            WorkerCts = workerCts;
            Task = task;
            WaiterCount = 1;
        }
    }

    private readonly object _lock = new();
    private readonly ByteLRUCache<MatrixCacheKey, Matrix> _cache;
    private readonly Dictionary<MatrixCacheKey, InFlight> _inFlight = [];
    private ulong _generation;

    public MatrixLoadCache(int? byteLimit = null)
    {
        _cache = new ByteLRUCache<MatrixCacheKey, Matrix>(
            byteLimit ?? MatrixCacheBudget.DefaultByteLimit);
    }

    public int CachedCount
    {
        get { lock (_lock) return _cache.Count; }
    }

    public int CachedByteCount
    {
        get { lock (_lock) return _cache.TotalCost; }
    }

    public int InFlightCount
    {
        get { lock (_lock) return _inFlight.Count; }
    }

    public IReadOnlyList<MatrixCacheKey> CachedKeysFromLeastToMostRecent
    {
        get { lock (_lock) return _cache.KeysFromLeastToMostRecent; }
    }

    public int ActiveWaiterCount(MatrixCacheKey key)
    {
        lock (_lock)
        {
            return _inFlight.TryGetValue(key, out InFlight? entry) ? entry.WaiterCount : 0;
        }
    }

    public async Task<Matrix> GetMatrixAsync(
        MatrixCacheKey key,
        Func<CancellationToken, Task<Matrix>> loader,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        InFlight entry;
        lock (_lock)
        {
            if (_cache.TryGetValue(key, out Matrix? cached))
            {
                return cached;
            }

            if (_inFlight.TryGetValue(key, out InFlight? existing))
            {
                existing.WaiterCount++;
                entry = existing;
            }
            else
            {
                Guid token = Guid.NewGuid();
                ulong entryGeneration = _generation;
                var workerCts = new CancellationTokenSource();
                Task<Matrix> workerTask = Task.Run(() => loader(workerCts.Token), workerCts.Token);
                entry = new InFlight(token, entryGeneration, workerCts, workerTask);
                _inFlight[key] = entry;

                _ = workerTask.ContinueWith(
                    completed => Complete(completed, key, token, entryGeneration),
                    CancellationToken.None,
                    TaskContinuationOptions.ExecuteSynchronously,
                    TaskScheduler.Default);
            }
        }

        try
        {
            Matrix result = await entry.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            Complete(entry.Task, key, entry.Token, entry.Generation);
            cancellationToken.ThrowIfCancellationRequested();
            return result;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            CancelWaiter(key, entry.Token, entry.Generation);
            throw;
        }
    }

    public void RemoveEntriesForStandardizedPath(string path)
    {
        string full = Path.GetFullPath(path);
        List<CancellationTokenSource> toCancel = [];
        lock (_lock)
        {
            foreach (MatrixCacheKey key in _cache.KeysFromLeastToMostRecent)
            {
                if (string.Equals(key.StandardizedPath, full, StringComparison.Ordinal))
                {
                    _cache.TryRemoveValue(key, out _);
                }
            }

            var matchingInFlight = _inFlight.Where(kv =>
                string.Equals(kv.Key.StandardizedPath, full, StringComparison.Ordinal)).ToList();
            foreach ((MatrixCacheKey key, InFlight entry) in matchingInFlight)
            {
                _inFlight.Remove(key);
                toCancel.Add(entry.WorkerCts);
            }
        }

        foreach (CancellationTokenSource cts in toCancel)
        {
            CancelAndDisposeQuietly(cts);
        }
    }

    public void Clear(bool cancelInFlight = true)
    {
        List<InFlight> active;
        lock (_lock)
        {
            unchecked { _generation++; }
            _cache.RemoveAll();
            active = [.. _inFlight.Values];
            _inFlight.Clear();
        }

        if (cancelInFlight)
        {
            foreach (InFlight entry in active)
            {
                CancelAndDisposeQuietly(entry.WorkerCts);
            }
        }
    }

    private void Complete(
        Task<Matrix> workerTask,
        MatrixCacheKey key,
        Guid token,
        ulong entryGeneration)
    {
        CancellationTokenSource? ctsToDispose = null;
        lock (_lock)
        {
            if (entryGeneration != _generation
                || !_inFlight.TryGetValue(key, out InFlight? current)
                || current.Token != token)
            {
                return;
            }
            _inFlight.Remove(key);
            ctsToDispose = current.WorkerCts;
            if (workerTask.Status == TaskStatus.RanToCompletion)
            {
                Matrix matrix = workerTask.Result;
                long rawCost = (long)matrix.Values.Length * sizeof(float);
                int cost = rawCost > int.MaxValue ? int.MaxValue : (int)rawCost;
                _cache.Insert(matrix, key, cost);
            }
        }
        ctsToDispose?.Dispose();
    }

    private void CancelWaiter(MatrixCacheKey key, Guid token, ulong entryGeneration)
    {
        CancellationTokenSource? ctsToCancel = null;
        lock (_lock)
        {
            if (entryGeneration != _generation
                || !_inFlight.TryGetValue(key, out InFlight? entry)
                || entry.Token != token)
            {
                return;
            }
            entry.WaiterCount--;
            if (entry.WaiterCount <= 0)
            {
                _inFlight.Remove(key);
                ctsToCancel = entry.WorkerCts;
            }
        }
        if (ctsToCancel is not null)
        {
            CancelAndDisposeQuietly(ctsToCancel);
        }
    }

    private static void CancelAndDisposeQuietly(CancellationTokenSource cts)
    {
        try
        {
            cts.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }
    }
}
