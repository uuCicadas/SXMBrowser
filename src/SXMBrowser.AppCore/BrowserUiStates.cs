using System;
using System.Collections.Generic;

namespace SXMBrowser.AppCore;

public abstract record DatasetLoadState
{
    public sealed record Idle : DatasetLoadState { public static readonly Idle Instance = new(); }
    public sealed record Loading : DatasetLoadState { public static readonly Loading Instance = new(); }
    public sealed record Ready : DatasetLoadState { public static readonly Ready Instance = new(); }
    public sealed record Failed(string Message) : DatasetLoadState;

    public bool IsLoading => this is Loading;
}

public abstract record SelectedRenderState<TId> where TId : notnull
{
    public sealed record Idle : SelectedRenderState<TId> { public static readonly Idle Instance = new(); }
    public sealed record Loading(TId FileId) : SelectedRenderState<TId>;
    public sealed record Ready(TId FileId) : SelectedRenderState<TId>;
    public sealed record Failed(TId FileId, string Message) : SelectedRenderState<TId>;
}

public abstract record BrowserContentState<TId> where TId : notnull
{
    public sealed record OpenFolder : BrowserContentState<TId> { public static readonly OpenFolder Instance = new(); }
    public sealed record LoadingFolder : BrowserContentState<TId> { public static readonly LoadingFolder Instance = new(); }
    public sealed record FolderFailed(string Message) : BrowserContentState<TId>;
    public sealed record EmptyFolder : BrowserContentState<TId> { public static readonly EmptyFolder Instance = new(); }
    public sealed record NoSearchResults : BrowserContentState<TId> { public static readonly NoSearchResults Instance = new(); }
    public sealed record NoVisibleFiles : BrowserContentState<TId> { public static readonly NoVisibleFiles Instance = new(); }
    public sealed record GridReady : BrowserContentState<TId> { public static readonly GridReady Instance = new(); }
    public sealed record NoSelection : BrowserContentState<TId> { public static readonly NoSelection Instance = new(); }
    public sealed record RenderLoading(TId FileId) : BrowserContentState<TId>;
    public sealed record RenderReady(TId FileId) : BrowserContentState<TId>;
    public sealed record RenderFailed(TId FileId, string Message) : BrowserContentState<TId>;
}

public static class BrowserContentProjection
{
    public static BrowserContentState<TId> Resolve<TId>(
        DatasetLoadState datasetState,
        int totalFileCount,
        int visibleFileCount,
        bool searchIsActive,
        bool isSingleMode,
        TId? selectedFileId,
        SelectedRenderState<TId> renderState) where TId : struct
    {
        switch (datasetState)
        {
            case DatasetLoadState.Idle:
                return BrowserContentState<TId>.OpenFolder.Instance;
            case DatasetLoadState.Loading:
                return BrowserContentState<TId>.LoadingFolder.Instance;
            case DatasetLoadState.Failed f:
                return new BrowserContentState<TId>.FolderFailed(f.Message);
        }

        if (totalFileCount <= 0) return BrowserContentState<TId>.EmptyFolder.Instance;
        if (visibleFileCount <= 0)
        {
            return searchIsActive
                ? BrowserContentState<TId>.NoSearchResults.Instance
                : BrowserContentState<TId>.NoVisibleFiles.Instance;
        }
        if (!isSingleMode) return BrowserContentState<TId>.GridReady.Instance;
        if (selectedFileId is not { } sid) return BrowserContentState<TId>.NoSelection.Instance;

        return renderState switch
        {
            SelectedRenderState<TId>.Ready r when EqualityComparer<TId>.Default.Equals(r.FileId, sid)
                => new BrowserContentState<TId>.RenderReady(sid),
            SelectedRenderState<TId>.Failed f when EqualityComparer<TId>.Default.Equals(f.FileId, sid)
                => new BrowserContentState<TId>.RenderFailed(sid, f.Message),
            _ => new BrowserContentState<TId>.RenderLoading(sid)
        };
    }
}

public abstract record BrowserKeyboardCommand
{
    public sealed record Move(GridNavigationDirection Direction, bool ExtendingSelection) : BrowserKeyboardCommand;
    public sealed record OpenSelection : BrowserKeyboardCommand { public static readonly OpenSelection Instance = new(); }
    public sealed record ShowGrid : BrowserKeyboardCommand { public static readonly ShowGrid Instance = new(); }
}

public enum BrowserVirtualKey
{
    Left,
    Right,
    Down,
    Up,
    Enter,
    Escape,
    Other
}

public static class BrowserKeyboardRouting
{
    public static BrowserKeyboardCommand? CommandForKey(
        BrowserVirtualKey key,
        bool hasCommandModifiers,
        bool isShiftPressed,
        bool interactiveControlHasFocus)
    {
        if (hasCommandModifiers || interactiveControlHasFocus) return null;

        return key switch
        {
            BrowserVirtualKey.Left => new BrowserKeyboardCommand.Move(GridNavigationDirection.Left, isShiftPressed),
            BrowserVirtualKey.Right => new BrowserKeyboardCommand.Move(GridNavigationDirection.Right, isShiftPressed),
            BrowserVirtualKey.Down => new BrowserKeyboardCommand.Move(GridNavigationDirection.Down, isShiftPressed),
            BrowserVirtualKey.Up => new BrowserKeyboardCommand.Move(GridNavigationDirection.Up, isShiftPressed),
            BrowserVirtualKey.Enter when !isShiftPressed => BrowserKeyboardCommand.OpenSelection.Instance,
            BrowserVirtualKey.Escape when !isShiftPressed => BrowserKeyboardCommand.ShowGrid.Instance,
            _ => null
        };
    }
}

public enum NativePanePriority
{
    Sidebar,
    Inspector
}

public readonly record struct NativePaneLayout
{
    public const double MinimumContentWidth = 320.0;
    public const double SidebarMinWidth = 220.0;
    public const double SidebarMaxWidth = 460.0;
    public const double InspectorMinWidth = 260.0;
    public const double InspectorMaxWidth = 430.0;

    public bool ShowsSidebar { get; }
    public bool ShowsInspector { get; }
    public double SidebarWidth { get; }
    public double InspectorWidth { get; }

    public NativePaneLayout(
        double containerWidth,
        bool wantsSidebar,
        bool wantsInspector,
        double preferredSidebarWidth,
        double preferredInspectorWidth,
        NativePanePriority priority = NativePanePriority.Sidebar,
        double dividerThickness = 1.0)
    {
        double available = double.IsFinite(containerWidth) ? Math.Max(0.0, containerWidth) : 0.0;
        double divider = double.IsFinite(dividerThickness) ? Math.Max(0.0, dividerThickness) : 1.0;
        double sidebar = Clamp(preferredSidebarWidth, SidebarMinWidth, SidebarMaxWidth, 300.0);
        double inspector = Clamp(preferredInspectorWidth, InspectorMinWidth, InspectorMaxWidth, 320.0);
        bool bothFit = available >= MinimumContentWidth + SidebarMinWidth + InspectorMinWidth + 2.0 * divider;

        if (wantsSidebar && wantsInspector && bothFit)
        {
            double budget = available - MinimumContentWidth - 2.0 * divider;
            double excess = Math.Max(0.0, sidebar + inspector - budget);
            if (priority == NativePanePriority.Sidebar)
            {
                double reduction = Math.Min(excess, inspector - InspectorMinWidth);
                inspector -= reduction;
                excess -= reduction;
                sidebar -= Math.Min(excess, sidebar - SidebarMinWidth);
            }
            else
            {
                double reduction = Math.Min(excess, sidebar - SidebarMinWidth);
                sidebar -= reduction;
                excess -= reduction;
                inspector -= Math.Min(excess, inspector - InspectorMinWidth);
            }
            ShowsSidebar = true;
            ShowsInspector = true;
        }
        else
        {
            bool sidebarFits = wantsSidebar && available >= MinimumContentWidth + SidebarMinWidth + divider;
            bool inspectorFits = wantsInspector && available >= MinimumContentWidth + InspectorMinWidth + divider;
            ShowsSidebar = sidebarFits && (priority == NativePanePriority.Sidebar || !inspectorFits);
            ShowsInspector = inspectorFits && !ShowsSidebar;
            if (ShowsSidebar)
            {
                sidebar = Math.Min(sidebar, available - MinimumContentWidth - divider);
            }
            if (ShowsInspector)
            {
                inspector = Math.Min(inspector, available - MinimumContentWidth - divider);
            }
        }

        SidebarWidth = sidebar;
        InspectorWidth = inspector;
    }

    private static double Clamp(double value, double min, double max, double fallback)
    {
        double finite = double.IsFinite(value) ? value : fallback;
        return Math.Min(max, Math.Max(min, finite));
    }
}

public enum NoticeSeverity
{
    Information,
    Success,
    Warning,
    Error
}

public enum NoticeAction
{
    RetryFolder,
    RetryRender,
    ShowInFinder,
    ShowScanIssues,
    ShowMetadataDetails
}

public sealed record UserNotice(
    Guid Id,
    string Title,
    string Message,
    NoticeSeverity Severity,
    IReadOnlyList<NoticeAction> Actions)
{
    public UserNotice(
        string title,
        string message,
        NoticeSeverity severity,
        IReadOnlyList<NoticeAction>? actions = null)
        : this(Guid.NewGuid(), title, message, severity, actions ?? Array.Empty<NoticeAction>())
    {
    }
}

public sealed class NoticePresentationState
{
    public UserNotice? Banner { get; private set; }
    public UserNotice? Toast { get; private set; }

    public void PresentBanner(UserNotice notice) => Banner = notice;
    public void PresentToast(UserNotice notice) => Toast = notice;

    public bool DismissBanner(Guid id)
    {
        if (Banner?.Id != id) return false;
        Banner = null;
        return true;
    }

    public bool DismissToast(Guid id)
    {
        if (Toast?.Id != id) return false;
        Toast = null;
        return true;
    }

    public void ClearBanner() => Banner = null;
    public void ClearToast() => Toast = null;
    public void Clear()
    {
        Banner = null;
        Toast = null;
    }
}
