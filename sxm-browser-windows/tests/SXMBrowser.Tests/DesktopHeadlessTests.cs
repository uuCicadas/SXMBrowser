using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Headless.XUnit;
using Avalonia.Threading;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Controllers;
using SXMBrowser.Desktop.Services;
using SXMBrowser.Desktop.Views;
using Xunit;

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
}
