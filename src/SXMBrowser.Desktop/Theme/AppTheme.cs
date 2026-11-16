using Avalonia.Media;
using Avalonia.Styling;
using SXMBrowser.AppCore;

namespace SXMBrowser.Desktop.Theme;

public sealed record AppThemePalette(
    bool IsDark,
    Color GridStage,
    Color CardSurface,
    Color SelectedTile,
    Color ImageWell,
    Color ElevatedCard,
    Color TileBorder,
    Color HairlineBorder,
    Color TextPrimary,
    Color TextSecondary,
    Color TextMuted,
    Color Accent,
    Color AccentSubtle,
    Color Danger,
    Color Warning,
    Color Success,
    Color PlotCanvasBackground,
    Color PlotBorder,
    Color PlotMajorGrid,
    Color PlotZeroLine,
    Color PlotAxisText,
    Color PlotBadgeBackground,
    Color HistogramBarFill,
    Color HistogramBarStroke,
    Color HistogramClipOverlay,
    Color HistogramHandleStroke,
    Color MissingDataBase,
    Color MissingDataAlt,
    Color ToolbarSurface,
    Color SidebarSurface)
{
    public IBrush GridStageBrush { get; } = new SolidColorBrush(GridStage);
    public IBrush CardSurfaceBrush { get; } = new SolidColorBrush(CardSurface);
    public IBrush SelectedTileBrush { get; } = new SolidColorBrush(SelectedTile);
    public IBrush ImageWellBrush { get; } = new SolidColorBrush(ImageWell);
    public IBrush ElevatedCardBrush { get; } = new SolidColorBrush(ElevatedCard);
    public IBrush TileBorderBrush { get; } = new SolidColorBrush(TileBorder);
    public IBrush HairlineBorderBrush { get; } = new SolidColorBrush(HairlineBorder);
    public IBrush TextPrimaryBrush { get; } = new SolidColorBrush(TextPrimary);
    public IBrush TextSecondaryBrush { get; } = new SolidColorBrush(TextSecondary);
    public IBrush TextMutedBrush { get; } = new SolidColorBrush(TextMuted);
    public IBrush AccentBrush { get; } = new SolidColorBrush(Accent);
    public IBrush AccentSubtleBrush { get; } = new SolidColorBrush(AccentSubtle);
    public IBrush DangerBrush { get; } = new SolidColorBrush(Danger);
    public IBrush WarningBrush { get; } = new SolidColorBrush(Warning);
    public IBrush SuccessBrush { get; } = new SolidColorBrush(Success);
    public IBrush PlotCanvasBackgroundBrush { get; } = new SolidColorBrush(PlotCanvasBackground);
    public IBrush PlotBorderBrush { get; } = new SolidColorBrush(PlotBorder);
    public IBrush PlotMajorGridBrush { get; } = new SolidColorBrush(PlotMajorGrid);
    public IBrush PlotZeroLineBrush { get; } = new SolidColorBrush(PlotZeroLine);
    public IBrush PlotAxisTextBrush { get; } = new SolidColorBrush(PlotAxisText);
    public IBrush PlotBadgeBackgroundBrush { get; } = new SolidColorBrush(PlotBadgeBackground);
    public IBrush HistogramBarFillBrush { get; } = new SolidColorBrush(HistogramBarFill);
    public IBrush HistogramBarStrokeBrush { get; } = new SolidColorBrush(HistogramBarStroke);
    public IBrush HistogramClipOverlayBrush { get; } = new SolidColorBrush(HistogramClipOverlay);
    public IBrush HistogramHandleStrokeBrush { get; } = new SolidColorBrush(HistogramHandleStroke);
    public IBrush MissingDataBaseBrush { get; } = new SolidColorBrush(MissingDataBase);
    public IBrush MissingDataAltBrush { get; } = new SolidColorBrush(MissingDataAlt);
    public IBrush ToolbarSurfaceBrush { get; } = new SolidColorBrush(ToolbarSurface);
    public IBrush SidebarSurfaceBrush { get; } = new SolidColorBrush(SidebarSurface);

    public Color CurveColor(SpectrumVisualStyle style)
    {
        if (style.PaletteIndex == 6)
        {
            return IsDark
                ? Color.FromRgb(0xE0, 0xE6, 0xF0)
                : Color.FromRgb(0x00, 0x00, 0x00);
        }
        return Color.FromRgb(style.Color.Red, style.Color.Green, style.Color.Blue);
    }
}

public static class AppTheme
{
    public static readonly AppThemePalette Dark = new(
        IsDark: true,
        GridStage: Color.Parse("#1A1B1D"),
        CardSurface: Color.Parse("#28292C"),
        SelectedTile: Color.Parse("#1F3455"),
        ImageWell: Color.Parse("#17181B"),
        ElevatedCard: Color.Parse("#25272A"),
        TileBorder: Color.Parse("#1CFFFFFF"),
        HairlineBorder: Color.Parse("#1AFFFFFF"),
        TextPrimary: Color.Parse("#F3F4F6"),
        TextSecondary: Color.Parse("#B4BAC2"),
        TextMuted: Color.Parse("#808690"),
        Accent: Color.Parse("#5CBFFA"),
        AccentSubtle: Color.Parse("#285CBFFA"),
        Danger: Color.Parse("#F06A6A"),
        Warning: Color.Parse("#F5B841"),
        Success: Color.Parse("#5AD08E"),
        PlotCanvasBackground: Color.Parse("#16181C"),
        PlotBorder: Color.Parse("#3DFFFFFF"),
        PlotMajorGrid: Color.Parse("#17FFFFFF"),
        PlotZeroLine: Color.Parse("#42FFFFFF"),
        PlotAxisText: Color.Parse("#C2FFFFFF"),
        PlotBadgeBackground: Color.Parse("#E0202227"),
        HistogramBarFill: Color.Parse("#48E0B857"),
        HistogramBarStroke: Color.Parse("#FCD166"),
        HistogramClipOverlay: Color.Parse("#5C000000"),
        HistogramHandleStroke: Color.Parse("#5CBFFA"),
        MissingDataBase: Color.Parse("#222428"),
        MissingDataAlt: Color.Parse("#1B1D20"),
        ToolbarSurface: Color.Parse("#222428"),
        SidebarSurface: Color.Parse("#202226"));

    public static readonly AppThemePalette Light = new(
        IsDark: false,
        GridStage: Color.Parse("#F1F3F4"),
        CardSurface: Color.Parse("#FBFCFC"),
        SelectedTile: Color.Parse("#E7F0FC"),
        ImageWell: Color.Parse("#EDEFF1"),
        ElevatedCard: Color.Parse("#FDFDFE"),
        TileBorder: Color.Parse("#14000000"),
        HairlineBorder: Color.Parse("#17000000"),
        TextPrimary: Color.Parse("#181A1E"),
        TextSecondary: Color.Parse("#525866"),
        TextMuted: Color.Parse("#7B8290"),
        Accent: Color.Parse("#1976D2"),
        AccentSubtle: Color.Parse("#1F1976D2"),
        Danger: Color.Parse("#C93434"),
        Warning: Color.Parse("#B87900"),
        Success: Color.Parse("#1B8A53"),
        PlotCanvasBackground: Color.Parse("#FDFDFE"),
        PlotBorder: Color.Parse("#47000000"),
        PlotMajorGrid: Color.Parse("#14000000"),
        PlotZeroLine: Color.Parse("#38000000"),
        PlotAxisText: Color.Parse("#B8000000"),
        PlotBadgeBackground: Color.Parse("#E6F9FAFC"),
        HistogramBarFill: Color.Parse("#46D6A840"),
        HistogramBarStroke: Color.Parse("#B88A24"),
        HistogramClipOverlay: Color.Parse("#17000000"),
        HistogramHandleStroke: Color.Parse("#2485D6"),
        MissingDataBase: Color.Parse("#F1F2F4"),
        MissingDataAlt: Color.Parse("#E4E7EA"),
        ToolbarSurface: Color.Parse("#F6F7F9"),
        SidebarSurface: Color.Parse("#F4F5F7"));

    public static AppThemePalette Resolve(ThemeVariant? actualVariant) =>
        actualVariant == ThemeVariant.Dark ? Dark : Light;
}
