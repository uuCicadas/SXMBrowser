using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.Threading;
using Avalonia.VisualTree;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Controllers;
using SXMBrowser.Desktop.Services;
using SXMBrowser.Desktop.Theme;
using SXMBrowser.Desktop.Views;
using Xunit;
using SxmMatrix = SXMBrowser.Core.Matrix;

namespace SXMBrowser.Tests;

public sealed class DesktopHeadlessTests
{
    private sealed class NoopFileService : IPlatformFileService
    {
        public List<string> DeletedPaths { get; } = [];
        public string? RevealedPath { get; private set; }

        public void MoveFilesToRecycleBin(IReadOnlyList<string> fullPaths) => DeletedPaths.AddRange(fullPaths);
        public void RevealInFileExplorer(string fullPath) => RevealedPath = fullPath;
    }

    private static (AppModel Model, string TempDir) CreateIsolatedModel()
    {
        string temp = Path.Combine(Path.GetTempPath(), $"sxm-headless-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temp);
        var metaStore = new DatasetMetadataStore(Path.Combine(temp, "metadata-v1.json"));
        var prefStore = new BrowserPreferencesStore(Path.Combine(temp, "preferences-v1.json"));
        var model = new AppModel(metaStore, prefStore, new NoopFileService());
        return (model, temp);
    }

    private static void PumpUi(Func<bool> condition, int timeoutMs = 5000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!condition() && DateTime.UtcNow < deadline)
        {
            Dispatcher.UIThread.RunJobs();
            Thread.Sleep(15);
        }
        Dispatcher.UIThread.RunJobs();
    }

    [AvaloniaFact]
    public async Task AppModelDefaultsToGwyddionAndOpensCanonicalExampleGraph()
    {
        (AppModel model, string tempDir) = CreateIsolatedModel();
        try
        {
            Assert.Equal(PaletteName.Gwyddion, model.StmPreviewPalette);
            Assert.Equal(PaletteName.Gwyddion, model.SelectedPalette);

            string sampleDir = TestRepoPaths.ExampleGraphDir();
            await model.OpenFolderAsync(sampleDir);

            Assert.IsType<DatasetLoadState.Ready>(model.DatasetState);
            Assert.Equal(6, model.AllFiles.Count);
            Assert.Equal(18, model.SpectroscopyFiles.Count);
            Assert.Empty(model.ScanIssues);
            Assert.NotNull(model.SelectedFile);

            // Verify MainWindow mounts cleanly and responds to theme switching
            var win = new MainWindow(model);
            win.Show();
            win.Width = 1280;
            win.Height = 800;

            model.ThemeMode = ThemeAppearanceMode.Light;
            Dispatcher.UIThread.RunJobs();
            Assert.Equal(Avalonia.Styling.ThemeVariant.Light, win.RequestedThemeVariant);

            model.ThemeMode = ThemeAppearanceMode.Dark;
            Dispatcher.UIThread.RunJobs();
            Assert.Equal(Avalonia.Styling.ThemeVariant.Dark, win.RequestedThemeVariant);

            // Switch to an STM file if present, enter Single view, and wait for WriteableBitmap render
            SXMMetadata? zScan = model.AllFiles.FirstOrDefault(
                f => f.DefaultChannel is not null && SXMChannelRules.ClassifyChannel(f.DefaultChannel).UsesSTMPalette())
                ?? model.AllFiles[0];
            model.OpenSingleView(zScan.Id);

            PumpUi(() => model.RenderedFrame is not null && model.RenderedFrame.Stats is not null);
            Assert.NotNull(model.RenderedFrame);
            Assert.IsType<SelectedRenderState<Guid>.Ready>(model.SelectedRenderState);
            Assert.True(model.RenderedFrame!.Image.PixelSize.Width > 0);
            Assert.NotNull(model.RenderedFrame.Stats);

            // Exercise stepless real-time contrast coalescing without dropping final scale
            MatrixStatistics stats = model.RenderedFrame.Stats!.Statistics;
            if (stats.Max > stats.Min)
            {
                double lo = stats.Min + (stats.Max - stats.Min) * 0.15;
                double hi = stats.Min + (stats.Max - stats.Min) * 0.85;
                model.UpdateScale(lo, hi);
                double lo2 = stats.Min + (stats.Max - stats.Min) * 0.25;
                double hi2 = stats.Min + (stats.Max - stats.Min) * 0.75;
                model.UpdateScale(lo2, hi2);

                Assert.Equal(ScalePreset.Manual, model.ScalePreset);
                Assert.Equal(lo2, model.ScaleMin);
                Assert.Equal(hi2, model.ScaleMax);

                PumpUi(() =>
                    model.RenderedFrame?.Request.Configuration.Scale is RenderScaleRequest.Locked(var rm, var rx)
                    && rm == lo2 && rx == hi2);
                Assert.Equal(
                    new RenderScaleRequest.Locked(lo2, hi2),
                    model.RenderedFrame.Request.Configuration.Scale);
            }

            // Exercise Tag CRUD + Portable Metadata Export & Re-import roundtrip
            await model.CreateTagAsync("Good Terraces", [model.AllFiles[0].Id]);
            Assert.Single(model.Tags);
            string transferFile = Path.Combine(tempDir, "export.sxm-metadata.json");
            await model.ExportMetadataAsync(transferFile);
            Assert.True(File.Exists(transferFile));

            Guid tagId = model.Tags[0].Id;
            await model.DeleteTagAsync(tagId);
            Assert.Empty(model.Tags);

            MetadataImportWorkflow wf = model.PrepareMetadataImport(transferFile);
            Assert.NotNull(wf.Plan);
            Assert.True(wf.Plan!.CanApply);
            Assert.Equal(1, wf.Plan.Summary.TagActionCount);
            await model.ApplyMetadataImportAsync(wf);
            Assert.Single(model.Tags);
            Assert.Equal("Good Terraces", model.Tags[0].Name);

            win.Close();
        }
        finally
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true);
        }
    }

    private sealed class RecordingMatrixReader : ISxmMatrixReader
    {
        private readonly IReadOnlyDictionary<MatrixKey, SxmMatrix> _matrices;
        private readonly object _lock = new();
        private readonly List<MatrixKey> _requests = [];

        public RecordingMatrixReader(IReadOnlyDictionary<MatrixKey, SxmMatrix> matrices)
        {
            _matrices = matrices;
        }

        public int TotalCount
        {
            get { lock (_lock) return _requests.Count; }
        }

        public int CountFor(MatrixKey key)
        {
            lock (_lock) return _requests.Count(k => k == key);
        }

        public Task<SxmMatrix> LoadMatrixAsync(SXMMetadata metadata, MatrixKey key, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (_lock) _requests.Add(key);
            if (_matrices.TryGetValue(key, out SxmMatrix? matrix))
            {
                return Task.FromResult(matrix);
            }
            throw new SXMParserException(
                SXMParserErrorKind.MatrixNotFound,
                metadata.Path,
                $"Matrix not found: {key.Channel} ({key.Direction})");
        }
    }

    private static SXMMetadata MakeFrequencyShiftSxm(string filename = "afm_test.sxm", bool includeBackward = true)
    {
        ScanDirection[] directions = includeBackward ? [ScanDirection.Fwd, ScanDirection.Bwd] : [ScanDirection.Fwd];
        return new SXMMetadata(
            id: null,
            path: Path.Combine(Path.GetTempPath(), "sxm-test", filename),
            filename: filename,
            header: new Dictionary<string, string>(),
            recordedTime: null,
            modifiedTime: DateTimeOffset.FromUnixTimeSeconds(1_700_000_000),
            pixels: (2, 2),
            scanRange: (4e-9, 4e-9),
            scanOffset: (0.0, 0.0),
            scanAngle: 0.0,
            scanDir: "down",
            zControllerOn: false,
            channels:
            [
                new SXMChannel("Z", "m", [ScanDirection.Fwd, ScanDirection.Bwd], ChannelKind.Topography),
                new SXMChannel("OC_D1_Amplitude", "m", [ScanDirection.Fwd], ChannelKind.Afm),
                new SXMChannel("OC_M1_Freq._Shift", "Hz", directions, ChannelKind.Afm)
            ],
            defaultChannel: "OC_M1_Freq._Shift");
    }

    [Fact]
    public void FormattedFrequencyShiftUsesOneDecimalAndAvoidsNegativeZero()
    {
        Assert.Equal("-12.3 Hz", ScientificFormatters.FormatFrequencyShift(-12.34));
        Assert.Equal("4.0 Hz", ScientificFormatters.FormatFrequencyShift(4.024));
        Assert.Equal("0.3 Hz", ScientificFormatters.FormatFrequencyShift(0.3));
        Assert.Equal("0.0 Hz", ScientificFormatters.FormatFrequencyShift(-0.04));
        Assert.Equal("0.0 Hz", ScientificFormatters.FormatFrequencyShift(0.0));
        Assert.Equal("5.3 Hz", ScientificFormatters.FormatFrequencyShift(5.26, unit: ""));
        Assert.Equal("5.3 Hz", ScientificFormatters.FormatFrequencyShift(5.26, unit: "   "));
        Assert.Equal("5.3 kHz", ScientificFormatters.FormatFrequencyShift(5.26, unit: "kHz"));
        Assert.Equal("\u2014", ScientificFormatters.FormatFrequencyShift(double.NaN));
        Assert.Equal("\u2014", ScientificFormatters.FormatFrequencyShift(double.PositiveInfinity));
    }

    [AvaloniaFact]
    public async Task FrequencyShiftBoundsLoadPerDirectionCacheHitsIgnoreScaleChangesAndInvalidate()
    {
        var fwdKey = new MatrixKey("OC_M1_Freq._Shift", ScanDirection.Fwd);
        var bwdKey = new MatrixKey("OC_M1_Freq._Shift", ScanDirection.Bwd);
        var zKey = new MatrixKey("Z", ScanDirection.Fwd);

        var fwdMatrix = new SxmMatrix(2, 2, [-10.25f, -2.0f, float.NaN, 1.34f]);
        var bwdMatrix = new SxmMatrix(2, 2, [-11.5f, 0.22f, -4.1f, float.PositiveInfinity]);
        var zMatrix = new SxmMatrix(2, 2, [1e-10f, 2e-10f, 3e-10f, 4e-10f]);

        var recorder = new RecordingMatrixReader(new Dictionary<MatrixKey, SxmMatrix>
        {
            [fwdKey] = fwdMatrix,
            [bwdKey] = bwdMatrix,
            [zKey] = zMatrix
        });

        string tempDir = Path.Combine(Path.GetTempPath(), $"sxm-df-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);
        try
        {
            var metaStore = new DatasetMetadataStore(Path.Combine(tempDir, "metadata-v1.json"));
            var prefStore = new BrowserPreferencesStore(Path.Combine(tempDir, "preferences-v1.json"));
            var model = new AppModel(metaStore, prefStore, new NoopFileService(), matrixReader: recorder)
            {
                InspectorVisible = false
            };

            SXMMetadata file = MakeFrequencyShiftSxm();
            model.SetFilesForTesting([file]);
            model.ShowGridView();
            model.SelectOnly(file.Id);

            Assert.Equal("OC_M1_Freq._Shift", model.SelectedChannel);
            Assert.Equal(ScanDirection.Fwd, model.SelectedDirection);

            // Non-frequency-shift channels do not produce bounds keys or trigger matrix loads.
            Assert.Null(model.GetFrequencyShiftBoundsKey(file, "Z", ScanDirection.Fwd));
            Assert.Null(model.GetFrequencyShiftBoundsKey(file, "OC_D1_Amplitude", ScanDirection.Fwd));
            var bogusNonFreqKey = new FrequencyShiftBoundsKey(
                model.DatasetRevision,
                file.Id,
                file.Path,
                file.ModifiedTime,
                "Z",
                ScanDirection.Fwd);
            Assert.Null(await model.LoadFrequencyShiftBoundsAsync(file, bogusNonFreqKey));
            Assert.Equal(0, recorder.TotalCount);

            // Grid mode loads raw forward bounds and caches the result.
            FrequencyShiftBoundsKey gridFwdKey = Assert.NotNull(
                model.GetFrequencyShiftBoundsKey(file, model.SelectedChannel, model.SelectedDirection));
            Assert.Null(model.GetCachedFrequencyShiftBounds(gridFwdKey));
            FrequencyShiftBounds gridFwdBounds = Assert.NotNull(
                await model.LoadFrequencyShiftBoundsAsync(file, gridFwdKey));
            Assert.InRange(Math.Abs(gridFwdBounds.Min - (-10.25f)), 0.0, 1e-6);
            Assert.InRange(Math.Abs(gridFwdBounds.Max - 1.34f), 0.0, 1e-6);
            Assert.Equal(gridFwdBounds, model.GetCachedFrequencyShiftBounds(gridFwdKey));
            Assert.Equal(1, recorder.CountFor(fwdKey));

            // Repeating the load uses the cache without reading the matrix again.
            FrequencyShiftBounds? repeatedFwdBounds = await model.LoadFrequencyShiftBoundsAsync(file, gridFwdKey);
            Assert.Equal(gridFwdBounds, repeatedFwdBounds);
            Assert.Equal(1, recorder.CountFor(fwdKey));

            // Backward direction loads independently.
            model.SelectedDirection = ScanDirection.Bwd;
            FrequencyShiftBoundsKey bwdBoundsKey = Assert.NotNull(
                model.GetFrequencyShiftBoundsKey(file, model.SelectedChannel, model.SelectedDirection));
            FrequencyShiftBounds bwdBounds = Assert.NotNull(
                await model.LoadFrequencyShiftBoundsAsync(file, bwdBoundsKey));
            Assert.InRange(Math.Abs(bwdBounds.Min - (-11.5f)), 0.0, 1e-6);
            Assert.InRange(Math.Abs(bwdBounds.Max - 0.22f), 0.0, 1e-6);
            Assert.Equal(1, recorder.CountFor(bwdKey));

            // Switching to Single mode and changing contrast scale must not alter raw matrix bounds.
            model.SelectedDirection = ScanDirection.Fwd;
            model.OpenSingleView(file.Id);
            PumpUi(() => model.SelectedStats is not null);
            model.UpdateScale(-5.0, 0.0);
            model.SetPercentileScale();
            FrequencyShiftBounds? singleFwdBounds = await model.LoadFrequencyShiftBoundsAsync(file, gridFwdKey);
            Assert.Equal(gridFwdBounds, singleFwdBounds);

            // Verify InspectorView renders Δf Min / Δf Max cards with formatted values.
            model.InspectorVisible = true;
            var win = new MainWindow(model) { Width = 1280, Height = 800 };
            win.Show();
            PumpUi(() => win.GetVisualDescendants().OfType<TextBlock>().Any(tb => tb.Text == "\u0394f Min"));
            var texts = win.GetVisualDescendants().OfType<TextBlock>().Select(tb => tb.Text).ToArray();
            Assert.Contains("\u0394f Min", texts);
            Assert.Contains("\u0394f Max", texts);
            Assert.Contains("-10.3 Hz", texts);
            Assert.Contains("1.3 Hz", texts);
            win.Close();

            // RemoveCachedData invalidates both matrix cache and bounds cache for that path.
            model.RemoveCachedData(file.Path);
            Assert.Null(model.GetCachedFrequencyShiftBounds(gridFwdKey));
            FrequencyShiftBounds? reloadedFwdBounds = await model.LoadFrequencyShiftBoundsAsync(file, gridFwdKey);
            Assert.Equal(gridFwdBounds, reloadedFwdBounds);
            Assert.Equal(2, recorder.CountFor(fwdKey));

            // New dataset revision isolates keys and clears bounds cache.
            model.ResetDatasetRevision(Guid.NewGuid());
            FrequencyShiftBoundsKey postResetKey = Assert.NotNull(
                model.GetFrequencyShiftBoundsKey(file, model.SelectedChannel, model.SelectedDirection));
            Assert.NotEqual(gridFwdKey, postResetKey);
            Assert.Null(model.GetCachedFrequencyShiftBounds(postResetKey));
        }
        finally
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true);
        }
    }

    [AvaloniaFact]
    public async Task FrequencyShiftBoundsCachesUnavailableForAllNonFiniteMatrices()
    {
        var fwdKey = new MatrixKey("OC_M1_Freq._Shift", ScanDirection.Fwd);
        var nanMatrix = new SxmMatrix(2, 2, [float.NaN, float.PositiveInfinity, float.NegativeInfinity, float.NaN]);
        var recorder = new RecordingMatrixReader(new Dictionary<MatrixKey, SxmMatrix>
        {
            [fwdKey] = nanMatrix
        });

        string tempDir = Path.Combine(Path.GetTempPath(), $"sxm-df-nan-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);
        try
        {
            var metaStore = new DatasetMetadataStore(Path.Combine(tempDir, "metadata-v1.json"));
            var prefStore = new BrowserPreferencesStore(Path.Combine(tempDir, "preferences-v1.json"));
            var model = new AppModel(metaStore, prefStore, new NoopFileService(), matrixReader: recorder);

            SXMMetadata file = MakeFrequencyShiftSxm(filename: "nan_afm.sxm", includeBackward: false);
            model.SetFilesForTesting([file]);
            model.SelectOnly(file.Id);

            FrequencyShiftBoundsKey boundsKey = Assert.NotNull(
                model.GetFrequencyShiftBoundsKey(file, model.SelectedChannel, model.SelectedDirection));
            Assert.Null(await model.LoadFrequencyShiftBoundsAsync(file, boundsKey));
            Assert.Null(model.GetCachedFrequencyShiftBounds(boundsKey));
            Assert.Equal(1, recorder.CountFor(fwdKey));

            // Second request hits the cached unavailable entry and avoids re-reading the matrix.
            Assert.Null(await model.LoadFrequencyShiftBoundsAsync(file, boundsKey));
            Assert.Equal(1, recorder.CountFor(fwdKey));
        }
        finally
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true);
        }
    }
}
