using System;
using System.Threading;
using System.Threading.Tasks;

namespace SXMBrowser.AppCore;

public static class CancellableDetachedWork
{
    public static async Task<T> RunAsync<T>(
        Func<CancellationToken, T> operation,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var workerCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task<T> worker = Task.Run(() => operation(workerCts.Token), workerCts.Token);
        return await worker.WaitAsync(cancellationToken).ConfigureAwait(false);
    }
}
