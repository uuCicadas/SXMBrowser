using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Controllers;
using SXMBrowser.Desktop.Controls;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Views;

public sealed class GridBrowserView : Grid
{
    private sealed class SxmTileEntry
    {
        public required SXMMetadata File { get; init; }
        public required Border CardBorder { get; init; }
        public required Image PreviewImage { get; init; }
        public CancellationTokenSource? LoadCts { get; set; }
    }

    private readonly AppModel _model;
    private readonly ScrollViewer _scrollViewer;
    private readonly UniformGrid _cardsGrid;
    private readonly Border _emptyOverlay;
    private readonly StackPanel _emptyStack;
    private readonly Border _selectionActionBar;
    private readonly TextBlock _selectionCountText;
    private readonly Button _actionAssignTagBtn;
    private readonly Button _actionDeleteBtn;

    private readonly Dictionary<Guid, SxmTileEntry> _sxmTiles = new();
    private readonly Dictionary<string, Border> _spectroscopyCards = new(StringComparer.Ordinal);
    private string _renderedStructureSignature = string.Empty;
    private int _currentColumnCount = 1;

    public int CurrentColumnCount => Math.Max(1, _currentColumnCount);

    public Action? OnOpenFolderRequested { get; set; }
    public Action<IReadOnlyList<SXMMetadata>>? OnDeleteRequested { get; set; }
    public Action<SXMMetadata>? OnExportPngRequested { get; set; }
    public Action<string, IReadOnlyList<Guid>>? OnCreateTagWithFilesRequested { get; set; }

    public GridBrowserView(AppModel model)
    {
        _model = model;

        _cardsGrid = new UniformGrid
        {
            Columns = 3,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(11, 11, 11, 72)
        };

        _scrollViewer = new ScrollViewer
        {
            Content = _cardsGrid,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
        };

        _emptyStack = new StackPanel
        {
            Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 420
        };
        _emptyOverlay = new Border
        {
            IsVisible = false,
            Child = _emptyStack
        };

        _selectionCountText = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = FontWeight.SemiBold,
            FontSize = 12.5
        };
        _actionAssignTagBtn = new Button { Content = "Assign Tag", Padding = new Thickness(10, 4) };
        _actionDeleteBtn = new Button { Content = "Move to Recycle Bin", Padding = new Thickness(10, 4) };
        var actionClearBtn = new Button { Content = "Clear", Padding = new Thickness(8, 4) };

        _actionAssignTagBtn.Click += (_, _) => OpenBulkTagFlyout(_actionAssignTagBtn);
        _actionDeleteBtn.Click += (_, _) =>
        {
            IReadOnlyList<SXMMetadata> targets = _model.SelectedFiles;
            if (targets.Count > 0) OnDeleteRequested?.Invoke(targets);
        };
        actionClearBtn.Click += (_, _) => _model.ClearSelection();

        _selectionActionBar = new Border
        {
            IsVisible = false,
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14, 8),
            Margin = new Thickness(16),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10,
                Children = { _selectionCountText, _actionAssignTagBtn, _actionDeleteBtn, actionClearBtn }
            }
        };

        Children.Add(_scrollViewer);
        Children.Add(_emptyOverlay);
        Children.Add(_selectionActionBar);

        ActualThemeVariantChanged += (_, _) => ApplyTheme();
        ApplyTheme();
        SyncFromModel();
    }

    protected override void OnSizeChanged(SizeChangedEventArgs e)
    {
        base.OnSizeChanged(e);
        UpdateLayoutMetrics();
    }

    private void UpdateLayoutMetrics()
    {
        double width = Bounds.Width > 1.0 ? Bounds.Width : 800.0;
        var metrics = new AdaptiveGridMetrics(width, _model.GridDensity);
        if (_currentColumnCount != metrics.ColumnCount)
        {
            _currentColumnCount = metrics.ColumnCount;
            _cardsGrid.Columns = _currentColumnCount;
        }
    }

    public void ApplyTheme()
    {
        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        Background = theme.GridStageBrush;
        _selectionActionBar.Background = theme.ElevatedCardBrush;
        _selectionActionBar.BorderBrush = theme.HairlineBorderBrush;
        RefreshTileSelectionVisuals(theme);
    }

    public void RefreshThumbnails()
    {
        foreach (SxmTileEntry entry in _sxmTiles.Values)
        {
            LoadThumbnailAsync(entry);
        }
    }

    public void SyncFromModel()
    {
        UpdateLayoutMetrics();
        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        BrowserContentState<Guid> state = _model.ContentState;

        bool showGrid = state is BrowserContentState<Guid>.GridReady
            or BrowserContentState<Guid>.NoSelection
            or BrowserContentState<Guid>.RenderLoading
            or BrowserContentState<Guid>.RenderReady
            or BrowserContentState<Guid>.RenderFailed;

        _scrollViewer.IsVisible = showGrid;
        _emptyOverlay.IsVisible = !showGrid;

        if (!showGrid)
        {
            RebuildEmptyState(state, theme);
            _selectionActionBar.IsVisible = false;
            return;
        }

        string signature = BuildStructureSignature();
        if (!string.Equals(_renderedStructureSignature, signature, StringComparison.Ordinal))
        {
            RebuildCards(theme);
            _renderedStructureSignature = signature;
        }
        else
        {
            RefreshTileSelectionVisuals(theme);
        }

        SelectionActionPresentation<Guid> bar = _model.SelectionActionBar;
        _selectionActionBar.IsVisible = bar.Placement == SelectionActionPlacement.ActionBar;
        if (_selectionActionBar.IsVisible)
        {
            _selectionCountText.Text = $"{bar.OrderedIds.Count} selected";
        }
    }

    private string BuildStructureSignature()
    {
        var itemIds = string.Join('|', _model.GridItems.Select(i => i.ItemId));
        var tagStates = string.Join(';', _model.Tags.Select(t => $"{t.Id:N}:{t.SxmPaths.Count}"));
        return $"{_model.GridItems.Count}:{_model.StmPreviewPalette}:{_model.GridDensity}:{_model.ThemeMode}:{itemIds}:{tagStates}";
    }

    private void CancelAllThumbnailLoads()
    {
        foreach (SxmTileEntry entry in _sxmTiles.Values)
        {
            entry.LoadCts?.Cancel();
            entry.LoadCts?.Dispose();
            entry.LoadCts = null;
        }
    }

    private void RebuildCards(AppThemePalette theme)
    {
        CancelAllThumbnailLoads();
        _sxmTiles.Clear();
        _spectroscopyCards.Clear();
        _cardsGrid.Children.Clear();
        _cardsGrid.Columns = CurrentColumnCount;

        foreach (GridBrowserItem item in _model.GridItems)
        {
            switch (item)
            {
                case GridBrowserItem.Sxm sxmItem:
                    _cardsGrid.Children.Add(BuildSxmTile(sxmItem.File, theme));
                    break;
                case GridBrowserItem.Spectroscopy specItem:
                    _cardsGrid.Children.Add(BuildSpectroscopyCard(specItem.Presentation, theme));
                    break;
            }
        }
    }

    private Control BuildSxmTile(SXMMetadata file, AppThemePalette theme)
    {
        bool isSelected = _model.SelectedIds.Contains(file.Id);
        var backdrop = new MissingDataBackdropControl { TileSize = 6.0 };
        var img = new Image { Stretch = Stretch.Uniform };
        Avalonia.Media.RenderOptions.SetBitmapInterpolationMode(img, BitmapInterpolationMode.HighQuality);

        if (_model.TryGetCachedThumbnail(file, out WriteableBitmap? cached) && cached is not null)
        {
            img.Source = cached;
        }

        var well = new Border
        {
            CornerRadius = new CornerRadius(6),
            ClipToBounds = true,
            Background = theme.ImageWellBrush,
            Height = 148,
            Child = new Grid
            {
                Children = { backdrop, img }
            }
        };

        string chName = file.DefaultChannel ?? "—";
        string footprint = file.ScanRange is { } sr
            ? ScientificFormatters.FormatScanFootprint(InspectorCoordinatePair.TryCreate(sr.X, sr.Y))
            : $"{file.Pixels.Width}\u00D7{file.Pixels.Height}";

        SpectroscopyPresentationProjection specProj = _model.SpectroscopyProjectionForFile(file.Id);
        int specCount = specProj.MarkerSpectra.Count;

        var metaRow = new DockPanel { LastChildFill = true };
        if (specCount > 0)
        {
            var specBadge = new Border
            {
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(5, 1),
                Background = theme.AccentSubtleBrush,
                Margin = new Thickness(4, 0, 0, 0),
                Child = new TextBlock
                {
                    Text = $"{specCount} dat",
                    FontSize = 10,
                    Foreground = theme.AccentBrush
                }
            };
            DockPanel.SetDock(specBadge, Dock.Right);
            metaRow.Children.Add(specBadge);
        }
        metaRow.Children.Add(new TextBlock
        {
            Text = $"{chName} \u00B7 {footprint}",
            FontSize = 11,
            Foreground = theme.TextSecondaryBrush,
            TextTrimming = TextTrimming.CharacterEllipsis
        });

        var stack = new StackPanel
        {
            Spacing = 6,
            Children =
            {
                well,
                new TextBlock
                {
                    Text = file.Filename,
                    FontWeight = FontWeight.SemiBold,
                    FontSize = 12,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    Foreground = theme.TextPrimaryBrush
                },
                metaRow
            }
        };

        IReadOnlyList<DatasetTagV1> fileTags = _model.TagsForFile(file.Id);
        if (fileTags.Count > 0)
        {
            var tagWrap = new WrapPanel { Orientation = Orientation.Horizontal };
            foreach (DatasetTagV1 t in fileTags.Take(3))
            {
                tagWrap.Children.Add(new Border
                {
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(5, 1),
                    Margin = new Thickness(0, 0, 4, 2),
                    Background = theme.AccentSubtleBrush,
                    Child = new TextBlock
                    {
                        Text = t.Name,
                        FontSize = 10,
                        Foreground = theme.TextPrimaryBrush
                    }
                });
            }
            stack.Children.Add(tagWrap);
        }

        var cardBorder = new Border
        {
            Margin = new Thickness(7),
            Padding = new Thickness(8),
            CornerRadius = new CornerRadius(9),
            BorderThickness = new Thickness(isSelected ? 1.5 : 1.0),
            Background = isSelected ? theme.SelectedTileBrush : theme.CardSurfaceBrush,
            BorderBrush = isSelected ? theme.AccentBrush : theme.TileBorderBrush,
            Child = stack
        };

        var entry = new SxmTileEntry
        {
            File = file,
            CardBorder = cardBorder,
            PreviewImage = img
        };
        _sxmTiles[file.Id] = entry;

        if (img.Source is null)
        {
            LoadThumbnailAsync(entry);
        }

        cardBorder.PointerPressed += (_, e) =>
        {
            if (e.ClickCount >= 2 && e.GetCurrentPoint(cardBorder).Properties.IsLeftButtonPressed)
            {
                _model.OpenSingleView(file.Id);
                e.Handled = true;
                return;
            }

            bool isRight = e.GetCurrentPoint(cardBorder).Properties.IsRightButtonPressed;
            if (isRight)
            {
                if (!_model.SelectedIds.Contains(file.Id))
                {
                    _model.SelectOnly(file.Id);
                }
                return;
            }

            KeyModifiers mods = e.KeyModifiers;
            if ((mods & KeyModifiers.Shift) != 0)
            {
                _model.SelectRange(file.Id);
            }
            else if ((mods & KeyModifiers.Control) != 0 || (mods & KeyModifiers.Meta) != 0)
            {
                _model.ToggleSelection(file.Id);
            }
            else
            {
                _model.SelectOnly(file.Id);
            }
            e.Handled = true;
        };

        cardBorder.ContextMenu = BuildTileContextMenu(file);
        return cardBorder;
    }

    private Control BuildSpectroscopyCard(PresentedSpectroscopyGroup presentation, AppThemePalette theme)
    {
        var plot = new SpectroscopyPlotControl
        {
            IsCompact = true,
            Height = 148
        };
        AxisSelection? selection = _model.SpectroscopyAxes.SelectionForGroupId(presentation.Id)
            ?? new AxisSelection(presentation.Group.XLabel, presentation.Group.YLabel);
        plot.UpdatePlot(presentation, selection, focusedSpectrumId: null);

        var plotWell = new Border
        {
            CornerRadius = new CornerRadius(6),
            ClipToBounds = true,
            Background = theme.PlotCanvasBackgroundBrush,
            Height = 148,
            Child = plot
        };

        var cardBorder = new Border
        {
            Margin = new Thickness(7),
            Padding = new Thickness(8),
            CornerRadius = new CornerRadius(9),
            BorderThickness = new Thickness(1),
            Background = theme.CardSurfaceBrush,
            BorderBrush = theme.TileBorderBrush,
            Child = new StackPanel
            {
                Spacing = 6,
                Children =
                {
                    plotWell,
                    new TextBlock
                    {
                        Text = presentation.Group.Title,
                        FontWeight = FontWeight.SemiBold,
                        FontSize = 12,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        Foreground = theme.TextPrimaryBrush
                    },
                    new TextBlock
                    {
                        Text = $"{presentation.Group.SxmFilename} \u00B7 {presentation.VisibleCurveCountText}",
                        FontSize = 11,
                        Foreground = theme.TextSecondaryBrush,
                        TextTrimming = TextTrimming.CharacterEllipsis
                    }
                }
            }
        };

        cardBorder.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(cardBorder).Properties.IsLeftButtonPressed)
            {
                _model.OpenSingleView(presentation.Group.SxmId, presentation.Id);
                e.Handled = true;
            }
        };

        _spectroscopyCards[presentation.Id] = cardBorder;
        return cardBorder;
    }

    private ContextMenu BuildTileContextMenu(SXMMetadata file)
    {
        var menu = new ContextMenu();
        var openItem = new MenuItem { Header = "Open in Single View" };
        openItem.Click += (_, _) => _model.OpenSingleView(file.Id);
        menu.Items.Add(openItem);

        var tagRoot = new MenuItem { Header = "Tags" };
        menu.Opened += (_, _) =>
        {
            tagRoot.Items.Clear();
            IReadOnlyList<Guid> targetIds = _model.SelectedIds.Contains(file.Id) && _model.SelectedIds.Count > 0
                ? _model.SelectedIds.ToArray()
                : [file.Id];

            foreach (DatasetTagV1 tag in _model.Tags)
            {
                bool allTagged = targetIds.All(id => _model.IsFileTagged(id, tag.Id));
                var tItem = new MenuItem
                {
                    Header = (allTagged ? "\u2713 " : "   ") + tag.Name
                };
                tItem.Click += async (_, _) => await _model.AssignFilesToTagAsync(targetIds, tag.Id, !allTagged);
                tagRoot.Items.Add(tItem);
            }
            if (_model.Tags.Count > 0)
            {
                tagRoot.Items.Add(new Separator());
            }
            var newTagItem = new MenuItem { Header = "New Tag from Selection\u2026" };
            newTagItem.Click += (_, _) => OnCreateTagWithFilesRequested?.Invoke(
                file.Filename,
                targetIds);
            tagRoot.Items.Add(newTagItem);
        };
        menu.Items.Add(tagRoot);

        var exportItem = new MenuItem { Header = "Export PNG\u2026" };
        exportItem.Click += (_, _) => OnExportPngRequested?.Invoke(file);
        menu.Items.Add(exportItem);

        var revealItem = new MenuItem { Header = "Show in Explorer" };
        revealItem.Click += (_, _) => _model.RevealSelectedInExplorer();
        menu.Items.Add(revealItem);

        menu.Items.Add(new Separator());

        var deleteItem = new MenuItem { Header = "Move to Recycle Bin" };
        deleteItem.Click += (_, _) =>
        {
            IReadOnlyList<SXMMetadata> targets = _model.SelectedFiles;
            if (targets.Count == 0) targets = [file];
            OnDeleteRequested?.Invoke(targets);
        };
        menu.Items.Add(deleteItem);

        return menu;
    }

    private void OpenBulkTagFlyout(Button anchor)
    {
        var menu = new ContextMenu();
        IReadOnlyList<Guid> targetIds = _model.SelectedIds.ToArray();
        foreach (DatasetTagV1 tag in _model.Tags)
        {
            bool allTagged = targetIds.All(id => _model.IsFileTagged(id, tag.Id));
            var item = new MenuItem { Header = (allTagged ? "\u2713 " : "   ") + tag.Name };
            item.Click += async (_, _) => await _model.AssignFilesToTagAsync(targetIds, tag.Id, !allTagged);
            menu.Items.Add(item);
        }
        if (_model.Tags.Count > 0) menu.Items.Add(new Separator());
        var createItem = new MenuItem { Header = "New Tag with Selection\u2026" };
        createItem.Click += (_, _) => OnCreateTagWithFilesRequested?.Invoke("Selection", targetIds);
        menu.Items.Add(createItem);
        menu.Open(anchor);
    }

    private void RefreshTileSelectionVisuals(AppThemePalette theme)
    {
        foreach ((Guid id, SxmTileEntry entry) in _sxmTiles)
        {
            bool selected = _model.SelectedIds.Contains(id);
            entry.CardBorder.Background = selected ? theme.SelectedTileBrush : theme.CardSurfaceBrush;
            entry.CardBorder.BorderBrush = selected ? theme.AccentBrush : theme.TileBorderBrush;
            entry.CardBorder.BorderThickness = new Thickness(selected ? 1.5 : 1.0);
        }
        foreach (Border card in _spectroscopyCards.Values)
        {
            card.Background = theme.CardSurfaceBrush;
            card.BorderBrush = theme.TileBorderBrush;
        }
    }

    private void LoadThumbnailAsync(SxmTileEntry entry)
    {
        entry.LoadCts?.Cancel();
        entry.LoadCts?.Dispose();
        var cts = new CancellationTokenSource();
        entry.LoadCts = cts;
        CancellationToken ct = cts.Token;

        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            WriteableBitmap? bmp = await _model.ThumbnailForAsync(entry.File, ct).ConfigureAwait(false);
            if (ct.IsCancellationRequested || bmp is null) return;
            Dispatcher.UIThread.Post(() =>
            {
                if (!ct.IsCancellationRequested && _sxmTiles.TryGetValue(entry.File.Id, out SxmTileEntry? cur)
                    && ReferenceEquals(cur, entry))
                {
                    entry.PreviewImage.Source = bmp;
                }
            });
        }, ct);
    }

    private void RebuildEmptyState(BrowserContentState<Guid> state, AppThemePalette theme)
    {
        _emptyStack.Children.Clear();
        (string title, string detail, string? btnLabel, Action? btnAction) = state switch
        {
            BrowserContentState<Guid>.OpenFolder => (
                "SXM Browser",
                "Open an experiment folder or drop a folder here to browse Nanonis .sxm scans and .dat spectroscopy.",
                "Open Folder\u2026",
                OnOpenFolderRequested),
            BrowserContentState<Guid>.LoadingFolder => (
                $"Scanning {_model.FolderName}\u2026",
                "Reading .sxm headers and .dat spectroscopy metadata.",
                null,
                null),
            BrowserContentState<Guid>.FolderFailed ff => (
                "Could not open folder",
                ff.Message,
                "Retry",
                () => { _ = _model.RescanAsync(); }),
            BrowserContentState<Guid>.EmptyFolder => (
                "No .sxm scans found",
                "The selected folder does not contain readable Nanonis .sxm files.",
                "Open Another Folder\u2026",
                OnOpenFolderRequested),
            BrowserContentState<Guid>.NoSearchResults => (
                "No matching scans",
                $"No scans or spectra match \u201C{_model.SearchQuery}\u201D.",
                "Clear Filter",
                () => { _model.SearchQuery = string.Empty; }),
            BrowserContentState<Guid>.NoVisibleFiles => (
                "No files in active tag",
                "This tag has no assigned scan files matching the current filter.",
                "Show All Scans",
                () => { _model.SetScope(BrowserScope.All.Instance); }),
            _ => ("No data", "", null, null)
        };

        _emptyStack.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 18,
            FontWeight = FontWeight.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            Foreground = theme.TextPrimaryBrush
        });
        if (!string.IsNullOrEmpty(detail))
        {
            _emptyStack.Children.Add(new TextBlock
            {
                Text = detail,
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                Foreground = theme.TextSecondaryBrush
            });
        }
        if (btnLabel is not null && btnAction is not null)
        {
            var btn = new Button
            {
                Content = btnLabel,
                HorizontalAlignment = HorizontalAlignment.Center,
                Padding = new Thickness(14, 7)
            };
            btn.Click += (_, _) => btnAction();
            _emptyStack.Children.Add(btn);
        }
    }
}
