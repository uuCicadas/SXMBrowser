using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Controllers;
using SXMBrowser.Desktop.Controls;
using SXMBrowser.Desktop.Services;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Views;

public sealed class InspectorView : Border
{
    private readonly AppModel _model;
    private readonly StackPanel _rootStack;
    private readonly StackPanel _contentStack;
    private readonly TextBlock _emptySelectionText;

    // Display & contrast controls
    private readonly ComboBox _channelBox;
    private readonly StackPanel _directionPanel;
    private readonly ComboBox _processingBox;
    private readonly ComboBox _paletteBox;
    private readonly CheckBox _invertCheck;
    private readonly StackPanel _scalePresetsPanel;
    private readonly PaletteStripControl _paletteStrip;
    private readonly HistogramControl _histogramControl;
    private readonly ComboBox _binsBox;
    private readonly TextBox _scaleMinBox;
    private readonly TextBox _scaleMaxBox;
    private readonly TextBlock _statsSummaryText;
    private readonly Button _exportPngBtn;

    // Tags controls
    private readonly WrapPanel _tagsWrap;
    private readonly Button _newTagFromFileBtn;

    // Acquisition cards & metadata
    private readonly Grid _acqGrid;
    private readonly TextBlock _timestampsText;
    private readonly Border _commentCard;
    private readonly TextBlock _commentText;

    // Raw header
    private readonly TextBox _headerFilterBox;
    private readonly StackPanel _rawHeaderHost;

    private readonly Dictionary<PaletteName, WriteableBitmap> _paletteSwatches = new();
    private InspectorMetadataPresentation? _cachedMetaPresentation;
    private Guid? _cachedMetaFileId;
    private string? _cachedMetaChannel;
    private ScanDirection? _cachedMetaDirection;
    private FrequencyShiftBoundsKey? _activeFrequencyShiftKey;
    private FrequencyShiftBounds? _loadedFrequencyShiftBounds;
    private CancellationTokenSource? _frequencyShiftCts;
    private bool _guard;
    private bool _editingScaleMin;
    private bool _editingScaleMax;

    public Action<SXMMetadata>? OnExportPngRequested { get; set; }
    public Action<string, IReadOnlyList<Guid>>? OnCreateTagWithFilesRequested { get; set; }

    public InspectorView(AppModel model)
    {
        _model = model;
        BorderThickness = new Thickness(1, 0, 0, 0);

        foreach (PaletteName p in SXMValueExtensions.AllPalettes)
        {
            _paletteSwatches[p] = BitmapBridge.CreatePaletteSwatchBitmap(p, 42, 13, invert: false);
        }

        _emptySelectionText = new TextBlock
        {
            Text = "Select an .sxm scan to inspect parameters and adjust contrast.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.7,
            Margin = new Thickness(8, 24)
        };

        // Display controls
        _channelBox = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        _channelBox.SelectionChanged += (_, _) =>
        {
            if (_guard || _channelBox.SelectedItem is not string ch) return;
            _model.SelectedChannel = ch;
        };

        _directionPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };

        _processingBox = new ComboBox
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = SXMValueExtensions.AllProcessingModes,
            ItemTemplate = new FuncDataTemplate<ProcessingMode>((m, _) => new TextBlock { Text = m.Label(), FontSize = 12 })
        };
        _processingBox.SelectionChanged += (_, _) =>
        {
            if (_guard || _processingBox.SelectedItem is not ProcessingMode pm) return;
            _model.SelectedProcessing = pm;
        };

        _paletteBox = new ComboBox
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = SXMValueExtensions.AllPalettes,
            ItemTemplate = new FuncDataTemplate<PaletteName>((p, _) =>
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                if (_paletteSwatches.TryGetValue(p, out WriteableBitmap? bmp))
                {
                    row.Children.Add(new Image { Source = bmp, Width = 42, Height = 13, Stretch = Stretch.Fill });
                }
                row.Children.Add(new TextBlock { Text = p.Label(), FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
                return row;
            })
        };
        _paletteBox.SelectionChanged += (_, _) =>
        {
            if (_guard || _paletteBox.SelectedItem is not PaletteName p) return;
            _model.SelectedPalette = p;
        };

        _invertCheck = new CheckBox { Content = "Invert", VerticalAlignment = VerticalAlignment.Center };
        _invertCheck.IsCheckedChanged += (_, _) =>
        {
            if (_guard) return;
            _model.InvertPalette = _invertCheck.IsChecked ?? false;
        };

        _scalePresetsPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };

        _paletteStrip = new PaletteStripControl();
        _histogramControl = new HistogramControl
        {
            OnScaleChanged = (min, max) => _model.UpdateScale(min, max),
            OnResetScale = () => _model.ApplyScalePreset(ScalePreset.Full)
        };

        _binsBox = new ComboBox
        {
            ItemsSource = new[] { 64, 128, 256, 512 },
            MinWidth = 74
        };
        _binsBox.SelectionChanged += (_, _) =>
        {
            if (_guard || _binsBox.SelectedItem is not int bins) return;
            _model.HistogramBins = bins;
        };

        _scaleMinBox = new TextBox { Watermark = "Min", FontSize = 11.5 };
        _scaleMaxBox = new TextBox { Watermark = "Max", FontSize = 11.5 };
        WireBufferedScaleField(_scaleMinBox, isMin: true);
        WireBufferedScaleField(_scaleMaxBox, isMin: false);

        _statsSummaryText = new TextBlock
        {
            FontSize = 11,
            Opacity = 0.8,
            TextWrapping = TextWrapping.Wrap
        };

        _exportPngBtn = new Button
        {
            Content = "Export PNG\u2026",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center
        };
        _exportPngBtn.Click += (_, _) =>
        {
            if (_model.SelectedFile is { } file) OnExportPngRequested?.Invoke(file);
        };

        // Tags section
        _tagsWrap = new WrapPanel { Orientation = Orientation.Horizontal };
        _newTagFromFileBtn = new Button { Content = "+ New Tag", FontSize = 11.5, Padding = new Thickness(8, 3) };
        _newTagFromFileBtn.Click += (_, _) =>
        {
            if (_model.SelectedFile is { } file)
            {
                OnCreateTagWithFilesRequested?.Invoke(file.Filename, [file.Id]);
            }
        };

        // Acquisition summary cards
        _acqGrid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,*"),
            RowDefinitions = new RowDefinitions("Auto,Auto,Auto,Auto")
        };
        _timestampsText = new TextBlock { FontSize = 11, Opacity = 0.8, TextWrapping = TextWrapping.Wrap };
        _commentText = new TextBlock { FontSize = 11.5, TextWrapping = TextWrapping.Wrap };
        _commentCard = new Border
        {
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(8, 6),
            IsVisible = false,
            Child = _commentText
        };

        // Raw Header
        _headerFilterBox = new TextBox { Watermark = "Filter raw header keys\u2026", FontSize = 11.5 };
        _headerFilterBox.TextChanged += (_, _) => RefreshRawHeaderEntries();
        _rawHeaderHost = new StackPanel { Spacing = 2 };

        var displayGrid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*"),
            RowDefinitions = new RowDefinitions("Auto,Auto,Auto,Auto")
        };
        AddLabeledRow(displayGrid, 0, "Channel", _channelBox);
        AddLabeledRow(displayGrid, 1, "Direction", _directionPanel);
        AddLabeledRow(displayGrid, 2, "Process", _processingBox);

        var paletteRow = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(_invertCheck, Dock.Right);
        _invertCheck.Margin = new Thickness(6, 0, 0, 0);
        paletteRow.Children.Add(_invertCheck);
        paletteRow.Children.Add(_paletteBox);
        AddLabeledRow(displayGrid, 3, "Palette", paletteRow);

        var boundsGrid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,*")
        };
        _scaleMinBox.Margin = new Thickness(0, 0, 6, 0);
        Grid.SetColumn(_scaleMinBox, 0);
        Grid.SetColumn(_scaleMaxBox, 1);
        boundsGrid.Children.AddRange([_scaleMinBox, _scaleMaxBox]);

        var binsDock = new DockPanel();
        DockPanel.SetDock(_binsBox, Dock.Right);
        binsDock.Children.Add(_binsBox);
        binsDock.Children.Add(new TextBlock
        {
            Text = "Contrast Range",
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 11.5,
            Opacity = 0.8
        });

        _contentStack = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                SectionTitle("DISPLAY & CONTRAST"),
                displayGrid,
                _scalePresetsPanel,
                _paletteStrip,
                _histogramControl,
                binsDock,
                boundsGrid,
                _statsSummaryText,
                _exportPngBtn,

                SectionTitle("TAGS"),
                _tagsWrap,
                _newTagFromFileBtn,

                SectionTitle("ACQUISITION & FILE"),
                _acqGrid,
                _timestampsText,
                _commentCard,

                SectionTitle("RAW HEADER"),
                _headerFilterBox,
                _rawHeaderHost
            }
        };

        _rootStack = new StackPanel
        {
            Spacing = 6,
            Children = { _emptySelectionText, _contentStack }
        };

        Child = new ScrollViewer
        {
            Padding = new Thickness(12, 10),
            Content = _rootStack
        };

        ActualThemeVariantChanged += (_, _) => ApplyTheme();
        ApplyTheme();
        SyncFromModel();
    }

    private static TextBlock SectionTitle(string text) => new()
    {
        Text = text,
        FontSize = 11,
        FontWeight = FontWeight.SemiBold,
        Opacity = 0.7,
        Margin = new Thickness(0, 6, 0, 0)
    };

    private static void AddLabeledRow(Grid grid, int row, string label, Control control)
    {
        var tb = new TextBlock
        {
            Text = label,
            FontSize = 11.5,
            Opacity = 0.8,
            Margin = new Thickness(0, 3, 8, 3),
            VerticalAlignment = VerticalAlignment.Center
        };
        control.Margin = new Thickness(0, 3);
        Grid.SetRow(tb, row);
        Grid.SetColumn(tb, 0);
        Grid.SetRow(control, row);
        Grid.SetColumn(control, 1);
        grid.Children.Add(tb);
        grid.Children.Add(control);
    }

    private void WireBufferedScaleField(TextBox box, bool isMin)
    {
        box.GotFocus += (_, _) =>
        {
            if (isMin) _editingScaleMin = true; else _editingScaleMax = true;
        };
        box.LostFocus += (_, _) =>
        {
            if (isMin) _editingScaleMin = false; else _editingScaleMax = false;
            CommitScaleBoundsFromInputs();
        };
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                CommitScaleBoundsFromInputs();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                if (isMin) _editingScaleMin = false; else _editingScaleMax = false;
                SyncScaleControlsOnly();
                e.Handled = true;
            }
        };
    }

    private void CommitScaleBoundsFromInputs()
    {
        string unit = _cachedMetaPresentation?.ChannelUnit ?? string.Empty;
        if (!ScientificFormatters.TryParseScaleInput(_scaleMinBox.Text ?? string.Empty, unit, out double minVal)
            || !ScientificFormatters.TryParseScaleInput(_scaleMaxBox.Text ?? string.Empty, unit, out double maxVal))
        {
            SyncScaleControlsOnly();
            return;
        }
        if (maxVal > minVal)
        {
            _model.UpdateScale(minVal, maxVal);
        }
        else
        {
            SyncScaleControlsOnly();
        }
    }

    public void ApplyTheme()
    {
        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        Background = theme.SidebarSurfaceBrush;
        BorderBrush = theme.HairlineBorderBrush;
        _commentCard.Background = theme.ElevatedCardBrush;
        _commentCard.BorderBrush = theme.HairlineBorderBrush;
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        CancelFrequencyShiftLoad();
    }

    public void SyncFromModel()
    {
        _guard = true;
        try
        {
            AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
            SXMMetadata? file = _model.SelectedFile;
            bool hasFile = file is not null;
            _emptySelectionText.IsVisible = !hasFile;
            _contentStack.IsVisible = hasFile;
            if (file is null)
            {
                CancelFrequencyShiftLoad();
                _cachedMetaFileId = null;
                _cachedMetaChannel = null;
                _cachedMetaDirection = null;
                _cachedMetaPresentation = null;
                _activeFrequencyShiftKey = null;
                _loadedFrequencyShiftBounds = null;
                return;
            }

            _channelBox.ItemsSource = file.Channels.Select(c => c.Name).ToArray();
            _channelBox.SelectedItem = _model.SelectedChannel;

            SXMChannel? chInfo = file.Channels.FirstOrDefault(
                c => string.Equals(c.Name, _model.SelectedChannel, StringComparison.Ordinal));
            RebuildDirectionButtons(chInfo, theme);

            _processingBox.SelectedItem = _model.SelectedProcessing;
            _paletteBox.SelectedItem = _model.SelectedPalette;
            _invertCheck.IsChecked = _model.InvertPalette;
            _binsBox.SelectedItem = _model.HistogramBins;

            _exportPngBtn.IsEnabled = _model.Mode == BrowserMode.Single && !string.IsNullOrEmpty(_model.SelectedChannel);

            RebuildScalePresetButtons(theme);
            RebuildFileTags(file);

            SyncMetadataAndFrequencyShiftBounds(file, theme);
            SyncScaleControlsCore(theme);
        }
        finally
        {
            _guard = false;
        }
    }

    public void SyncScaleControlsOnly()
    {
        bool prevGuard = _guard;
        _guard = true;
        try
        {
            AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
            if (_model.SelectedFile is { } file)
            {
                SyncMetadataAndFrequencyShiftBounds(file, theme);
            }
            SyncScaleControlsCore(theme);
        }
        finally
        {
            _guard = prevGuard;
        }
    }

    private void SyncScaleControlsCore(AppThemePalette theme)
    {
        _paletteStrip.Palette = _model.SelectedPalette;
        _paletteStrip.Invert = _model.InvertPalette;
        _histogramControl.UpdateData(_model.SelectedHistogramStats, _model.ScaleMin, _model.ScaleMax);

        RebuildScalePresetButtons(theme);

        string unit = _cachedMetaPresentation?.ChannelUnit ?? string.Empty;
        if (!_editingScaleMin)
        {
            _scaleMinBox.Text = _model.ScaleMin is { } min ? ScientificFormatters.FormatSi(min, unit, 4) : "";
        }
        if (!_editingScaleMax)
        {
            _scaleMaxBox.Text = _model.ScaleMax is { } max ? ScientificFormatters.FormatSi(max, unit, 4) : "";
        }

        if (_model.SelectedStats is { } stats)
        {
            _statsSummaryText.Text =
                $"Min {ScientificFormatters.FormatSi(stats.Min, unit, 3)} \u00B7 " +
                $"Max {ScientificFormatters.FormatSi(stats.Max, unit, 3)}\n" +
                $"Mean {ScientificFormatters.FormatSi(stats.Mean, unit, 3)} \u00B7 " +
                $"RMS {ScientificFormatters.FormatSi(stats.Std, unit, 3)}";
        }
        else
        {
            _statsSummaryText.Text = _model.Mode == BrowserMode.Single
                ? "Open in Single View for live histogram statistics."
                : "Switch to Single View to adjust contrast bounds.";
        }
    }

    private void SyncMetadataAndFrequencyShiftBounds(SXMMetadata file, AppThemePalette theme)
    {
        bool metaChanged = _cachedMetaFileId != file.Id
            || !string.Equals(_cachedMetaChannel, _model.SelectedChannel, StringComparison.Ordinal)
            || _cachedMetaPresentation is null;
        bool dirChanged = _cachedMetaDirection != _model.SelectedDirection;

        InspectorMetadataPresentation presentation;
        if (metaChanged)
        {
            _cachedMetaFileId = file.Id;
            _cachedMetaChannel = _model.SelectedChannel;
            presentation = new InspectorMetadataPresentation(file, _model.SelectedChannel);
            _cachedMetaPresentation = presentation;
            _channelBox.ItemsSource = file.Channels.Select(c => c.Name).ToArray();
            _channelBox.SelectedItem = _model.SelectedChannel;
            _processingBox.SelectedItem = _model.SelectedProcessing;
            _paletteBox.SelectedItem = _model.SelectedPalette;
            _invertCheck.IsChecked = _model.InvertPalette;
            SXMChannel? chInfo = file.Channels.FirstOrDefault(
                c => string.Equals(c.Name, _model.SelectedChannel, StringComparison.Ordinal));
            RebuildDirectionButtons(chInfo, theme);
            RefreshRawHeaderEntries();
        }
        else
        {
            presentation = _cachedMetaPresentation!;
            if (dirChanged)
            {
                SXMChannel? chInfo = file.Channels.FirstOrDefault(
                    c => string.Equals(c.Name, _model.SelectedChannel, StringComparison.Ordinal));
                RebuildDirectionButtons(chInfo, theme);
            }
        }
        _cachedMetaDirection = _model.SelectedDirection;

        FrequencyShiftBoundsKey? key = IsVisible && presentation.IsFrequencyShiftChannel
            ? _model.GetFrequencyShiftBoundsKey(file, presentation.ChannelName, _model.SelectedDirection)
            : null;

        FrequencyShiftBounds? currentBounds = null;
        if (key is { } k)
        {
            currentBounds = _model.GetCachedFrequencyShiftBounds(k)
                ?? (_activeFrequencyShiftKey == k ? _loadedFrequencyShiftBounds : null);
        }

        if (metaChanged || dirChanged || key != _activeFrequencyShiftKey)
        {
            RebuildAcquisitionSection(presentation, theme, currentBounds);
        }

        if (key is null)
        {
            CancelFrequencyShiftLoad();
            _activeFrequencyShiftKey = null;
            _loadedFrequencyShiftBounds = null;
        }
        else if (_model.GetCachedFrequencyShiftBounds(key.Value) is { } cached)
        {
            CancelFrequencyShiftLoad();
            _activeFrequencyShiftKey = key;
            _loadedFrequencyShiftBounds = cached;
        }
        else if (_activeFrequencyShiftKey != key)
        {
            CancelFrequencyShiftLoad();
            _activeFrequencyShiftKey = key;
            _loadedFrequencyShiftBounds = null;
            var cts = new CancellationTokenSource();
            _frequencyShiftCts = cts;
            _ = LoadFrequencyShiftBoundsForUiAsync(file, key.Value, cts);
        }
    }

    private void CancelFrequencyShiftLoad()
    {
        if (_frequencyShiftCts is not null)
        {
            try { _frequencyShiftCts.Cancel(); } catch (ObjectDisposedException) { }
            _frequencyShiftCts.Dispose();
            _frequencyShiftCts = null;
        }
    }

    private async Task LoadFrequencyShiftBoundsForUiAsync(
        SXMMetadata file,
        FrequencyShiftBoundsKey key,
        CancellationTokenSource cts)
    {
        FrequencyShiftBounds? bounds = await _model.LoadFrequencyShiftBoundsAsync(file, key, cts.Token)
            .ConfigureAwait(false);
        Dispatcher.UIThread.Post(() =>
        {
            if (cts.IsCancellationRequested
                || !ReferenceEquals(_frequencyShiftCts, cts)
                || _activeFrequencyShiftKey != key
                || _cachedMetaPresentation is null)
            {
                return;
            }
            _loadedFrequencyShiftBounds = bounds;
            RebuildAcquisitionSection(_cachedMetaPresentation, AppTheme.Resolve(ActualThemeVariant), bounds);
        });
    }

    private void RebuildDirectionButtons(SXMChannel? channel, AppThemePalette theme)
    {
        _directionPanel.Children.Clear();
        IReadOnlyList<ScanDirection> dirs = channel?.Directions ?? [ScanDirection.Fwd];
        foreach (ScanDirection dir in dirs)
        {
            bool active = _model.SelectedDirection == dir;
            var btn = new Button
            {
                Content = dir == ScanDirection.Fwd ? "Fwd" : "Bwd",
                Padding = new Thickness(10, 3),
                FontSize = 11.5,
                Background = active ? theme.AccentSubtleBrush : Brushes.Transparent
            };
            btn.Click += (_, _) => _model.SelectedDirection = dir;
            _directionPanel.Children.Add(btn);
        }
    }

    private void RebuildScalePresetButtons(AppThemePalette theme)
    {
        _scalePresetsPanel.Children.Clear();
        bool hasStats = _model.SelectedStats is not null;
        foreach (ScalePreset preset in ScalePresetExtensions.AllPresets)
        {
            bool active = _model.ScalePreset == preset;
            var btn = new Button
            {
                Content = preset.Label(),
                Padding = new Thickness(7, 3),
                FontSize = 11,
                IsEnabled = hasStats || preset == ScalePreset.Manual,
                Background = active ? theme.AccentSubtleBrush : Brushes.Transparent
            };
            btn.Click += (_, _) => _model.ApplyScalePreset(preset);
            _scalePresetsPanel.Children.Add(btn);
        }
    }

    private void RebuildFileTags(SXMMetadata file)
    {
        _tagsWrap.Children.Clear();
        IReadOnlyList<DatasetTagV1> tags = _model.Tags;
        if (tags.Count == 0)
        {
            _tagsWrap.Children.Add(new TextBlock { Text = "No dataset tags", FontSize = 11.5, Opacity = 0.6 });
            return;
        }

        foreach (DatasetTagV1 tag in tags)
        {
            bool assigned = _model.IsFileTagged(file.Id, tag.Id);
            var cb = new CheckBox
            {
                Content = tag.Name,
                IsChecked = assigned,
                FontSize = 11.5,
                Margin = new Thickness(0, 0, 8, 2)
            };
            cb.IsCheckedChanged += async (_, _) =>
            {
                if (_guard) return;
                await _model.AssignFilesToTagAsync([file.Id], tag.Id, cb.IsChecked ?? false);
            };
            _tagsWrap.Children.Add(cb);
        }
    }

    private void RebuildAcquisitionSection(
        InspectorMetadataPresentation meta,
        AppThemePalette theme,
        FrequencyShiftBounds? frequencyShiftBounds = null)
    {
        _acqGrid.Children.Clear();

        void AddCard(int col, int row, string label, string value)
        {
            var card = new Border
            {
                Margin = new Thickness(3),
                CornerRadius = new CornerRadius(6),
                BorderThickness = new Thickness(1),
                BorderBrush = theme.HairlineBorderBrush,
                Background = theme.ElevatedCardBrush,
                Padding = new Thickness(8, 5),
                Child = new StackPanel
                {
                    Spacing = 1,
                    Children =
                    {
                        new TextBlock { Text = label, FontSize = 10, Foreground = theme.TextMutedBrush },
                        new TextBlock
                        {
                            Text = value,
                            FontSize = 11.5,
                            FontWeight = FontWeight.Medium,
                            TextTrimming = TextTrimming.CharacterEllipsis
                        }
                    }
                }
            };
            Grid.SetColumn(card, col);
            Grid.SetRow(card, row);
            _acqGrid.Children.Add(card);
        }

        string footprint = ScientificFormatters.FormatScanFootprint(meta.ScanRangeMeters);
        string pixels = $"{meta.PixelWidth} \u00D7 {meta.PixelHeight}";
        string bias = meta.SampleBiasVolts is { } b ? ScientificFormatters.FormatSi(b, "V", 3) : "\u2014";
        string setpoint = meta.SetpointValue is { } sv
            ? ScientificFormatters.FormatSi(sv, meta.SetpointUnit ?? string.Empty, 3)
            : (meta.SetpointRawText ?? "\u2014");
        string temp = ScientificFormatters.FormatTemperature(meta.TemperatureKelvin);
        string acq = ScientificFormatters.FormatDuration(meta.AcquisitionSeconds);

        AddCard(0, 0, "Footprint", footprint);
        AddCard(1, 0, "Pixels", pixels);
        AddCard(0, 1, "Sample Bias", bias);
        AddCard(1, 1, meta.FeedbackControllerName ?? "Setpoint", setpoint);
        AddCard(0, 2, "Temperature", temp);
        AddCard(1, 2, "Acq. Time", acq);
        if (meta.IsFrequencyShiftChannel)
        {
            AddCard(
                0,
                3,
                "\u0394f Min",
                frequencyShiftBounds is { } dfMinBounds
                    ? ScientificFormatters.FormatFrequencyShift(dfMinBounds.Min, meta.ChannelUnit)
                    : "\u2014");
            AddCard(
                1,
                3,
                "\u0394f Max",
                frequencyShiftBounds is { } dfMaxBounds
                    ? ScientificFormatters.FormatFrequencyShift(dfMaxBounds.Max, meta.ChannelUnit)
                    : "\u2014");
        }

        string recorded = meta.RecordedTime is { } rt
            ? rt.LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)
            : "\u2014";
        string modified = meta.ModifiedTime.LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        string offset = ScientificFormatters.FormatOffset(meta.ScanOffsetMeters);
        string angle = meta.ScanAngleDegrees is { } a ? $"{a.ToString("0.#", CultureInfo.InvariantCulture)}\u00B0" : "\u2014";

        _timestampsText.Text = $"Offset: {offset}  \u00B7  Angle: {angle}\nRecorded: {recorded}\nModified: {modified}";

        if (!string.IsNullOrWhiteSpace(meta.Comment))
        {
            _commentCard.IsVisible = true;
            _commentText.Text = meta.Comment;
        }
        else
        {
            _commentCard.IsVisible = false;
        }
    }

    private void RefreshRawHeaderEntries()
    {
        _rawHeaderHost.Children.Clear();
        if (_cachedMetaPresentation is null) return;
        string query = _headerFilterBox.Text ?? string.Empty;
        IReadOnlyList<InspectorHeaderEntry> entries = _cachedMetaPresentation.FilteredHeaderEntries(query);
        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);

        foreach (InspectorHeaderEntry entry in entries.Take(120))
        {
            var grid = new Grid
            {
                ColumnDefinitions = new ColumnDefinitions("110,*"),
                Margin = new Thickness(0, 1)
            };
            var k = new SelectableTextBlock
            {
                Text = entry.Key,
                FontSize = 10.5,
                Foreground = theme.TextSecondaryBrush,
                TextWrapping = TextWrapping.Wrap
            };
            var v = new SelectableTextBlock
            {
                Text = entry.Value,
                FontSize = 10.5,
                Foreground = theme.TextPrimaryBrush,
                TextWrapping = TextWrapping.Wrap
            };
            Grid.SetColumn(k, 0);
            Grid.SetColumn(v, 1);
            grid.Children.AddRange([k, v]);
            _rawHeaderHost.Children.Add(grid);
        }
    }
}
