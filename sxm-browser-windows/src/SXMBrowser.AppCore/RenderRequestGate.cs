using System;
using System.Collections.Generic;
using SXMBrowser.Core;

namespace SXMBrowser.AppCore;

public abstract record RenderScaleRequest
{
    public sealed record Automatic : RenderScaleRequest
    {
        public static readonly Automatic Instance = new();
    }

    public sealed record Locked(double? Min, double? Max) : RenderScaleRequest;
}

public sealed record ProcessedRenderConfiguration(
    string Channel,
    ScanDirection Direction,
    ProcessingMode Processing);

public sealed record ImageRenderConfiguration(
    ProcessedRenderConfiguration Processed,
    PaletteName Palette,
    bool Invert,
    RenderScaleRequest Scale);

public sealed record HistogramRenderConfiguration(
    ProcessedRenderConfiguration Processed,
    int Bins);

public sealed record SelectedRenderConfiguration(
    string Channel,
    ScanDirection Direction,
    ProcessingMode Processing,
    PaletteName Palette,
    bool Invert,
    int HistogramBins,
    RenderScaleRequest Scale)
{
    public ProcessedRenderConfiguration ProcessedConfiguration =>
        new(Channel, Direction, Processing);

    public ImageRenderConfiguration ImageConfiguration =>
        new(ProcessedConfiguration, Palette, Invert, Scale);

    public HistogramRenderConfiguration HistogramConfiguration =>
        new(ProcessedConfiguration, HistogramBins);
}

public sealed record ProcessedRenderKey<TId>(
    Guid DatasetRevision,
    TId FileId,
    ProcessedRenderConfiguration Configuration);

public sealed record RenderRequestIdentity<TId>(
    Guid RequestId,
    Guid DatasetRevision,
    TId FileId,
    ImageRenderConfiguration Configuration)
{
    public ProcessedRenderKey<TId> ProcessedKey =>
        new(DatasetRevision, FileId, Configuration.Processed);
}

public sealed record HistogramRequestIdentity<TId>(
    Guid RequestId,
    Guid DatasetRevision,
    TId FileId,
    HistogramRenderConfiguration Configuration)
{
    public ProcessedRenderKey<TId> ProcessedKey =>
        new(DatasetRevision, FileId, Configuration.Processed);
}

public sealed class RenderRequestGate<TId> where TId : notnull
{
    public Guid DatasetRevision { get; private set; }
    public RenderRequestIdentity<TId>? ActiveRequest { get; private set; }

    public RenderRequestGate(Guid? datasetRevision = null)
    {
        DatasetRevision = datasetRevision ?? Guid.NewGuid();
    }

    public RenderRequestIdentity<TId> Begin(
        TId fileId,
        SelectedRenderConfiguration configuration,
        Guid? requestId = null)
    {
        var req = new RenderRequestIdentity<TId>(
            requestId ?? Guid.NewGuid(),
            DatasetRevision,
            fileId,
            configuration.ImageConfiguration);
        ActiveRequest = req;
        return req;
    }

    public void Invalidate()
    {
        ActiveRequest = null;
    }

    public void BeginNewDataset(Guid? revision = null)
    {
        DatasetRevision = revision ?? Guid.NewGuid();
        ActiveRequest = null;
    }

    public bool Accepts(
        RenderRequestIdentity<TId> request,
        TId? currentFileId,
        SelectedRenderConfiguration currentConfiguration)
    {
        return ActiveRequest is not null
            && ActiveRequest.Equals(request)
            && request.DatasetRevision == DatasetRevision
            && currentFileId is not null
            && EqualityComparer<TId>.Default.Equals(request.FileId, currentFileId)
            && request.Configuration.Equals(currentConfiguration.ImageConfiguration);
    }
}

public sealed class HistogramRequestGate<TId> where TId : notnull
{
    public Guid DatasetRevision { get; private set; }
    public HistogramRequestIdentity<TId>? ActiveRequest { get; private set; }

    public HistogramRequestGate(Guid? datasetRevision = null)
    {
        DatasetRevision = datasetRevision ?? Guid.NewGuid();
    }

    public HistogramRequestIdentity<TId> Begin(
        TId fileId,
        SelectedRenderConfiguration configuration,
        Guid? requestId = null)
    {
        var req = new HistogramRequestIdentity<TId>(
            requestId ?? Guid.NewGuid(),
            DatasetRevision,
            fileId,
            configuration.HistogramConfiguration);
        ActiveRequest = req;
        return req;
    }

    public void Invalidate()
    {
        ActiveRequest = null;
    }

    public void BeginNewDataset(Guid? revision = null)
    {
        DatasetRevision = revision ?? Guid.NewGuid();
        ActiveRequest = null;
    }

    public bool Accepts(
        HistogramRequestIdentity<TId> request,
        TId? currentFileId,
        SelectedRenderConfiguration currentConfiguration)
    {
        return ActiveRequest is not null
            && ActiveRequest.Equals(request)
            && request.DatasetRevision == DatasetRevision
            && currentFileId is not null
            && EqualityComparer<TId>.Default.Equals(request.FileId, currentFileId)
            && request.Configuration.Equals(currentConfiguration.HistogramConfiguration);
    }
}
