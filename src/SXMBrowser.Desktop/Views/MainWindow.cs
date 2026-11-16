using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Styling;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Controllers;
using SXMBrowser.Desktop.Services;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Views;

public sealed class MainWindow : Window
{
    private readonly AppModel _model;
    private readonly BrowserToolbar _toolbar;
    private readonly SidebarView _sidebar;
    private readonly GridBrowserView _gridView;
    private readonly SingleImageView _singleView;
    private readonly InspectorView _inspector;

    private readonly Grid _workspaceGrid;
    private readonly GridSplitter _leftSplitter;
    private readonly GridSplitter _rightSplitter;

    private readonly Border _bannerBar;
    private readonly TextBlock _bannerText;
    private readonly StackPanel _bannerActionsPanel;

    private readonly Border _warningBar;
    private readonly TextBlock _warningText;

    private readonly Border _toastCard;
    private readonly TextBlock _toastTitle;
    private readonly TextBlock _toastMessage;

    private readonly Border _dropOverlay;
    private readonly Border _statusFooter;
    private readonly TextBlock _footerStatusText;

    private bool _isUpdatingSplitLayout;

    public AppModel Model => _model;

    public MainWindow()
        : this(new AppModel())
    {
    }

    public MainWindow(AppModel model)
    {
        _model = model;
        Title = "SXM Browser";
        Width = 1360;
        Height = 860;
        MinWidth = 680;
        MinHeight = 480;

        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragOverEvent, OnDragOver);
        AddHandler(DragDrop.DragLeaveEvent, OnDragLeave);
        AddHandler(DragDrop.DropEvent, OnDrop);

        Menu topMenu = BuildTopMenu();
        _toolbar = new BrowserToolbar(_model)
        {
            OnOpenFolderRequested = async () => await OpenFolderPickerAsync()
        };

        // Banner bar
        _bannerText = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        _bannerActionsPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        _bannerBar = new Border
        {
            IsVisible = false,
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(12, 6),
            Child = BuildBannerDock()
        };

        // Metadata warning strip
        var warnDetailsBtn = new Button { Content = "Details\u2026", Padding = new Thickness(8, 2), FontSize = 11.5 };
        var warnDismissBtn = new Button { Content = "Dismiss", Padding = new Thickness(8, 2), FontSize = 11.5 };
        warnDetailsBtn.Click += async (_, _) => await Dialogs.ShowDetailsListAsync(this, "Metadata Restore Warnings", _model.MetadataWarnings.Messages);
        warnDismissBtn.Click += (_, _) => _model.DismissMetadataWarnings();

        _warningText = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var warnBtns = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children = { warnDetailsBtn, warnDismissBtn }
        };
        var warnDock = new DockPanel();
        DockPanel.SetDock(warnBtns, Dock.Right);
        warnDock.Children.Add(warnBtns);
        warnDock.Children.Add(_warningText);
        _warningBar = new Border
        {
            IsVisible = false,
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(12, 5),
            Child = warnDock
        };

        // Panes
        _sidebar = new SidebarView(_model)
        {
            PromptTextAsync = async (title, prompt, init) =>
                await Dialogs.ShowTextPromptAsync(this, title, prompt, init)
        };

        _gridView = new GridBrowserView(_model)
        {
            OnOpenFolderRequested = async () => await OpenFolderPickerAsync(),
            OnDeleteRequested = async targets => await ConfirmAndDeleteAsync(targets),
            OnExportPngRequested = async file => await ExportPngDialogAsync(file),
            OnCreateTagWithFilesRequested = async (hint, fileIds) =>
            {
                string? tagName = await Dialogs.ShowTextPromptAsync(this, "New Tag", $"Create tag for {hint}:", "");
                if (!string.IsNullOrWhiteSpace(tagName))
                {
                    try
                    {
                        await _model.CreateTagAsync(tagName, fileIds);
                    }
                    catch (Exception ex)
                    {
                        _model.PresentToast("Could not create tag", ex.Message, NoticeSeverity.Error);
                    }
                }
            }
        };

        _singleView = new SingleImageView(_model) { IsVisible = false };

        _inspector = new InspectorView(_model)
        {
            OnExportPngRequested = async file => await ExportPngDialogAsync(file),
            OnCreateTagWithFilesRequested = async (hint, fileIds) =>
            {
                string? tagName = await Dialogs.ShowTextPromptAsync(this, "New Tag", $"Create tag for {hint}:", "");
                if (!string.IsNullOrWhiteSpace(tagName))
                {
                    try
                    {
                        await _model.CreateTagAsync(tagName, fileIds);
                    }
                    catch (Exception ex)
                    {
                        _model.PresentToast("Could not create tag", ex.Message, NoticeSeverity.Error);
                    }
                }
            }
        };

        var centerHost = new Grid
        {
            Children = { _gridView, _singleView }
        };

        _leftSplitter = new GridSplitter { ResizeDirection = GridResizeDirection.Columns, Width = 4, Background = Brushes.Transparent };
        _rightSplitter = new GridSplitter { ResizeDirection = GridResizeDirection.Columns, Width = 4, Background = Brushes.Transparent };

        _leftSplitter.DragCompleted += (_, _) => PersistSplitterWidths();
        _rightSplitter.DragCompleted += (_, _) => PersistSplitterWidths();

        _workspaceGrid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("300,4,*,4,320")
        };
        Grid.SetColumn(_sidebar, 0);
        Grid.SetColumn(_leftSplitter, 1);
        Grid.SetColumn(centerHost, 2);
        Grid.SetColumn(_rightSplitter, 3);
        Grid.SetColumn(_inspector, 4);
        _workspaceGrid.Children.AddRange([_sidebar, _leftSplitter, centerHost, _rightSplitter, _inspector]);

        // Status footer
        _footerStatusText = new TextBlock { FontSize = 11, Opacity = 0.78 };
        _statusFooter = new Border
        {
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(12, 3),
            Child = _footerStatusText
        };

        // Toast overlay
        _toastTitle = new TextBlock { FontWeight = FontWeight.SemiBold, FontSize = 12 };
        _toastMessage = new TextBlock { FontSize = 11.5, Opacity = 0.85, TextWrapping = TextWrapping.Wrap };
        _toastCard = new Border
        {
            IsVisible = false,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14, 8),
            Margin = new Thickness(16, 16, 16, 36),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            MaxWidth = 360,
            Child = new StackPanel
            {
                Spacing = 2,
                Children = { _toastTitle, _toastMessage }
            }
        };

        // Drag-and-drop overlay
        _dropOverlay = new Border
        {
            IsVisible = false,
            BorderThickness = new Thickness(3),
            Margin = new Thickness(12),
            CornerRadius = new CornerRadius(12),
            IsHitTestVisible = false,
            Child = new TextBlock
            {
                Text = "Drop experiment folder to open in SXM Browser",
                FontSize = 18,
                FontWeight = FontWeight.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };

        var rootDock = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(topMenu, Dock.Top);
        DockPanel.SetDock(_toolbar, Dock.Top);
        DockPanel.SetDock(_bannerBar, Dock.Top);
        DockPanel.SetDock(_warningBar, Dock.Top);
        DockPanel.SetDock(_statusFooter, Dock.Bottom);
        rootDock.Children.AddRange([topMenu, _toolbar, _bannerBar, _warningBar, _statusFooter, _workspaceGrid]);

        Content = new Grid
        {
            Children = { rootDock, _toastCard, _dropOverlay }
        };

        _model.StateChanged += OnModelStateChanged;
        _model.RenderStateChanged += OnModelRenderStateChanged;
        _model.ThumbnailsInvalidated += () => _gridView.RefreshThumbnails();
        ActualThemeVariantChanged += (_, _) => ApplyWindowThemeColors();

        ApplyThemeMode();
        SyncAllViews();
    }

    private DockPanel BuildBannerDock()
    {
        var dock = new DockPanel();
        DockPanel.SetDock(_bannerActionsPanel, Dock.Right);
        dock.Children.Add(_bannerActionsPanel);
        dock.Children.Add(_bannerText);
        return dock;
    }

    private Menu BuildTopMenu()
    {
        MenuItem Item(string header, KeyGesture? gesture, Action action)
        {
            var mi = new MenuItem { Header = header, InputGesture = gesture };
            mi.Click += (_, _) => action();
            return mi;
        }

        // File menu
        var fileMenu = new MenuItem
        {
            Header = "_File",
            Items =
            {
                Item("_Open Folder\u2026", new KeyGesture(Key.O, KeyModifiers.Control), () => { _ = OpenFolderPickerAsync(); }),
                Item("_Rescan Folder", new KeyGesture(Key.R, KeyModifiers.Control | KeyModifiers.Shift), () => { _ = _model.RescanAsync(); }),
                new Separator(),
                Item("Export _PNG\u2026", new KeyGesture(Key.E, KeyModifiers.Control | KeyModifiers.Shift), () =>
                {
                    if (_model.SelectedFile is { } f) _ = ExportPngDialogAsync(f);
                }),
                new Separator(),
                Item("Export _Metadata\u2026", null, () => { _ = ExportMetadataDialogAsync(); }),
                Item("_Import Metadata\u2026", null, () => { _ = ImportMetadataDialogAsync(); }),
                new Separator(),
                Item("Show in _Explorer", null, () => _model.RevealSelectedInExplorer()),
                Item("Move to _Recycle Bin", new KeyGesture(Key.Delete), () => { _ = ConfirmAndDeleteAsync(_model.SelectedFiles); }),
                new Separator(),
                Item("E_xit", new KeyGesture(Key.Q, KeyModifiers.Control), () => Close())
            }
        };

        // Edit menu
        var editMenu = new MenuItem
        {
            Header = "_Edit",
            Items =
            {
                Item("Select _All", new KeyGesture(Key.A, KeyModifiers.Control), () => _model.SelectAll()),
                Item("_Clear Selection", null, () => _model.ClearSelection()),
                Item("_Find\u2026", new KeyGesture(Key.F, KeyModifiers.Control), () => _toolbar.FocusSearch()),
                new Separator(),
                Item("_New Tag\u2026", null, () => { _ = PromptCreateTagAsync(); })
            }
        };

        // View menu
        var densityMenu = new MenuItem
        {
            Header = "Grid _Density",
            Items =
            {
                Item("Compact", null, () => _model.GridDensity = GridDensity.Compact),
                Item("Comfortable", null, () => _model.GridDensity = GridDensity.Comfortable),
                Item("Large", null, () => _model.GridDensity = GridDensity.Large)
            }
        };

        var appearanceMenu = new MenuItem
        {
            Header = "_Appearance",
            Items =
            {
                Item("Follow System", null, () => _model.ThemeMode = ThemeAppearanceMode.System),
                Item("Light", null, () => _model.ThemeMode = ThemeAppearanceMode.Light),
                Item("Dark", null, () => _model.ThemeMode = ThemeAppearanceMode.Dark)
            }
        };

        var viewMenu = new MenuItem
        {
            Header = "_View",
            Items =
            {
                Item("_Grid View", new KeyGesture(Key.D1, KeyModifiers.Control), () => _model.ShowGridView()),
                Item("_Single View", new KeyGesture(Key.D2, KeyModifiers.Control), () => _model.OpenSingleView()),
                new Separator(),
                Item("Zoom to _Fit", new KeyGesture(Key.D0, KeyModifiers.Control), () => _model.FitViewer()),
                Item("_Actual Size (100%)", new KeyGesture(Key.D9, KeyModifiers.Control), () => _model.ShowActualSize()),
                Item("Zoom _In", new KeyGesture(Key.OemPlus, KeyModifiers.Control), () => _model.StepViewerZoom(true)),
                Item("Zoom _Out", new KeyGesture(Key.OemMinus, KeyModifiers.Control), () => _model.StepViewerZoom(false)),
                new Separator(),
                Item("Toggle _Sidebar", new KeyGesture(Key.S, KeyModifiers.Control | KeyModifiers.Alt), () => _model.SidebarVisible = !_model.SidebarVisible),
                Item("Toggle _Inspector", new KeyGesture(Key.I, KeyModifiers.Control | KeyModifiers.Alt), () => _model.InspectorVisible = !_model.InspectorVisible),
                Item("Toggle Spe_ctroscopy Cards", null, () => _model.ShowsGridSpectroscopyCards = !_model.ShowsGridSpectroscopyCards),
                densityMenu,
                appearanceMenu
            }
        };

        return new Menu
        {
            Items = { fileMenu, editMenu, viewMenu }
        };
    }

    protected override void OnSizeChanged(SizeChangedEventArgs e)
    {
        base.OnSizeChanged(e);
        UpdatePaneLayout();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Handled) return;

        bool interactiveFocus = TopLevel.GetTopLevel(this)?.FocusManager?.GetFocusedElement() is TextBox;
        bool hasCommand = (e.KeyModifiers & (KeyModifiers.Control | KeyModifiers.Meta | KeyModifiers.Alt)) != 0;
        bool isShift = (e.KeyModifiers & KeyModifiers.Shift) != 0;

        if (!interactiveFocus && !hasCommand && e.Key == Key.Delete)
        {
            if (_model.SelectedFiles.Count > 0)
            {
                _ = ConfirmAndDeleteAsync(_model.SelectedFiles);
                e.Handled = true;
            }
            return;
        }

        BrowserVirtualKey vkey = e.Key switch
        {
            Key.Left => BrowserVirtualKey.Left,
            Key.Right => BrowserVirtualKey.Right,
            Key.Up => BrowserVirtualKey.Up,
            Key.Down => BrowserVirtualKey.Down,
            Key.Enter => BrowserVirtualKey.Enter,
            Key.Escape => BrowserVirtualKey.Escape,
            _ => BrowserVirtualKey.Other
        };

        BrowserKeyboardCommand? cmd = BrowserKeyboardRouting.CommandForKey(
            vkey,
            hasCommandModifiers: hasCommand,
            isShiftPressed: isShift,
            interactiveControlHasFocus: interactiveFocus);

        if (cmd is null) return;

        switch (cmd)
        {
            case BrowserKeyboardCommand.Move m:
                if (_model.Mode == BrowserMode.Single)
                {
                    if (m.Direction == GridNavigationDirection.Left) _model.StepSelection(-1);
                    else if (m.Direction == GridNavigationDirection.Right) _model.StepSelection(1);
                }
                else
                {
                    _model.MoveGridSelection(m.Direction, _gridView.CurrentColumnCount, m.ExtendingSelection);
                }
                e.Handled = true;
                break;

            case BrowserKeyboardCommand.OpenSelection:
                if (_model.Mode == BrowserMode.Grid && _model.SelectedFile is not null)
                {
                    _model.OpenSingleView();
                    e.Handled = true;
                }
                break;

            case BrowserKeyboardCommand.ShowGrid:
                if (_model.Mode == BrowserMode.Single)
                {
                    _model.ShowGridView();
                    e.Handled = true;
                }
                else if (_model.SelectedIds.Count > 0)
                {
                    _model.ClearSelection();
                    e.Handled = true;
                }
                break;
        }
    }

    private void OnModelStateChanged()
    {
        ApplyThemeMode();
        SyncAllViews();
    }

    private void OnModelRenderStateChanged()
    {
        _toolbar.SyncFromModel();
        if (_model.Mode == BrowserMode.Single)
        {
            _singleView.SyncCanvasOnly();
        }
        _inspector.SyncScaleControlsOnly();
        _footerStatusText.Text = _model.Status;
    }

    private void SyncAllViews()
    {
        bool isSingle = _model.Mode == BrowserMode.Single;
        _gridView.IsVisible = !isSingle;
        _singleView.IsVisible = isSingle;

        _toolbar.SyncFromModel();
        _sidebar.SyncFromModel();
        if (isSingle)
        {
            _singleView.SyncFromModel();
        }
        else
        {
            _gridView.SyncFromModel();
        }
        _inspector.SyncFromModel();

        UpdatePaneLayout();
        SyncNoticesAndWarnings();
        _footerStatusText.Text = _model.Status;
        ApplyWindowThemeColors();
    }

    private void ApplyThemeMode()
    {
        ThemeVariant target = _model.ThemeMode switch
        {
            ThemeAppearanceMode.Light => ThemeVariant.Light,
            ThemeAppearanceMode.Dark => ThemeVariant.Dark,
            _ => ThemeVariant.Default
        };
        RequestedThemeVariant = target;
        if (Application.Current is not null && !Equals(Application.Current.RequestedThemeVariant, target))
        {
            Application.Current.RequestedThemeVariant = target;
        }
    }

    private void ApplyWindowThemeColors()
    {
        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        Background = theme.GridStageBrush;
        _statusFooter.Background = theme.ToolbarSurfaceBrush;
        _statusFooter.BorderBrush = theme.HairlineBorderBrush;
        _bannerBar.Background = theme.ElevatedCardBrush;
        _bannerBar.BorderBrush = theme.HairlineBorderBrush;
        _warningBar.Background = theme.ElevatedCardBrush;
        _warningBar.BorderBrush = theme.WarningBrush;
        _toastCard.Background = theme.ElevatedCardBrush;
        _toastCard.BorderBrush = theme.AccentBrush;
        _dropOverlay.Background = theme.AccentSubtleBrush;
        _dropOverlay.BorderBrush = theme.AccentBrush;
    }

    private void UpdatePaneLayout()
    {
        double w = Bounds.Width > 1.0 ? Bounds.Width : Width;
        var layout = new NativePaneLayout(
            containerWidth: w,
            wantsSidebar: _model.SidebarVisible,
            wantsInspector: _model.InspectorVisible,
            preferredSidebarWidth: _model.SidebarWidth,
            preferredInspectorWidth: _model.InspectorWidth,
            priority: NativePanePriority.Sidebar,
            dividerThickness: 4.0);

        _isUpdatingSplitLayout = true;
        try
        {
            _sidebar.IsVisible = layout.ShowsSidebar;
            _leftSplitter.IsVisible = layout.ShowsSidebar;
            _rightSplitter.IsVisible = layout.ShowsInspector;
            _inspector.IsVisible = layout.ShowsInspector;

            _workspaceGrid.ColumnDefinitions[0].Width = layout.ShowsSidebar ? new GridLength(layout.SidebarWidth) : new GridLength(0);
            _workspaceGrid.ColumnDefinitions[1].Width = layout.ShowsSidebar ? new GridLength(4) : new GridLength(0);
            _workspaceGrid.ColumnDefinitions[3].Width = layout.ShowsInspector ? new GridLength(4) : new GridLength(0);
            _workspaceGrid.ColumnDefinitions[4].Width = layout.ShowsInspector ? new GridLength(layout.InspectorWidth) : new GridLength(0);
        }
        finally
        {
            _isUpdatingSplitLayout = false;
        }
    }

    private void PersistSplitterWidths()
    {
        if (_isUpdatingSplitLayout) return;
        if (_sidebar.IsVisible)
        {
            double sw = _workspaceGrid.ColumnDefinitions[0].ActualWidth;
            if (sw >= NativePaneLayout.SidebarMinWidth) _model.SidebarWidth = sw;
        }
        if (_inspector.IsVisible)
        {
            double iw = _workspaceGrid.ColumnDefinitions[4].ActualWidth;
            if (iw >= NativePaneLayout.InspectorMinWidth) _model.InspectorWidth = iw;
        }
    }

    private void SyncNoticesAndWarnings()
    {
        if (_model.NoticeState.Banner is { } banner)
        {
            _bannerBar.IsVisible = true;
            _bannerText.Text = string.IsNullOrEmpty(banner.Message)
                ? banner.Title
                : $"{banner.Title} \u2014 {banner.Message}";

            _bannerActionsPanel.Children.Clear();
            foreach (NoticeAction action in banner.Actions)
            {
                string label = action switch
                {
                    NoticeAction.RetryFolder => "Retry",
                    NoticeAction.RetryRender => "Retry",
                    NoticeAction.ShowInFinder => "Show in Explorer",
                    NoticeAction.ShowScanIssues => "Details\u2026",
                    NoticeAction.ShowMetadataDetails => "Details\u2026",
                    _ => action.ToString()
                };
                var btn = new Button { Content = label, Padding = new Thickness(8, 2), FontSize = 11.5 };
                btn.Click += async (_, _) => await HandleNoticeActionAsync(action);
                _bannerActionsPanel.Children.Add(btn);
            }
            var dismissBtn = new Button { Content = "\u2715", Padding = new Thickness(6, 2), FontSize = 11.5 };
            dismissBtn.Click += (_, _) => _model.DismissBanner(banner.Id);
            _bannerActionsPanel.Children.Add(dismissBtn);
        }
        else
        {
            _bannerBar.IsVisible = false;
        }

        if (_model.MetadataWarnings.IsPresented)
        {
            _warningBar.IsVisible = true;
            int count = _model.MetadataWarnings.Count;
            _warningText.Text = $"{count} metadata compatibility note{(count == 1 ? "" : "s")} detected when opening dataset.";
        }
        else
        {
            _warningBar.IsVisible = false;
        }

        if (_model.NoticeState.Toast is { } toast)
        {
            _toastCard.IsVisible = true;
            _toastTitle.Text = toast.Title;
            _toastMessage.Text = toast.Message;
            _toastMessage.IsVisible = !string.IsNullOrEmpty(toast.Message);
        }
        else
        {
            _toastCard.IsVisible = false;
        }
    }

    private async Task HandleNoticeActionAsync(NoticeAction action)
    {
        switch (action)
        {
            case NoticeAction.RetryFolder:
                await _model.RescanAsync();
                break;
            case NoticeAction.RetryRender:
                _model.RefreshSelectedImage(resetScale: false);
                break;
            case NoticeAction.ShowInFinder:
                _model.RevealSelectedInExplorer();
                break;
            case NoticeAction.ShowScanIssues:
                string[] issueLines = _model.ScanIssues
                    .Select(i => $"{Path.GetFileName(i.FilePath)} [{i.Stage.ToRawValue()}]: {i.Reason}")
                    .ToArray();
                await Dialogs.ShowDetailsListAsync(this, "Scan Issues", issueLines);
                break;
            case NoticeAction.ShowMetadataDetails:
                await Dialogs.ShowDetailsListAsync(this, "Metadata Restore Warnings", _model.MetadataWarnings.Messages);
                break;
        }
    }

    // --- File Dialogs & Operations ---

    private async Task OpenFolderPickerAsync()
    {
        IReadOnlyList<IStorageFolder> picked = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
        {
            Title = "Open Experiment Folder",
            AllowMultiple = false
        });
        if (picked.Count == 0) return;
        string? path = picked[0].TryGetLocalPath();
        if (!string.IsNullOrEmpty(path))
        {
            await _model.OpenFolderAsync(path);
        }
    }

    private async Task PromptCreateTagAsync()
    {
        if (_model.ActiveSession is null) return;
        string? name = await Dialogs.ShowTextPromptAsync(this, "New Tag", "Enter tag name:", "");
        if (!string.IsNullOrWhiteSpace(name))
        {
            try
            {
                await _model.CreateTagAsync(name);
            }
            catch (Exception ex)
            {
                _model.PresentToast("Could not create tag", ex.Message, NoticeSeverity.Error);
            }
        }
    }

    private async Task ConfirmAndDeleteAsync(IReadOnlyList<SXMMetadata> targets)
    {
        if (targets.Count == 0) return;
        bool confirmed = await Dialogs.ConfirmRecycleBinAsync(this, targets.Select(t => t.Filename).ToArray());
        if (!confirmed) return;
        try
        {
            _model.DeleteFilesToRecycleBin(targets);
        }
        catch (Exception ex)
        {
            _model.PresentToast("Recycle Bin Failed", ex.Message, NoticeSeverity.Error);
        }
    }

    private async Task ExportPngDialogAsync(SXMMetadata file)
    {
        if (!_model.SelectedIds.Contains(file.Id))
        {
            _model.SelectOnly(file.Id);
        }
        string stem = Path.GetFileNameWithoutExtension(file.Filename);
        IStorageFile? dest = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Export Scan as PNG",
            SuggestedFileName = $"{stem}.png",
            DefaultExtension = "png",
            FileTypeChoices = [new FilePickerFileType("PNG Image") { Patterns = ["*.png"] }]
        });
        string? destPath = dest?.TryGetLocalPath();
        if (string.IsNullOrEmpty(destPath)) return;

        try
        {
            await _model.ExportPngAsync(destPath);
        }
        catch (Exception ex)
        {
            _model.PresentToast("PNG Export Failed", ex.Message, NoticeSeverity.Error);
        }
    }

    private async Task ExportMetadataDialogAsync()
    {
        if (_model.ActiveSession is null)
        {
            _model.PresentToast("Export Metadata", "Open a dataset folder first.", NoticeSeverity.Warning);
            return;
        }
        IStorageFile? dest = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Export Dataset Metadata",
            SuggestedFileName = $"{_model.FolderName}.sxm-metadata.json",
            DefaultExtension = "json",
            FileTypeChoices = [new FilePickerFileType("SXM Browser Metadata") { Patterns = ["*.json"] }]
        });
        string? destPath = dest?.TryGetLocalPath();
        if (string.IsNullOrEmpty(destPath)) return;

        try
        {
            await _model.ExportMetadataAsync(destPath);
        }
        catch (Exception ex)
        {
            _model.PresentToast("Metadata Export Failed", ex.Message, NoticeSeverity.Error);
        }
    }

    private async Task ImportMetadataDialogAsync()
    {
        if (_model.ActiveSession is null)
        {
            _model.PresentToast("Import Metadata", "Open a dataset folder first.", NoticeSeverity.Warning);
            return;
        }
        IReadOnlyList<IStorageFile> picked = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Import Dataset Metadata",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("JSON Metadata") { Patterns = ["*.json"] }]
        });
        if (picked.Count == 0) return;
        string? srcPath = picked[0].TryGetLocalPath();
        if (string.IsNullOrEmpty(srcPath)) return;

        try
        {
            MetadataImportWorkflow workflow = _model.PrepareMetadataImport(srcPath);
            await Dialogs.ShowMetadataImportPreviewAsync(this, _model, workflow);
        }
        catch (Exception ex)
        {
            _model.PresentToast("Metadata Import Failed", ex.Message, NoticeSeverity.Error);
        }
    }

    // --- Drag & Drop ---

    private void OnDragOver(object? sender, DragEventArgs e)
    {
        if (e.Data.Contains(DataFormats.Files))
        {
            e.DragEffects = DragDropEffects.Copy;
            _dropOverlay.IsVisible = true;
        }
        else
        {
            e.DragEffects = DragDropEffects.None;
            _dropOverlay.IsVisible = false;
        }
        e.Handled = true;
    }

    private void OnDragLeave(object? sender, DragEventArgs e)
    {
        _dropOverlay.IsVisible = false;
    }

    private async void OnDrop(object? sender, DragEventArgs e)
    {
        _dropOverlay.IsVisible = false;
        IEnumerable<IStorageItem>? items = e.Data.GetFiles();
        if (items is null) return;

        foreach (IStorageItem item in items)
        {
            string? local = item.TryGetLocalPath();
            if (string.IsNullOrEmpty(local)) continue;
            string? folder = Directory.Exists(local) ? local : Path.GetDirectoryName(local);
            if (!string.IsNullOrEmpty(folder) && Directory.Exists(folder))
            {
                await _model.OpenFolderAsync(folder);
                break;
            }
        }
        e.Handled = true;
    }
}
