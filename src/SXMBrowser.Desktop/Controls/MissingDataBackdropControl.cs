using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Controls;

public sealed class MissingDataBackdropControl : Control
{
    public static readonly StyledProperty<double> TileSizeProperty =
        AvaloniaProperty.Register<MissingDataBackdropControl, double>(nameof(TileSize), 8.0);

    public double TileSize
    {
        get => GetValue(TileSizeProperty);
        set => SetValue(TileSizeProperty, value);
    }

    static MissingDataBackdropControl()
    {
        AffectsRender<MissingDataBackdropControl>(TileSizeProperty);
    }

    public MissingDataBackdropControl()
    {
        ActualThemeVariantChanged += (_, _) => InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        Rect bounds = new(Bounds.Size);
        if (bounds.Width <= 0 || bounds.Height <= 0) return;

        AppThemePalette palette = AppTheme.Resolve(ActualThemeVariant);
        DrawCheckerboard(context, bounds, TileSize, palette);
    }

    public static void DrawCheckerboard(
        DrawingContext context,
        Rect rect,
        double tileSize,
        AppThemePalette palette)
    {
        double size = tileSize > 1.0 ? tileSize : 8.0;
        context.FillRectangle(palette.MissingDataBaseBrush, rect);

        using var _ = context.PushClip(rect);
        int cols = (int)System.Math.Ceiling(rect.Width / size);
        int rows = (int)System.Math.Ceiling(rect.Height / size);
        for (int row = 0; row < rows; row++)
        {
            int startCol = row & 1;
            double y = rect.Y + row * size;
            for (int col = startCol; col < cols; col += 2)
            {
                double x = rect.X + col * size;
                context.FillRectangle(palette.MissingDataAltBrush, new Rect(x, y, size, size));
            }
        }
    }
}
