using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using Xunit;

namespace SXMBrowser.Tests;

public sealed class AppCoreTests
{
    private sealed class FailingVerifyFileAccess : IDatasetMetadataFileAccess
    {
        private readonly Dictionary<string, byte[]> _files = new(StringComparer.Ordinal);
        public bool FailNextVerifyRead { get; set; }
        private bool _corruptNextRead;

        public bool FileExists(string filePath) => _files.ContainsKey(filePath);
        public void CreateDirectory(string directoryPath) { }
        public byte[] ReadData(string filePath)
        {
            if (_corruptNextRead)
            {
                _corruptNextRead = false;
                return Encoding.UTF8.GetBytes("{corrupt");
            }
            return _files[filePath];
        }
        public void WriteDataAtomically(byte[] data, string filePath)
        {
            _files[filePath] = (byte[])data.Clone();
            if (FailNextVerifyRead)
            {
                FailNextVerifyRead = false;
                _corruptNextRead = true;
            }
        }
        public void RemoveItem(string filePath) => _files.Remove(filePath);
    }

    [Fact]
    public async Task AsyncLimiterLifoAndCancellationHandOffPermitsCleanly()
    {
        var limiter = new AsyncLimiter(1, AcquisitionOrder.Lifo);
        Assert.True(await limiter.AcquireAsync());

        Task<bool> first = limiter.AcquireAsync();
        var secondCts = new CancellationTokenSource();
        Task<bool> second = limiter.AcquireAsync(secondCts.Token);
        Task<bool> third = limiter.AcquireAsync();

        secondCts.Cancel();
        Assert.False(await second);

        limiter.Release();
        // LIFO wakes third before first
        Assert.True(await third);
        Assert.False(first.IsCompleted);

        limiter.Release();
        Assert.True(await first);
        limiter.Release();
    }

    [Fact]
    public async Task DatasetMetadataStoreRollsBackWhenVerificationFails()
    {
        var mem = new FailingVerifyFileAccess();
        var store = new DatasetMetadataStore("/virtual/metadata-v1.json", mem);

        // Initial clean transaction succeeds
        var first = await store.TransactionAsync(doc =>
        {
            var ds = new DatasetRecordV1(Guid.NewGuid(), null, "/dataset", updatedAt: DateTimeOffset.UnixEpoch);
            ds.CreateTag(null, "Baseline");
            doc.UpsertDataset(ds);
        });
        Assert.Single(first.Datasets);
        byte[] golden = mem.ReadData(store.FilePath);

        // Simulated read-back verification failure rolls back exact previous bytes
        mem.FailNextVerifyRead = true;
        var ex = await Assert.ThrowsAsync<DatasetMetadataStoreException>(() =>
            store.TransactionAsync(doc =>
            {
                doc.Datasets[0].CreateTag(null, "ShouldRollBack");
            }));
        Assert.Equal(DatasetMetadataStoreErrorKind.VerificationFailed, ex.Kind);

        Assert.Equal(golden, mem.ReadData(store.FilePath));
    }

    [Fact]
    public void DatasetMetadataTransferCodecMatchesMacWireFormatStrictly()
    {
        Guid tagId = Guid.Parse("A1B2C3D4-E5F6-4708-9123-456789ABCDEF");
        var ds = new DatasetRecordV1(
            id: Guid.NewGuid(),
            folderBookmark: null,
            lastKnownPath: "/data",
            tags: [new DatasetTagV1(tagId, "Favorite", ["b.sxm", "a.sxm"])],
            manualAssociations: [new DatasetManualAssociationV1("z1.dat", "a.sxm")],
            hiddenDATPaths: [DatasetRelativePath.Dat("hidden.dat")],
            spectrumAxisPreferences:
            [
                new SpectrumAxisPreferenceV1(
                    "a.sxm",
                    SpectroscopyKind.Bias,
                    "bias spectroscopy",
                    "0123456789abcdef",
                    new AxisSelection("Bias (V)", "Current (A)"))
            ],
            updatedAt: DateTimeOffset.UnixEpoch);

        var codec = new DatasetMetadataTransferCodec();
        byte[] jsonBytes = codec.Encode(new DatasetMetadataTransferV1(ds));
        string json = Encoding.UTF8.GetString(jsonBytes);

        // Verifies lowercase canonical UUIDs & flattened axis keys matching macOS v2.6.0
        Assert.Contains("\"id\":\"a1b2c3d4-e5f6-4708-9123-456789abcdef\"", json, StringComparison.Ordinal);
        Assert.Contains("\"formatIdentifier\":\"com.sxmbrowser.dataset-metadata\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\"key\":{", json, StringComparison.Ordinal);

        DatasetMetadataTransferV1 decoded = codec.Decode(jsonBytes);
        Assert.Single(decoded.Tags);
        Assert.Equal(["a.sxm", "b.sxm"], decoded.Tags[0].SxmPaths.Select(p => p.RawValue).ToArray());

        // Reject uppercase UUID
        byte[] uppercaseUuid = Encoding.UTF8.GetBytes(
            json.Replace("a1b2c3d4-e5f6-4708-9123-456789abcdef", "A1B2C3D4-E5F6-4708-9123-456789ABCDEF", StringComparison.Ordinal));
        var nonCanonicalEx = Assert.Throws<DatasetMetadataTransferException>(() => codec.Decode(uppercaseUuid));
        Assert.Equal(DatasetMetadataTransferErrorKind.NonCanonicalUuid, nonCanonicalEx.Kind);

        // Reject unknown root field
        byte[] unknownField = Encoding.UTF8.GetBytes("{\"extra\":1," + json[1..]);
        var unknownEx = Assert.Throws<DatasetMetadataTransferException>(() => codec.Decode(unknownField));
        Assert.Equal(DatasetMetadataTransferErrorKind.UnknownField, unknownEx.Kind);
    }

    [Fact]
    public void CoordinateTransformScaleBarAndViewerTransformOperateConsistently()
    {
        ScanCoordinateTransform? xform = ScanCoordinateTransform.TryCreate(
            rangeX: 100e-9,
            rangeY: 100e-9,
            offsetX: 10e-9,
            offsetY: -5e-9,
            angleDegrees: 0.0,
            scanDirection: "down");
        Assert.NotNull(xform);

        NormalizedScanCoordinate? center = xform!.NormalizedCoordinate(PhysicalScanCoordinate.TryCreate(10e-9, -5e-9)!.Value);
        Assert.NotNull(center);
        Assert.Equal(0.5, center!.Value.U, 8);
        Assert.Equal(0.5, center.Value.V, 8);

        NormalizedScanCoordinate? topRight = xform.NormalizedCoordinate(PhysicalScanCoordinate.TryCreate(60e-9, 45e-9)!.Value);
        Assert.NotNull(topRight);
        Assert.Equal(1.0, topRight!.Value.U, 8);
        Assert.Equal(0.0, topRight.Value.V, 8);

        var viewer = new ViewerTransform(new ViewerSize(512, 512), new ViewerSize(512, 512));
        ScaleBar? bar = ScaleBar.Resolve(100e-9, 512, viewer, 480.0);
        Assert.NotNull(bar);
        Assert.Contains("nm", bar!.Label, StringComparison.Ordinal);
        Assert.InRange(bar.ScreenLengthPoints, 48.0, 180.0);
    }

    [Fact]
    public void InspectorPresentationIdentifiesFrequencyShiftChannels()
    {
        var metadata = new SXMMetadata(
            id: null,
            path: "/tmp/afm.sxm",
            filename: "afm.sxm",
            header: new Dictionary<string, string>(),
            recordedTime: null,
            modifiedTime: DateTimeOffset.FromUnixTimeSeconds(200),
            pixels: (112, 112),
            scanRange: (4e-9, 4e-9),
            scanOffset: null,
            scanAngle: null,
            scanDir: "down",
            zControllerOn: false,
            channels:
            [
                new SXMChannel("Z", "m", [ScanDirection.Fwd], ChannelKind.Topography),
                new SXMChannel("Current", "A", [ScanDirection.Fwd], ChannelKind.ConductanceOrCurrent),
                new SXMChannel("OC_D1_Amplitude", "m", [ScanDirection.Fwd], ChannelKind.Afm),
                new SXMChannel("OC_M1_Freq._Shift", "Hz", [ScanDirection.Fwd, ScanDirection.Bwd], ChannelKind.Afm)
            ],
            defaultChannel: "OC_M1_Freq._Shift");

        var freqPresentation = new InspectorMetadataPresentation(metadata, "OC_M1_Freq._Shift");
        Assert.True(freqPresentation.IsFrequencyShiftChannel);
        Assert.Equal("Hz", freqPresentation.ChannelUnit);

        Assert.False(new InspectorMetadataPresentation(metadata, "Z").IsFrequencyShiftChannel);
        Assert.False(new InspectorMetadataPresentation(metadata, "Current").IsFrequencyShiftChannel);
        Assert.False(new InspectorMetadataPresentation(metadata, "OC_D1_Amplitude").IsFrequencyShiftChannel);
    }

    [Fact]
    public void FrequencyShiftBoundsIgnoresNonFiniteHandlesConstantsEmptyAndCancellation()
    {
        var mixed = new Matrix(3, 2, [-12.34f, float.NaN, 4.56f, float.PositiveInfinity, float.NegativeInfinity, 0.0f]);
        FrequencyShiftBounds? mixedBounds = FrequencyShiftBounds.From(mixed);
        Assert.NotNull(mixedBounds);
        Assert.InRange(Math.Abs(mixedBounds!.Value.Min - (-12.34f)), 0.0, 1e-6);
        Assert.InRange(Math.Abs(mixedBounds.Value.Max - 4.56f), 0.0, 1e-6);

        var constant = new Matrix(2, 2, [-8.5f, -8.5f, -8.5f, -8.5f]);
        FrequencyShiftBounds? constantBounds = FrequencyShiftBounds.From(constant);
        Assert.NotNull(constantBounds);
        Assert.Equal(-8.5, constantBounds!.Value.Min);
        Assert.Equal(-8.5, constantBounds.Value.Max);

        Assert.Null(FrequencyShiftBounds.From(new Matrix(0, 0, [])));
        Assert.Null(FrequencyShiftBounds.From(new Matrix(2, 1, [float.NaN, float.PositiveInfinity])));

        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() =>
            FrequencyShiftBounds.From(mixed, CancellationCheckpoint.FromToken(cts.Token)));
    }
}
