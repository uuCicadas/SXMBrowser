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

public enum BrowserMode
{
    Grid,
    Single
}

public abstract record BrowserScope
{
    public sealed record All : BrowserScope
    {
        public static readonly All Instance = new();
    }

    public sealed record Tag(Guid TagId) : BrowserScope;
}

public enum ScalePreset
{
    Full,
    Percentile,
    Sigma,
    Manual
}

public static class ScalePresetExtensions
{
    public static readonly IReadOnlyList<ScalePreset> AllPresets =
    [
        ScalePreset.Full,
        ScalePreset.Percentile,
        ScalePreset.Sigma,
        ScalePreset.Manual
    ];

    public static string Label(this ScalePreset preset) => preset switch
    {
        ScalePreset.Full => "Full",
        ScalePreset.Percentile => "1-99%",
        ScalePreset.Sigma => "2.5\u03C3",
        ScalePreset.Manual => "Manual",
        _ => "Full"
    };
}

public abstract record GridBrowserItem
{
    public sealed record Sxm(SXMMetadata File) : GridBrowserItem;
    public sealed record Spectroscopy(PresentedSpectroscopyGroup Presentation) : GridBrowserItem;

    public string ItemId => this switch
    {
        Sxm s => $"sxm-{s.File.Id:N}",
        Spectroscopy p => $"spectroscopy-{p.Presentation.Id}",
        _ => string.Empty
    };
}

public enum MetadataImportWorkflowPhase
{
    Loading,
    Preview,
    Applying,
    Failed,
    Completed
}

public sealed record MetadataImportWorkflow(
    Guid Id,
    string SourceFilePath,
    DatasetSessionIdentity SessionIdentity,
    DatasetMetadataImportInventory? Inventory,
    DatasetInventorySignature? FileSignature,
    DatasetMetadataTransferV1? Transfer,
    DatasetMetadataImportPolicy Policy,
    DatasetMetadataImportPlan? Plan,
    MetadataImportWorkflowPhase Phase,
    string? Message = null)
{
    public string SourceFilename => System.IO.Path.GetFileName(SourceFilePath);
}

public sealed class AvaloniaRenderBackend : IRenderBackend<WriteableBitmap>
{
    private readonly DefaultRenderBackend _inner = new();

    public Task<Matrix> ProcessAsync(Matrix matrix, ProcessingMode mode, CancellationToken ct) =>
        _inner.ProcessAsync(matrix, mode, ct);

    public Task<MatrixStatistics?> StatisticsAsync(Matrix matrix, CancellationToken ct) =>
        _inner.StatisticsAsync(matrix, ct);

    public Task<HistogramDistribution> HistogramAsync(
        Matrix matrix,
        MatrixStatistics statistics,
        int bins,
        CancellationToken ct) =>
        _inner.HistogramAsync(matrix, statistics, bins, ct);

    public async Task<WriteableBitmap> RenderImageAsync(
        Matrix matrix,
        RenderOptions options,
        CancellationToken ct)
    {
        RenderedImage rendered = await _inner.RenderImageAsync(matrix, options, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();

        if (Dispatcher.UIThread.CheckAccess())
        {
            return BitmapBridge.CreateWriteableBitmap(rendered);
        }

        return await Dispatcher.UIThread.InvokeAsync(
            () => BitmapBridge.CreateWriteableBitmap(rendered),
            DispatcherPriority.Normal,
            ct);
    }
}
