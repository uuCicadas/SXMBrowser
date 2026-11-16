using System;
using System.Collections.Generic;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Controllers;
using SXMBrowser.Desktop.Services;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Views;

public sealed class BrowserToolbar : Border
{
    private readonly AppModel _model;
    private readonly Button _openBtn;
    private readonly Button _rescanBtn;
    private readonly Button _gridModeBtn;
    private readonly Button _singleModeBtn;
    private readonly ComboBox _sortBox;
    private readonly Button _sortDirBtn;
    private readonly ComboBox _densityBox;
    private readonly StackPanel _singleZoomPanel;
    private readonly Button _fitBtn;
    private readonly Button _actualSizeBtn;
    private readonly TextBlock _zoomLabel;
    private readonly ComboBox _stmPaletteBox;
    private readonly CheckBox _spectraCardsToggle;
    private readonly TextBox _searchBox;
    private readonly TextBlock _searchCountBadge;
    private readonly Button _clearSearchBtn;
    private readonly Button _sidebarToggleBtn;
    private readonly Button _inspectorToggleBtn;

    private readonly Dictionary<PaletteName, WriteableBitmap> _paletteSwatches = new();
    private bool _guard;

    public Action? OnOpenFolderRequested { get; set; }

    public BrowserToolbar(AppModel model)
    {
        _model = model;
        BorderThickness = new Thickness(0, 0, 0, 1);
        Padding = new Thickness(10, 6);

        foreach (PaletteName p in SXMValueExtensions.AllPalettes)
        {
            _paletteSwatches[p] = BitmapBridge.CreatePaletteSwatchBitmap(p, 42, 13, invert: false);
        }

        _openBtn = new Button { Content = "Open Folder\u2026", Padding = new Thickness(10, 4) };
        _rescanBtn = new Button { Content = "Rescan", Padding = new Thickness(8, 4) };
        _gridModeBtn = new Button { Content = "Grid", Padding = new Thickness(10, 4) };
        _singleModeBtn = new Button { Content = "Single", Padding = new Thickness(10, 4) };

        _sortBox = new ComboBox
        {
            ItemsSource = new[] { "Name", "Modified", "Recorded" },
            MinWidth = 98
        };
        _sortDirBtn = new Button { Content = "\u2193", Padding = new Thickness(7, 4) };

        _densityBox = new ComboBox
        {
            ItemsSource = new[] { "Compact", "Comfortable", "Large" },
            MinWidth = 104
        };

        _fitBtn = new Button { Content = "Fit", Padding = new Thickness(7, 4) };
        _actualSizeBtn = new Button { Content = "100%", Padding = new Thickness(7, 4) };
        var zoomOutBtn = new Button { Content = "-", Padding = new Thickness(7, 4) };
        var zoomInBtn = new Button { Content = "+", Padding = new Thickness(7, 4) };
        _zoomLabel = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 11.5,
            Margin = new Thickness(4, 0)
        };
        _singleZoomPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            Children = { _fitBtn, _actualSizeBtn, zoomOutBtn, _zoomLabel, zoomInBtn }
        };

        _stmPaletteBox = new ComboBox
        {
            ItemsSource = SXMValueExtensions.AllPalettes,
            MinWidth = 148,
            ItemTemplate = new FuncDataTemplate<PaletteName>((palette, _) =>
            {
                var row = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    VerticalAlignment = VerticalAlignment.Center
                };
                if (_paletteSwatches.TryGetValue(palette, out WriteableBitmap? bmp))
                {
                    row.Children.Add(new Border
                    {
                        CornerRadius = new CornerRadius(2),
                        ClipToBounds = true,
                        VerticalAlignment = VerticalAlignment.Center,
                        Child = new Image { Source = bmp, Width = 42, Height = 13, Stretch = Stretch.Fill }
                    });
                }
                row.Children.Add(new TextBlock
                {
                    Text = palette.Label(),
                    VerticalAlignment = VerticalAlignment.Center,
                    FontSize = 12
                });
                return row;
            })
        };

        _spectraCardsToggle = new CheckBox
        {
            Content = "Spectra Cards",
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 12
        };

        _searchBox = new TextBox
        {
            Watermark = "Filter .sxm / .dat (Ctrl+F)",
            Width = 190
        };
        _searchCountBadge = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 11,
            Opacity = 0.75,
            IsVisible = false
        };
        _clearSearchBtn = new Button
        {
            Content = "\u2715",
            Padding = new Thickness(5, 3),
            IsVisible = false
        };

        _sidebarToggleBtn = new Button { Content = "Sidebar", Padding = new Thickness(8, 4) };
        _inspectorToggleBtn = new Button { Content = "Inspector", Padding = new Thickness(8, 4) };

        // Wire events
        _openBtn.Click += (_, _) => OnOpenFolderRequested?.Invoke();
        _rescanBtn.Click += async (_, _) => await _model.RescanAsync();
        _gridModeBtn.Click += (_, _) => _model.ShowGridView();
        _singleModeBtn.Click += (_, _) => _model.OpenSingleView();

        _sortBox.SelectionChanged += (_, _) =>
        {
            if (_guard) return;
            _model.SortCriterion = _sortBox.SelectedIndex switch
            {
                1 => FileSortCriterion.ModifiedTime,
                2 => FileSortCriterion.RecordedTime,
                _ => FileSortCriterion.Name
            };
        };
        _sortDirBtn.Click += (_, _) => _model.SortAscending = !_model.SortAscending;

        _densityBox.SelectionChanged += (_, _) =>
        {
            if (_guard) return;
            _model.GridDensity = _densityBox.SelectedIndex switch
            {
                0 => GridDensity.Compact,
                2 => GridDensity.Large,
                _ => GridDensity.Comfortable
            };
        };

        _fitBtn.Click += (_, _) => _model.FitViewer();
        _actualSizeBtn.Click += (_, _) => _model.ShowActualSize();
        zoomOutBtn.Click += (_, _) => _model.StepViewerZoom(false);
        zoomInBtn.Click += (_, _) => _model.StepViewerZoom(true);

        _stmPaletteBox.SelectionChanged += (_, _) =>
        {
            if (_guard || _stmPaletteBox.SelectedItem is not PaletteName p) return;
            _model.StmPreviewPalette = p;
        };

        _spectraCardsToggle.IsCheckedChanged += (_, _) =>
        {
            if (_guard) return;
            _model.ShowsGridSpectroscopyCards = _spectraCardsToggle.IsChecked ?? true;
        };

        _searchBox.TextChanged += (_, _) =>
        {
            if (_guard) return;
            _model.SearchQuery = _searchBox.Text ?? string.Empty;
        };
        _clearSearchBtn.Click += (_, _) => _model.SearchQuery = string.Empty;

        _sidebarToggleBtn.Click += (_, _) => _model.SidebarVisible = !_model.SidebarVisible;
        _inspectorToggleBtn.Click += (_, _) => _model.InspectorVisible = !_model.InspectorVisible;

        var leftControls = new WrapPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };
        void AddSpaced(Control c, double right = 6)
        {
            c.Margin = new Thickness(0, 2, right, 2);
            leftControls.Children.Add(c);
        }

        AddSpaced(_openBtn);
        AddSpaced(_rescanBtn, 12);
        AddSpaced(_gridModeBtn, 2);
        AddSpaced(_singleModeBtn, 12);
        AddSpaced(_sortBox, 2);
        AddSpaced(_sortDirBtn, 10);
        AddSpaced(_densityBox, 10);
        AddSpaced(_singleZoomPanel, 10);
        AddSpaced(new TextBlock
        {
            Text = "STM:",
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 12,
            Opacity = 0.8
        }, 4);
        AddSpaced(_stmPaletteBox, 10);
        AddSpaced(_spectraCardsToggle, 12);

        var rightControls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                _searchBox,
                _searchCountBadge,
                _clearSearchBtn,
                _sidebarToggleBtn,
                _inspectorToggleBtn
            }
        };

        var root = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(rightControls, Dock.Right);
        root.Children.Add(rightControls);
        root.Children.Add(leftControls);
        Child = root;

        ActualThemeVariantChanged += (_, _) => ApplyTheme();
        SyncFromModel();
        ApplyTheme();
    }

    public void FocusSearch()
    {
        _searchBox.Focus();
        _searchBox.SelectAll();
    }

    public void ApplyTheme()
    {
        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        Background = theme.ToolbarSurfaceBrush;
        BorderBrush = theme.HairlineBorderBrush;
        UpdateHighlightButtons(theme);
    }

    public void SyncFromModel()
    {
        _guard = true;
        try
        {
            _rescanBtn.IsEnabled = !string.IsNullOrEmpty(_model.FolderPath);

            bool isGrid = _model.Mode == BrowserMode.Grid;
            _singleModeBtn.IsEnabled = _model.VisibleFiles.Count > 0;
            _densityBox.IsVisible = isGrid;
            _spectraCardsToggle.IsVisible = isGrid;
            _singleZoomPanel.IsVisible = !isGrid;

            _sortBox.SelectedIndex = _model.SortCriterion switch
            {
                FileSortCriterion.ModifiedTime => 1,
                FileSortCriterion.RecordedTime => 2,
                _ => 0
            };
            _sortDirBtn.Content = _model.SortAscending ? "\u2191" : "\u2193";
            ToolTip.SetTip(_sortDirBtn, _model.SortAscending ? "Ascending (click to reverse)" : "Descending (click to reverse)");

            _densityBox.SelectedIndex = _model.GridDensity switch
            {
                GridDensity.Compact => 0,
                GridDensity.Large => 2,
                _ => 1
            };

            _stmPaletteBox.SelectedItem = _model.StmPreviewPalette;
            _spectraCardsToggle.IsChecked = _model.ShowsGridSpectroscopyCards;

            if (!string.Equals(_searchBox.Text, _model.SearchQuery, StringComparison.Ordinal))
            {
                _searchBox.Text = _model.SearchQuery;
            }
            bool searchActive = _model.SearchIsActive;
            _clearSearchBtn.IsVisible = searchActive;
            _searchCountBadge.IsVisible = searchActive;
            if (searchActive)
            {
                _searchCountBadge.Text = $"{_model.VisibleFiles.Count}/{_model.AllFiles.Count}";
            }

            _zoomLabel.Text = _model.FormattedZoomLabel;
            ApplyTheme();
        }
        finally
        {
            _guard = false;
        }
    }

    private void UpdateHighlightButtons(AppThemePalette theme)
    {
        bool isGrid = _model.Mode == BrowserMode.Grid;
        _gridModeBtn.Background = isGrid ? theme.AccentSubtleBrush : Brushes.Transparent;
        _singleModeBtn.Background = !isGrid ? theme.AccentSubtleBrush : Brushes.Transparent;
        _sidebarToggleBtn.Background = _model.SidebarVisible ? theme.AccentSubtleBrush : Brushes.Transparent;
        _inspectorToggleBtn.Background = _model.InspectorVisible ? theme.AccentSubtleBrush : Brushes.Transparent;
    }
}
