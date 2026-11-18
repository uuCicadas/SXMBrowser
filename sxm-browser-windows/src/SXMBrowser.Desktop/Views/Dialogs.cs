using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using SXMBrowser.AppCore;
using SXMBrowser.Desktop.Controllers;

namespace SXMBrowser.Desktop.Views;

public static class Dialogs
{
    public static async Task<string?> ShowTextPromptAsync(
        Window owner,
        string title,
        string prompt,
        string initialValue = "",
        string confirmLabel = "OK")
    {
        string? result = null;
        var input = new TextBox
        {
            Text = initialValue,
            Watermark = prompt,
            MinWidth = 300
        };

        var okBtn = new Button
        {
            Content = confirmLabel,
            IsDefault = true,
            IsEnabled = !string.IsNullOrWhiteSpace(initialValue)
        };
        var cancelBtn = new Button
        {
            Content = "Cancel",
            IsCancel = true
        };

        input.TextChanged += (_, _) => okBtn.IsEnabled = !string.IsNullOrWhiteSpace(input.Text);

        var win = new Window
        {
            Title = title,
            Width = 380,
            SizeToContent = SizeToContent.Height,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = new StackPanel
            {
                Margin = new Thickness(18),
                Spacing = 12,
                Children =
                {
                    new TextBlock { Text = prompt, TextWrapping = TextWrapping.Wrap },
                    input,
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        HorizontalAlignment = HorizontalAlignment.Right,
                        Spacing = 8,
                        Children = { cancelBtn, okBtn }
                    }
                }
            }
        };

        okBtn.Click += (_, _) =>
        {
            result = input.Text?.Trim();
            win.Close();
        };
        cancelBtn.Click += (_, _) =>
        {
            result = null;
            win.Close();
        };
        win.Opened += (_, _) =>
        {
            input.Focus();
            input.SelectAll();
        };

        await win.ShowDialog(owner);
        return string.IsNullOrWhiteSpace(result) ? null : result;
    }

    public static async Task<bool> ConfirmRecycleBinAsync(
        Window owner,
        IReadOnlyList<string> filenames)
    {
        bool confirmed = false;
        string summary = filenames.Count == 1
            ? $"Move \u201C{filenames[0]}\u201D to the Recycle Bin?"
            : $"Move {filenames.Count} selected scan files to the Recycle Bin?";

        var listBox = new ItemsControl
        {
            ItemsSource = filenames.Take(20).ToArray()
        };

        var deleteBtn = new Button { Content = "Move to Recycle Bin" };
        var cancelBtn = new Button { Content = "Cancel", IsCancel = true, IsDefault = true };

        var win = new Window
        {
            Title = "Move to Recycle Bin",
            Width = 420,
            SizeToContent = SizeToContent.Height,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = new StackPanel
            {
                Margin = new Thickness(18),
                Spacing = 12,
                Children =
                {
                    new TextBlock
                    {
                        Text = summary,
                        FontWeight = FontWeight.SemiBold,
                        TextWrapping = TextWrapping.Wrap
                    },
                    new Border
                    {
                        BorderThickness = new Thickness(1),
                        CornerRadius = new CornerRadius(4),
                        MaxHeight = 160,
                        Padding = new Thickness(8),
                        Child = new ScrollViewer { Content = listBox }
                    },
                    new TextBlock
                    {
                        Text = "Files remain recoverable from the Recycle Bin. Saved tags and metadata are preserved.",
                        FontSize = 12,
                        Opacity = 0.75,
                        TextWrapping = TextWrapping.Wrap
                    },
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        HorizontalAlignment = HorizontalAlignment.Right,
                        Spacing = 8,
                        Children = { cancelBtn, deleteBtn }
                    }
                }
            }
        };

        deleteBtn.Click += (_, _) =>
        {
            confirmed = true;
            win.Close();
        };
        cancelBtn.Click += (_, _) =>
        {
            confirmed = false;
            win.Close();
        };

        await win.ShowDialog(owner);
        return confirmed;
    }

    public static async Task ShowDetailsListAsync(
        Window owner,
        string title,
        IReadOnlyList<string> lines)
    {
        var closeBtn = new Button { Content = "Close", IsDefault = true, IsCancel = true };
        var win = new Window
        {
            Title = title,
            Width = 560,
            Height = 380,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = new DockPanel
            {
                Margin = new Thickness(16),
                Children =
                {
                    CreateFooterDock(closeBtn),
                    new ScrollViewer
                    {
                        Content = new SelectableTextBlock
                        {
                            Text = string.Join("\n\n", lines),
                            TextWrapping = TextWrapping.Wrap,
                            FontSize = 12
                        }
                    }
                }
            }
        };
        closeBtn.Click += (_, _) => win.Close();
        await win.ShowDialog(owner);
    }

    public static async Task ShowMetadataImportPreviewAsync(
        Window owner,
        AppModel model,
        MetadataImportWorkflow initialWorkflow)
    {
        MetadataImportWorkflow workflow = initialWorkflow;
        bool guard = false;

        var policyOptions = new[]
        {
            DatasetMetadataImportConflictPolicy.KeepDestination,
            DatasetMetadataImportConflictPolicy.UseImported,
            DatasetMetadataImportConflictPolicy.RequireDecision
        };

        string PolicyLabel(DatasetMetadataImportConflictPolicy p) => p switch
        {
            DatasetMetadataImportConflictPolicy.KeepDestination => "Keep Existing",
            DatasetMetadataImportConflictPolicy.UseImported => "Use Imported",
            DatasetMetadataImportConflictPolicy.RequireDecision => "Require Decision",
            _ => p.ToString()
        };

        ComboBox MakePolicyBox(DatasetMetadataImportConflictPolicy current)
        {
            var box = new ComboBox
            {
                ItemsSource = policyOptions.Select(PolicyLabel).ToArray(),
                SelectedIndex = Array.IndexOf(policyOptions, current),
                MinWidth = 150
            };
            return box;
        }

        ComboBox tagPolicyBox = MakePolicyBox(workflow.Policy.TagIdentity);
        ComboBox assocPolicyBox = MakePolicyBox(workflow.Policy.Association);
        ComboBox axisPolicyBox = MakePolicyBox(workflow.Policy.Axis);

        var summaryText = new TextBlock { TextWrapping = TextWrapping.Wrap, FontWeight = FontWeight.SemiBold };
        var detailsText = new SelectableTextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
        var importBtn = new Button { Content = "Import", IsDefault = true };
        var cancelBtn = new Button { Content = "Cancel", IsCancel = true };

        void RefreshUi()
        {
            if (workflow.Plan is not { } plan) return;
            DatasetMetadataImportSummary s = plan.Summary;
            summaryText.Text =
                $"Actions: {s.ActionCount} (Tags: {s.TagActionCount}, Associations: {s.AssociationActionCount}, Hidden: {s.HiddenActionCount}, Axes: {s.AxisActionCount}) | " +
                $"Skipped: {s.SkippedItemCount} | Resolved Conflicts: {s.ResolvedConflictCount} | Unresolved Conflicts: {s.UnresolvedConflictCount}";

            var lines = new List<string>();
            if (plan.Actions.Count == 0 && plan.Issues.Count == 0)
            {
                lines.Add("No differences found between the transfer file and current dataset metadata.");
            }
            foreach (DatasetMetadataImportAction action in plan.Actions)
            {
                lines.Add($"+ {FormatAction(action)}");
            }
            foreach (DatasetMetadataImportIssue issue in plan.Issues)
            {
                lines.Add($"! {FormatIssue(issue)}");
            }

            detailsText.Text = string.Join("\n", lines);
            importBtn.IsEnabled = plan.CanApply && plan.HasChanges;
        }

        void OnPolicyChanged(object? sender, SelectionChangedEventArgs e)
        {
            if (guard) return;
            var nextPolicy = new DatasetMetadataImportPolicy(
                policyOptions[Math.Max(0, tagPolicyBox.SelectedIndex)],
                policyOptions[Math.Max(0, assocPolicyBox.SelectedIndex)],
                policyOptions[Math.Max(0, axisPolicyBox.SelectedIndex)]);
            workflow = model.ReplanMetadataImport(workflow, nextPolicy);
            RefreshUi();
        }

        tagPolicyBox.SelectionChanged += OnPolicyChanged;
        assocPolicyBox.SelectionChanged += OnPolicyChanged;
        axisPolicyBox.SelectionChanged += OnPolicyChanged;

        var policyGrid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,*,Auto,*"),
            RowDefinitions = new RowDefinitions("Auto")
        };
        var l1 = new TextBlock { Text = "Tags:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
        var l2 = new TextBlock { Text = "Associations:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 6, 0) };
        var l3 = new TextBlock { Text = "Axes:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 6, 0) };
        Grid.SetColumn(l1, 0); Grid.SetColumn(tagPolicyBox, 1);
        Grid.SetColumn(l2, 2); Grid.SetColumn(assocPolicyBox, 3);
        Grid.SetColumn(l3, 4); Grid.SetColumn(axisPolicyBox, 5);
        policyGrid.Children.AddRange([l1, tagPolicyBox, l2, assocPolicyBox, l3, axisPolicyBox]);

        var buttonsPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8,
            Margin = new Thickness(0, 12, 0, 0),
            Children = { cancelBtn, importBtn }
        };
        DockPanel.SetDock(buttonsPanel, Dock.Bottom);

        var headerPanel = new StackPanel
        {
            Spacing = 8,
            Margin = new Thickness(0, 0, 0, 8),
            Children =
            {
                new TextBlock { Text = $"File: {workflow.SourceFilename}", Opacity = 0.8 },
                policyGrid,
                summaryText
            }
        };
        DockPanel.SetDock(headerPanel, Dock.Top);

        var win = new Window
        {
            Title = "Import Metadata Preview",
            Width = 680,
            Height = 480,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = new DockPanel
            {
                Margin = new Thickness(16),
                Children =
                {
                    headerPanel,
                    buttonsPanel,
                    new Border
                    {
                        BorderThickness = new Thickness(1),
                        CornerRadius = new CornerRadius(4),
                        Padding = new Thickness(10),
                        Child = new ScrollViewer { Content = detailsText }
                    }
                }
            }
        };

        cancelBtn.Click += (_, _) => win.Close();
        importBtn.Click += async (_, _) =>
        {
            importBtn.IsEnabled = false;
            try
            {
                await model.ApplyMetadataImportAsync(workflow);
                win.Close();
            }
            catch (Exception ex)
            {
                summaryText.Text = $"Import failed: {ex.Message}";
                importBtn.IsEnabled = true;
            }
        };

        guard = true;
        RefreshUi();
        guard = false;

        await win.ShowDialog(owner);
    }

    private static StackPanel CreateFooterDock(Button closeBtn)
    {
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0),
            Children = { closeBtn }
        };
        DockPanel.SetDock(panel, Dock.Bottom);
        return panel;
    }

    private static string FormatAction(DatasetMetadataImportAction action) => action switch
    {
        DatasetMetadataImportAction.AddTag a => $"Add tag \u201C{a.Tag.Name}\u201D ({a.Tag.SxmPaths.Count} files)",
        DatasetMetadataImportAction.MergeTag m => $"Merge {m.AddedSxmPaths.Count} file(s) into tag {m.DestinationTagId}",
        DatasetMetadataImportAction.RenameTag r => $"Rename tag \u201C{r.From}\u201D \u2192 \u201C{r.To}\u201D",
        DatasetMetadataImportAction.AddManualAssociation a => $"Associate {a.Association.DatPath} \u2192 {a.Association.SxmPath}",
        DatasetMetadataImportAction.ReplaceManualAssociation r => $"Replace association {r.DatPath}: {r.From} \u2192 {r.To}",
        DatasetMetadataImportAction.HideDat h => $"Hide spectrum {h.DatPath}",
        DatasetMetadataImportAction.AddAxisPreference p => $"Add axis pref {p.Preference.Key.SxmPath}: {p.Preference.Selection.XColumn} / {p.Preference.Selection.YColumn}",
        DatasetMetadataImportAction.ReplaceAxisPreference r => $"Replace axis pref {r.Key.SxmPath}: ({r.To.XColumn}, {r.To.YColumn})",
        _ => action.ToString() ?? string.Empty
    };

    private static string FormatIssue(DatasetMetadataImportIssue issue) => issue switch
    {
        DatasetMetadataImportIssue.MissingTagMember m => $"Skipped missing tag member {m.SxmPath}",
        DatasetMetadataImportIssue.TagIdentityConflict t => $"Tag conflict ({t.Kind}) for \u201C{t.ImportedName}\u201D [{t.Resolution}]",
        DatasetMetadataImportIssue.AssociationDatMissing a => $"Skipped missing DAT {a.DatPath}",
        DatasetMetadataImportIssue.AssociationSxmMissing a => $"Skipped association for {a.DatPath}: missing {a.SxmPath}",
        DatasetMetadataImportIssue.AssociationConflict a => $"Association conflict for {a.DatPath}: {a.DestinationSxmPath} vs {a.ImportedSxmPath} [{a.Resolution}]",
        DatasetMetadataImportIssue.HiddenDatMissing h => $"Skipped missing hidden DAT {h.DatPath}",
        DatasetMetadataImportIssue.AxisGroupUnavailable ax => $"Axis group unavailable for {ax.Key.SxmPath}",
        DatasetMetadataImportIssue.AxisExperimentAmbiguous ax => $"Ambiguous experiment for {ax.Key.SxmPath}",
        DatasetMetadataImportIssue.AxisColumnMissing ax => $"Missing axis column \u201C{ax.Column}\u201D for {ax.Key.SxmPath}",
        DatasetMetadataImportIssue.AxisColumnAmbiguous ax => $"Ambiguous axis column \u201C{ax.Column}\u201D for {ax.Key.SxmPath}",
        DatasetMetadataImportIssue.AxisConflict ax => $"Axis conflict for {ax.Key.SxmPath} [{ax.Resolution}]",
        _ => issue.ToString() ?? string.Empty
    };
}
