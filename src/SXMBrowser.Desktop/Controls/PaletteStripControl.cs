using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Services;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Controls;

public sealed class PaletteStripControl : Control
{
    public static readonly StyledProperty<PaletteName> PaletteProperty =
        AvaloniaProperty.Register<PaletteStripControl, PaletteName>(nameof(Palette), PaletteName.Gwyddion);

    public static readonly StyledProperty<bool> InvertProperty =
        AvaloniaProperty.Register<PaletteStripControl, bool>(nameof(Invert), false);

    private WriteableBitmap? _cachedBitmap;
    private PaletteName _cachedPalette;
    private bool _cachedInvert;

    public PaletteName Palette
    {
        get => GetValue(PaletteProperty);
        set => SetValue(PaletteProperty, value);
    }

    public bool Invert
    {
        get => GetValue(InvertProperty);
        set => SetValue(InvertProperty, value);
    }

    static PaletteStripControl()
    {
        AffectsRender<PaletteStripControl>(PaletteProperty, InvertProperty);
    }

    public PaletteStripControl()
    {
        Height = 14;
    }

    public override void Render(DrawingContext context)
    {
        Rect rect = new(Bounds.Size);
        if (rect.Width <= 0 || rect.Height <= 0) return;

        if (_cachedBitmap is null || _cachedPalette != Palette || _cachedInvert != Invert)
        {
            _cachedBitmap?.Dispose();
            _cachedBitmap = BitmapBridge.CreatePaletteSwatchBitmap(Palette, width: 128, height: 4, invert: Invert);
            _cachedPalette = Palette;
            _cachedInvert = Invert;
        }

        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        context.DrawImage(_cachedBitmap, rect);
        context.DrawRectangle(null, new Pen(theme.HairlineBorderBrush, 1.0), rect.Deflate(0.5), 3.0, 3.0);
    }
}
