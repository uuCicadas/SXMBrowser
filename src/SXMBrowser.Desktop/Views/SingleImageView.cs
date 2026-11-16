using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Controllers;
using SXMBrowser.Desktop.Controls;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Views;

public sealed class SingleImageView : Grid
{
    private readonly AppModel _model;
    private readonly Button _backBtn;
    private readonly Button _prevBtn;
    private readonly Button _nextBtn;
    private readonly TextBlock _indexText;
    private readonly TextBlock _titleText;
    private readonly TextBlock _subtitleText;

    private readonly SingleImageCanvasControl _canvas;
    private readonly Border _statusOverlay;
    private readonly TextBlock _statusOverlayText;
    private readonly Button _retryRenderBtn;

    private readonly Border _drawerBorder;
    private readonly Border _drawerDragHandle;
    private readonly Button _drawerToggleBtn;
    private readonly StackPanel _groupTabsPanel;
    private readonly TextBlock _drawerCountText;
    private readonly ComboBox _xColumnBox;
    private readonly ComboBox _yColumnBox;
    private readonly TextBlock _columnSummaryText;
    private readonly Grid _drawerContentGrid;
    private readonly SpectroscopyPlotControl _plotControl;
    private readonly StackPanel _legendHost;

    private readonly RowDefinition _drawerRow;
    private bool _guard;
    private bool _isResizingDrawer;
    private Point _resizeStartScreen;
    private double _resizeStartHeight;

    public SingleImageView(AppModel model)
    {
        _model = model;

        RowDefinitions = new RowDefinitions("Auto,*,Auto");
        _drawerRow = RowDefinitions[2];

        // Top nav bar
        _backBtn = new Button { Content = "\u2190 Grid", Padding = new Thickness(8, 4) };
        _prevBtn = new Button { Content = "\u2039", Padding = new Thickness(8, 3) };
        _nextBtn = new Button { Content = "\u203A", Padding = new Thickness(8, 3) };
        _indexText = new TextBlock { VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5, Opacity = 0.75 };
        _titleText = new TextBlock { VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeight.SemiBold, FontSize = 13 };
        _subtitleText = new TextBlock { VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5, Opacity = 0.7 };

        _backBtn.Click += (_, _) => _model.ShowGridView();
        _prevBtn.Click += (_, _) => _model.StepSelection(-1);
        _nextBtn.Click += (_, _) => _model.StepSelection(1);

        var navRight = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { _prevBtn, _indexText, _nextBtn }
        };
        var navLeft = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { _backBtn, _titleText, _subtitleText }
        };
        var navDock = new DockPanel();
        DockPanel.SetDock(navRight, Dock.Right);
        navDock.Children.Add(navRight);
        navDock.Children.Add(navLeft);

        var navBar = new Border
        {
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(12, 6),
            Child = navDock
        };
        Grid.SetRow(navBar, 0);

        // Center image canvas + status overlay
        _canvas = new SingleImageCanvasControl
        {
            OnGeometryChanged = (imgSize, viewSize) => _model.ReconcileViewerGeometry(imgSize, viewSize),
            OnZoom = (factor, anchor) => _model.ZoomViewer(factor, anchor),
            OnPan = delta => _model.PanViewer(delta),
            OnToggleFitActual = anchor => _model.ToggleFitOrActualSize(anchor),
            OnMarkerClicked = id => _model.FocusSpectrumInDrawer(id)
        };

        _statusOverlayText = new TextBlock
        {
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        _retryRenderBtn = new Button
        {
            Content = "Retry",
            IsVisible = false,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        _retryRenderBtn.Click += (_, _) => _model.RefreshSelectedImage(resetScale: false);

        _statusOverlay = new Border
        {
            IsVisible = false,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(16, 10),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Child = new StackPanel
            {
                Spacing = 8,
                Children = { _statusOverlayText, _retryRenderBtn }
            }
        };

        var canvasHost = new Grid
        {
            Children = { _canvas, _statusOverlay }
        };
        Grid.SetRow(canvasHost, 1);

        // Bottom spectroscopy drawer
        _drawerDragHandle = new Border
        {
            Height = 6,
            Cursor = new Cursor(StandardCursorType.SizeNorthSouth),
            Background = Brushes.Transparent
        };
        _drawerDragHandle.PointerPressed += (_, e) =>
        {
            if (!_model.SingleSpectroscopy.IsExpanded) return;
            _isResizingDrawer = true;
            _resizeStartScreen = e.GetPosition(this);
            _resizeStartHeight = _model.SingleSpectroscopy.Height;
            e.Pointer.Capture(_drawerDragHandle);
            e.Handled = true;
        };
        _drawerDragHandle.PointerMoved += (_, e) =>
        {
            if (!_isResizingDrawer) return;
            Point pt = e.GetPosition(this);
            double dy = pt.Y - _resizeStartScreen.Y;
            double nextH = SingleSpectroscopyState.ResizedHeight(_resizeStartHeight, dy);
            _model.SetSingleSpectroscopyHeight(nextH);
            e.Handled = true;
        };
        _drawerDragHandle.PointerReleased += (_, e) =>
        {
            if (_isResizingDrawer)
            {
                _isResizingDrawer = false;
                if (Equals(e.Pointer.Captured, _drawerDragHandle)) e.Pointer.Capture(null);
                e.Handled = true;
            }
        };

        _drawerToggleBtn = new Button
        {
            Content = "\u25BE Spectroscopy",
            Padding = new Thickness(6, 2),
            Background = Brushes.Transparent,
            FontWeight = FontWeight.SemiBold,
            FontSize = 12
        };
        _drawerToggleBtn.Click += (_, _) => _model.SetSingleSpectroscopyExpanded(!_model.SingleSpectroscopy.IsExpanded);

        _groupTabsPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        _drawerCountText = new TextBlock { FontSize = 11.5, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center };

        _xColumnBox = new ComboBox { MinWidth = 130 };
        _yColumnBox = new ComboBox { MinWidth = 130 };
        _columnSummaryText = new TextBlock
        {
            FontSize = 11,
            Opacity = 0.65,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis
        };

        _xColumnBox.SelectionChanged += async (_, _) =>
        {
            if (_guard || _xColumnBox.SelectedItem is not string col) return;
            if (_model.SingleDrawerPresentation.ActiveGroup is { } active)
            {
                await _model.SetSpectrumXColumnAsync(active.Group, col);
            }
        };
        _yColumnBox.SelectionChanged += async (_, _) =>
        {
            if (_guard || _yColumnBox.SelectedItem is not string col) return;
            if (_model.SingleDrawerPresentation.ActiveGroup is { } active)
            {
                await _model.SetSpectrumYColumnAsync(active.Group, col);
            }
        };

        _plotControl = new SpectroscopyPlotControl
        {
            IsCompact = false,
            OnSpectrumClicked = id => _model.FocusSpectrumInDrawer(id)
        };
        _legendHost = new StackPanel { Spacing = 3 };

        _drawerContentGrid = new Grid
        {
            RowDefinitions = new RowDefinitions("Auto,*"),
            ColumnDefinitions = new ColumnDefinitions("*,220"),
            Margin = new Thickness(10, 4, 10, 8)
        };

        var axesBar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Margin = new Thickness(0, 0, 0, 6),
            Children =
            {
                new TextBlock { Text = "X:", VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5 },
                _xColumnBox,
                new TextBlock { Text = "Y:", VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5, Margin = new Thickness(6, 0, 0, 0) },
                _yColumnBox,
                _columnSummaryText
            }
        };
        Grid.SetRow(axesBar, 0);
        Grid.SetColumnSpan(axesBar, 2);
        Grid.SetRow(_plotControl, 1);
        Grid.SetColumn(_plotControl, 0);

        var legendScroll = new ScrollViewer
        {
            Margin = new Thickness(8, 0, 0, 0),
            Content = _legendHost
        };
        Grid.SetRow(legendScroll, 1);
        Grid.SetColumn(legendScroll, 1);

        _drawerContentGrid.Children.AddRange([axesBar, _plotControl, legendScroll]);

        var drawerHeaderDock = new DockPanel { Margin = new Thickness(10, 0, 10, 4) };
        DockPanel.SetDock(_drawerToggleBtn, Dock.Left);
        DockPanel.SetDock(_drawerCountText, Dock.Right);
        drawerHeaderDock.Children.Add(_drawerToggleBtn);
        drawerHeaderDock.Children.Add(_drawerCountText);
        drawerHeaderDock.Children.Add(_groupTabsPanel);

        _drawerBorder = new Border
        {
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = new DockPanel
            {
                Children =
                {
                    SetTopDock(_drawerDragHandle),
                    SetTopDock(drawerHeaderDock),
                    _drawerContentGrid
                }
            }
        };
        Grid.SetRow(_drawerBorder, 2);

        Children.AddRange([navBar, canvasHost, _drawerBorder]);

        ActualThemeVariantChanged += (_, _) => ApplyTheme(navBar);
        ApplyTheme(navBar);
        SyncFromModel();
    }

    private static Control SetTopDock(Control c)
    {
        DockPanel.SetDock(c, Dock.Top);
        return c;
    }

    private void ApplyTheme(Border? navBar)
    {
        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        if (navBar is not null)
        {
            navBar.Background = theme.ToolbarSurfaceBrush;
            navBar.BorderBrush = theme.HairlineBorderBrush;
        }
        _statusOverlay.Background = theme.PlotBadgeBackgroundBrush;
        _statusOverlay.BorderBrush = theme.HairlineBorderBrush;
        _drawerBorder.Background = theme.SidebarSurfaceBrush;
        _drawerBorder.BorderBrush = theme.HairlineBorderBrush;
    }

    public void SyncFromModel()
    {
        _guard = true;
        try
        {
            AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
            SXMMetadata? file = _model.SelectedFile;
            IReadOnlyList<SXMMetadata> visible = _model.VisibleFiles;
            int idx = file is null ? -1 : visible.ToList().FindIndex(f => f.Id == file.Id);

            _prevBtn.IsEnabled = _model.CanStepSelection(-1);
            _nextBtn.IsEnabled = _model.CanStepSelection(1);
            _indexText.Text = idx >= 0 ? $"{idx + 1} of {visible.Count}" : "0 of 0";
            _titleText.Text = file?.Filename ?? "No Selection";

            if (file is not null)
            {
                string footprint = file.ScanRange is { } sr
                    ? ScientificFormatters.FormatScanFootprint(InspectorCoordinatePair.TryCreate(sr.X, sr.Y))
                    : "";
                _subtitleText.Text = string.IsNullOrEmpty(footprint)
                    ? $"{file.Pixels.Width}\u00D7{file.Pixels.Height}"
                    : $"{footprint} \u00B7 {file.Pixels.Width}\u00D7{file.Pixels.Height}";
            }
            else
            {
                _subtitleText.Text = string.Empty;
            }

            SyncCanvasOnly();
            SyncDrawer(theme);
        }
        finally
        {
            _guard = false;
        }
    }

    public void SyncCanvasOnly()
    {
        SingleSpectroscopyDrawerPresentation drawer = _model.SingleDrawerPresentation;
        var markers = new List<(SpectroscopyFile Spectrum, int IndexInGroup)>();
        foreach (PresentedSpectroscopyGroup pg in drawer.Groups)
        {
            var idxById = new Dictionary<Guid, int>(pg.AllSpectra.Count);
            for (int i = 0; i < pg.AllSpectra.Count; i++) idxById[pg.AllSpectra[i].Id] = i;
            foreach (SpectroscopyFile s in pg.VisibleSpectra)
            {
                markers.Add((s, idxById.TryGetValue(s.Id, out int idx) ? idx : 0));
            }
        }

        WriteableBitmap? bmp = _model.RenderedFrame?.Image;
        _canvas.UpdateScene(
            bmp,
            _model.SelectedFile,
            _model.ViewerTransform,
            markers,
            _model.SingleSpectroscopy.FocusedSpectrumId);

        BrowserContentState<Guid> state = _model.ContentState;
        if (state is BrowserContentState<Guid>.RenderFailed rf)
        {
            _statusOverlay.IsVisible = true;
            _statusOverlayText.Text = $"Could not render: {rf.Message}";
            _retryRenderBtn.IsVisible = true;
        }
        else if (state is BrowserContentState<Guid>.RenderLoading && bmp is null)
        {
            _statusOverlay.IsVisible = true;
            _statusOverlayText.Text = $"Rendering {_model.SelectedFile?.Filename ?? "scan"}\u2026";
            _retryRenderBtn.IsVisible = false;
        }
        else
        {
            _statusOverlay.IsVisible = false;
            _retryRenderBtn.IsVisible = false;
        }
    }

    private void SyncDrawer(AppThemePalette theme)
    {
        SingleSpectroscopyDrawerPresentation presentation = _model.SingleDrawerPresentation;
        bool hasGroups = presentation.Groups.Count > 0;
        _drawerBorder.IsVisible = hasGroups;
        if (!hasGroups)
        {
            _drawerRow.Height = new GridLength(0);
            return;
        }

        bool expanded = _model.SingleSpectroscopy.IsExpanded;
        _drawerToggleBtn.Content = expanded ? "\u25BE Spectroscopy" : "\u25B8 Spectroscopy";
        _drawerContentGrid.IsVisible = expanded;
        _drawerRow.Height = expanded
            ? new GridLength(_model.SingleSpectroscopy.Height)
            : GridLength.Auto;

        _drawerCountText.Text = presentation.VisibleCountText;

        _groupTabsPanel.Children.Clear();
        if (presentation.Groups.Count > 1)
        {
            foreach (PresentedSpectroscopyGroup pg in presentation.Groups)
            {
                bool active = presentation.ActiveGroup?.Id == pg.Id;
                var tabBtn = new Button
                {
                    Content = $"{pg.Group.Title} ({pg.VisibleSpectra.Count})",
                    Padding = new Thickness(8, 2),
                    FontSize = 11.5,
                    Background = active ? theme.AccentSubtleBrush : Brushes.Transparent
                };
                tabBtn.Click += (_, _) => _model.SelectSingleSpectroscopyGroup(pg.Id);
                _groupTabsPanel.Children.Add(tabBtn);
            }
        }
        else if (presentation.ActiveGroup is { } singleGroup)
        {
            _groupTabsPanel.Children.Add(new TextBlock
            {
                Text = singleGroup.Group.Title,
                FontSize = 11.5,
                Opacity = 0.8,
                VerticalAlignment = VerticalAlignment.Center
            });
        }

        if (presentation.ActiveGroup is not { } activeGroup) return;

        IReadOnlyList<string> cols = activeGroup.Group.AvailableColumns;
        _xColumnBox.ItemsSource = cols;
        _yColumnBox.ItemsSource = cols;
        AxisSelection? axisSel = _model.SpectroscopyAxes.EnsureSelection(
            activeGroup.Id,
            cols,
            activeGroup.Group.XLabel,
            activeGroup.Group.YLabel);

        _xColumnBox.SelectedItem = axisSel?.XColumn;
        _yColumnBox.SelectedItem = axisSel?.YColumn;
        _columnSummaryText.Text = "";

        _plotControl.UpdatePlot(activeGroup, axisSel, _model.SingleSpectroscopy.FocusedSpectrumId);

        _legendHost.Children.Clear();
        for (int i = 0; i < activeGroup.AllSpectra.Count; i++)
        {
            SpectroscopyFile spec = activeGroup.AllSpectra[i];
            bool visible = activeGroup.VisibleSpectra.Any(v => v.Id == spec.Id);
            bool focused = _model.SingleSpectroscopy.FocusedSpectrumId == spec.Id;
            SpectrumVisualStyle style = SpectrumVisualStyle.ForIndex(i);
            Color curveColor = theme.CurveColor(style);

            var check = new CheckBox
            {
                IsChecked = visible,
                Padding = new Thickness(0),
                VerticalAlignment = VerticalAlignment.Center
            };
            check.IsCheckedChanged += async (_, _) =>
            {
                if (_guard) return;
                await _model.ToggleSpectrumVisibilityAsync(spec.Id, check.IsChecked ?? true);
            };

            var swatch = new Border
            {
                Width = 14,
                Height = 4,
                CornerRadius = new CornerRadius(2),
                VerticalAlignment = VerticalAlignment.Center,
                Background = new SolidColorBrush(curveColor)
            };

            var nameText = new TextBlock
            {
                Text = spec.Filename,
                FontSize = 11.5,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Opacity = visible ? 1.0 : 0.45
            };

            var rowPanel = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { check, swatch, nameText }
            };
            var rowCard = new Border
            {
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(5, 3),
                Background = focused ? theme.SelectedTileBrush : Brushes.Transparent,
                Child = rowPanel
            };
            rowCard.PointerPressed += (_, e) =>
            {
                if (visible) _model.FocusSpectrumInDrawer(spec.Id);
                e.Handled = true;
            };
            _legendHost.Children.Add(rowCard);
        }
    }
}
