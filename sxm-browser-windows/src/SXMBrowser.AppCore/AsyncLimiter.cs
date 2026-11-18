using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace SXMBrowser.AppCore;

public enum AcquisitionOrder
{
    Fifo,
    Lifo
}

/// <summary>
/// Bounded async concurrency gate supporting FIFO and LIFO (viewport-priority) scheduling
/// with race-free structured cancellation.
/// </summary>
public sealed class AsyncLimiter
{
    private readonly int _limit;
    private readonly AcquisitionOrder _order;
    private readonly object _lock = new();
    private int _available;
    private readonly List<Waiter> _waiters = [];

    private sealed class Waiter
    {
        public TaskCompletionSource<bool> Tcs { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Removed;
    }

    public AsyncLimiter(int limit, AcquisitionOrder order = AcquisitionOrder.Fifo)
    {
        _limit = Math.Max(1, limit);
        _order = order;
        _available = _limit;
    }

    public int WaiterCount
    {
        get
        {
            lock (_lock)
            {
                return _waiters.Count;
            }
        }
    }

    public Task<bool> AcquireAsync(CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return Task.FromResult(false);
        }

        Waiter waiter;
        lock (_lock)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return Task.FromResult(false);
            }
            if (_available > 0)
            {
                _available--;
                return Task.FromResult(true);
            }
            waiter = new Waiter();
            _waiters.Add(waiter);
        }

        if (!cancellationToken.CanBeCanceled)
        {
            return waiter.Tcs.Task;
        }

        return AwaitWithCancellationAsync(waiter, cancellationToken);
    }

    private async Task<bool> AwaitWithCancellationAsync(
        Waiter waiter,
        CancellationToken cancellationToken)
    {
        using CancellationTokenRegistration reg = cancellationToken.Register(() =>
        {
            lock (_lock)
            {
                if (!waiter.Removed)
                {
                    waiter.Removed = true;
                    _waiters.Remove(waiter);
                }
            }
            waiter.Tcs.TrySetResult(false);
        });

        return await waiter.Tcs.Task.ConfigureAwait(false);
    }

    public void Release()
    {
        Waiter? next = null;
        lock (_lock)
        {
            while (_waiters.Count > 0)
            {
                int index = _order == AcquisitionOrder.Lifo ? _waiters.Count - 1 : 0;
                Waiter candidate = _waiters[index];
                _waiters.RemoveAt(index);
                candidate.Removed = true;
                next = candidate;
                break;
            }

            if (next is null)
            {
                _available = Math.Min(_limit, _available + 1);
            }
        }

        if (next is not null)
        {
            // If waiter's cancellation raced right after lock release and resolved Tcs with false,
            // TrySetResult(true) returns false and we must return the permit!
            if (!next.Tcs.TrySetResult(true))
            {
                Release();
            }
        }
    }
}
