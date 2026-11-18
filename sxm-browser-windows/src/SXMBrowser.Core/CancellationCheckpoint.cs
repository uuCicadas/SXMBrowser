using System;
using System.Threading;

namespace SXMBrowser.Core;

/// <summary>
/// Cooperative cancellation checkpoint invoked inside tight parsing and rendering loops.
/// </summary>
public readonly struct CancellationCheckpoint
{
    private readonly Action? _check;

    public static CancellationCheckpoint None => default;

    public CancellationCheckpoint(Action? check)
    {
        _check = check;
    }

    public static CancellationCheckpoint FromToken(CancellationToken cancellationToken)
    {
        return cancellationToken.CanBeCanceled
            ? new CancellationCheckpoint(() => cancellationToken.ThrowIfCancellationRequested())
            : None;
    }

    public void Check()
    {
        _check?.Invoke();
    }
}
