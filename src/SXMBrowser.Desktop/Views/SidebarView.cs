using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using SXMBrowser.AppCore;
using SXMBrowser.Desktop.Controllers;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Views;

public sealed class SidebarView : Border
{
    private readonly AppModel _model;
    private readonly TextBlock _folderTitle;
    private readonly TextBlock _folderPathText;
    private readonly Button _allScansBtn;
    private readonly TextBlock _allScansCount;
    private readonly Button _newTagBtn;
    private readonly StackPanel _tagsHost;
    private readonly StackPanel _spectraHost;
    private readonly Button _associateBtn;
    private readonly Button _resetAssocBtn;

    private bool _guard;

    public Func<string, string, string, Task<string?>>? PromptTextAsync { get; set; }

    public SidebarView(AppModel model)
    {
        _model = model;
        BorderThickness = new Thickness(0, 0, 1, 0);

        _folderTitle = new TextBlock
        {
            FontWeight = FontWeight.SemiBold,
            FontSize = 13.5,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        _folderPathText = new TextBlock
        {
            FontSize = 11,
            Opacity = 0.7,
            TextTrimming = TextTrimming.CharacterEllipsis
        };

        _allScansCount = new TextBlock
        {
            FontSize = 11.5,
            Opacity = 0.8,
            VerticalAlignment = VerticalAlignment.Center
        };
        var allRowContent = new DockPanel();
        DockPanel.SetDock(_allScansCount, Dock.Right);
        allRowContent.Children.Add(_allScansCount);
        allRowContent.Children.Add(new TextBlock
        {
            Text = "All Scans",
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = FontWeight.Medium
        });

        _allScansBtn = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 6),
            Content = allRowContent
        };
        _allScansBtn.Click += (_, _) => _model.SetScope(BrowserScope.All.Instance);

        _newTagBtn = new Button
        {
            Content = "+ Tag",
            Padding = new Thickness(8, 2),
            FontSize = 11.5
        };
        _newTagBtn.Click += async (_, _) => await CreateTagPromptAsync();

        _tagsHost = new StackPanel { Spacing = 3 };
        _spectraHost = new StackPanel { Spacing = 2 };

        _associateBtn = new Button
        {
            Content = "Associate with Selected",
            FontSize = 11.5,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center
        };
        _resetAssocBtn = new Button
        {
            Content = "Reset Manual",
            FontSize = 11.5,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center
        };

        _associateBtn.Click += async (_, _) => await _model.AssociateSpectraToSelectedSxmAsync();
        _resetAssocBtn.Click += async (_, _) => await _model.ResetManualAssociationsAsync();

        var tagsHeader = new DockPanel { Margin = new Thickness(0, 8, 0, 4) };
        DockPanel.SetDock(_newTagBtn, Dock.Right);
        tagsHeader.Children.Add(_newTagBtn);
        tagsHeader.Children.Add(new TextBlock
        {
            Text = "TAGS",
            FontSize = 11,
            FontWeight = FontWeight.SemiBold,
            Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center
        });

        var spectraHeader = new TextBlock
        {
            Text = "SPECTROSCOPY (.DAT)",
            FontSize = 11,
            FontWeight = FontWeight.SemiBold,
            Opacity = 0.7,
            Margin = new Thickness(0, 12, 0, 4)
        };

        var mainStack = new StackPanel
        {
            Spacing = 6,
            Children =
            {
                new StackPanel
                {
                    Spacing = 2,
                    Margin = new Thickness(2, 0, 2, 6),
                    Children = { _folderTitle, _folderPathText }
                },
                _allScansBtn,
                tagsHeader,
                _tagsHost,
                spectraHeader,
                _spectraHost
            }
        };

        var bottomAssocBar = new StackPanel
        {
            Spacing = 4,
            Margin = new Thickness(10, 8),
            Children = { _associateBtn, _resetAssocBtn }
        };

        var dock = new DockPanel();
        DockPanel.SetDock(bottomAssocBar, Dock.Bottom);
        dock.Children.Add(bottomAssocBar);
        dock.Children.Add(new ScrollViewer
        {
            Padding = new Thickness(10, 10, 10, 6),
            Content = mainStack
        });

        Child = dock;
        ActualThemeVariantChanged += (_, _) => ApplyTheme();
        ApplyTheme();
        SyncFromModel();
    }

    public void ApplyTheme()
    {
        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        Background = theme.SidebarSurfaceBrush;
        BorderBrush = theme.HairlineBorderBrush;
        RefreshRowHighlights(theme);
    }

    private async System.Threading.Tasks.Task CreateTagPromptAsync()
    {
        if (PromptTextAsync is null) return;
        string? name = await PromptTextAsync("New Tag", "Enter tag name", "");
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

    private async System.Threading.Tasks.Task RenameTagPromptAsync(DatasetTagV1 tag)
    {
        if (PromptTextAsync is null) return;
        string? name = await PromptTextAsync("Rename Tag", "Enter updated tag name", tag.Name);
        if (!string.IsNullOrWhiteSpace(name))
        {
            try
            {
                await _model.RenameTagAsync(tag.Id, name);
            }
            catch (Exception ex)
            {
                _model.PresentToast("Could not rename tag", ex.Message, NoticeSeverity.Error);
            }
        }
    }

    public void SyncFromModel()
    {
        _guard = true;
        try
        {
            AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
            _folderTitle.Text = _model.FolderName;
            _folderPathText.Text = _model.FolderPath ?? "Open an experiment folder to start";
            ToolTip.SetTip(_folderPathText, _model.FolderPath);

            _allScansCount.Text = _model.AllFiles.Count.ToString();
            _newTagBtn.IsEnabled = _model.ActiveSession is not null;

            RebuildTagsList(theme);
            RebuildSpectraList(theme);

            int selSpecCount = _model.SelectedSidebarSpectrumIds.Count;
            _associateBtn.IsEnabled = selSpecCount > 0 && _model.SelectedFile is not null;
            _resetAssocBtn.IsEnabled = _model.SidebarSpectrumRows.Any(
                r => _model.SelectedSidebarSpectrumIds.Contains(r.Spectrum.Id) && (r.IsManualAssociation || r.HasMissingManualTarget));

            RefreshRowHighlights(theme);
        }
        finally
        {
            _guard = false;
        }
    }

    private void RebuildTagsList(AppThemePalette theme)
    {
        _tagsHost.Children.Clear();
        IReadOnlyList<DatasetTagV1> tags = _model.Tags;
        if (tags.Count == 0)
        {
            _tagsHost.Children.Add(new TextBlock
            {
                Text = "No tags yet",
                FontSize = 11.5,
                Opacity = 0.6,
                Margin = new Thickness(6, 2)
            });
            return;
        }

        for (int i = 0; i < tags.Count; i++)
        {
            DatasetTagV1 tag = tags[i];
            bool isSelectedScope = _model.ActiveScope is BrowserScope.Tag ts && ts.TagId == tag.Id;
            bool isExpanded = _model.ExpandedTagIds.Contains(tag.Id);

            var discloseBtn = new Button
            {
                Content = isExpanded ? "\u25BE" : "\u25B8",
                Padding = new Thickness(4, 2),
                Background = Brushes.Transparent,
                FontSize = 11
            };
            discloseBtn.Click += (_, _) => _model.ToggleTagExpanded(tag.Id);

            var countBadge = new TextBlock
            {
                Text = tag.SxmPaths.Count.ToString(),
                FontSize = 11.5,
                Opacity = 0.75,
                VerticalAlignment = VerticalAlignment.Center
            };

            var nameBlock = new TextBlock
            {
                Text = tag.Name,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis
            };

            var rowDock = new DockPanel();
            DockPanel.SetDock(discloseBtn, Dock.Left);
            DockPanel.SetDock(countBadge, Dock.Right);
            rowDock.Children.Add(discloseBtn);
            rowDock.Children.Add(countBadge);
            rowDock.Children.Add(nameBlock);

            var tagBtn = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(6, 5),
                Background = isSelectedScope ? theme.AccentSubtleBrush : Brushes.Transparent,
                Content = rowDock
            };
            tagBtn.Click += (_, _) => _model.SetScope(new BrowserScope.Tag(tag.Id));

            var menu = new ContextMenu();
            var renameItem = new MenuItem { Header = "Rename Tag\u2026" };
            renameItem.Click += async (_, _) => await RenameTagPromptAsync(tag);
            menu.Items.Add(renameItem);

            if (i > 0)
            {
                DatasetTagV1 prevTag = tags[i - 1];
                var moveUp = new MenuItem { Header = "Move Up" };
                moveUp.Click += async (_, _) => await _model.MoveTagAsync(tag.Id, prevTag.Id);
                menu.Items.Add(moveUp);
            }
            if (i + 1 < tags.Count)
            {
                DatasetTagV1 nextTag = tags[i + 1];
                var moveDown = new MenuItem { Header = "Move Down" };
                moveDown.Click += async (_, _) => await _model.MoveTagAsync(tag.Id, nextTag.Id);
                menu.Items.Add(moveDown);
            }
            menu.Items.Add(new Separator());
            var deleteItem = new MenuItem { Header = "Delete Tag" };
            deleteItem.Click += async (_, _) => await _model.DeleteTagAsync(tag.Id);
            menu.Items.Add(deleteItem);

            tagBtn.ContextMenu = menu;
            _tagsHost.Children.Add(tagBtn);

            if (isExpanded && tag.SxmPaths.Count > 0)
            {
                var membersPanel = new StackPanel
                {
                    Margin = new Thickness(22, 1, 4, 4),
                    Spacing = 1
                };
                foreach (DatasetRelativePath p in tag.SxmPaths)
                {
                    Guid? sxmId = _model.ActiveSession?.PathIndex.SxmId(p);
                    var memberBtn = new Button
                    {
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        HorizontalContentAlignment = HorizontalAlignment.Left,
                        Padding = new Thickness(6, 2),
                        Background = Brushes.Transparent,
                        FontSize = 11.5,
                        Content = new TextBlock
                        {
                            Text = p.RawValue,
                            TextTrimming = TextTrimming.CharacterEllipsis
                        }
                    };
                    if (sxmId is { } targetId)
                    {
                        memberBtn.Click += (_, _) => _model.SelectOnly(targetId);
                    }
                    membersPanel.Children.Add(memberBtn);
                }
                _tagsHost.Children.Add(membersPanel);
            }
        }
    }

    private void RebuildSpectraList(AppThemePalette theme)
    {
        _spectraHost.Children.Clear();
        IReadOnlyList<SidebarSpectrumRow> rows = _model.SidebarSpectrumRows;
        if (rows.Count == 0)
        {
            _spectraHost.Children.Add(new TextBlock
            {
                Text = "No .dat spectra found",
                FontSize = 11.5,
                Opacity = 0.6,
                Margin = new Thickness(6, 2)
            });
            return;
        }

        foreach (SidebarSpectrumRow row in rows)
        {
            bool isSelected = _model.SelectedSidebarSpectrumIds.Contains(row.Spectrum.Id);

            var visCheck = new CheckBox
            {
                IsChecked = row.IsVisible,
                Padding = new Thickness(0),
                VerticalAlignment = VerticalAlignment.Center
            };
            ToolTip.SetTip(visCheck, row.IsVisible ? "Hide curve" : "Show curve");
            visCheck.IsCheckedChanged += async (_, _) =>
            {
                if (_guard) return;
                await _model.ToggleSpectrumVisibilityAsync(row.Spectrum.Id, visCheck.IsChecked ?? true);
            };

            string parentSubtitle = row.HasMissingManualTarget
                ? $"Missing manual target: {row.MissingTargetPath?.RawValue}"
                : row.ParentSxmFilename is not null
                    ? (row.IsManualAssociation ? $"\u2192 {row.ParentSxmFilename} (Manual)" : $"\u2192 {row.ParentSxmFilename}")
                    : "Unassociated";

            var labels = new StackPanel
            {
                Spacing = 1,
                Children =
                {
                    new TextBlock
                    {
                        Text = row.Spectrum.Filename,
                        FontSize = 11.5,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        Opacity = row.IsVisible ? 1.0 : 0.45
                    },
                    new TextBlock
                    {
                        Text = parentSubtitle,
                        FontSize = 10,
                        Foreground = row.HasMissingManualTarget ? theme.WarningBrush : theme.TextMutedBrush,
                        TextTrimming = TextTrimming.CharacterEllipsis
                    }
                }
            };

            var rowGrid = new DockPanel { LastChildFill = true };
            DockPanel.SetDock(visCheck, Dock.Right);
            rowGrid.Children.Add(visCheck);
            rowGrid.Children.Add(labels);

            var card = new Border
            {
                CornerRadius = new CornerRadius(5),
                Padding = new Thickness(6, 4),
                Background = isSelected ? theme.SelectedTileBrush : Brushes.Transparent,
                BorderBrush = isSelected ? theme.AccentBrush : Brushes.Transparent,
                BorderThickness = new Thickness(1),
                Child = rowGrid
            };

            card.PointerPressed += (_, e) =>
            {
                KeyModifiers mods = e.KeyModifiers;
                SpectrumRowModifier modifier = (mods & KeyModifiers.Control) != 0 || (mods & KeyModifiers.Meta) != 0
                    ? SpectrumRowModifier.Command
                    : (mods & KeyModifiers.Shift) != 0
                        ? SpectrumRowModifier.Shift
                        : SpectrumRowModifier.Plain;
                _model.ClickSidebarSpectrum(row.Spectrum.Id, modifier);
                e.Handled = true;
            };

            _spectraHost.Children.Add(card);
        }
    }

    private void RefreshRowHighlights(AppThemePalette theme)
    {
        bool isAll = _model.ActiveScope is BrowserScope.All;
        _allScansBtn.Background = isAll ? theme.AccentSubtleBrush : Brushes.Transparent;
    }
}
