using System;
using System.Collections.Generic;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Controls;

/// <summary>
/// Zoomable, pannable single-image scientific scan canvas supporting nearest-neighbor pixel
/// inspection above 100%, NaN missing-data checkerboard, interactive .dat markers, and physical scale bar.
/// </summary>
public sealed class SingleImageCanvasControl : Control
{
    private readonly record struct MarkerHit(Guid SpectrumId, Point ScreenCenter);

    private WriteableBitmap? _bitmap;
    private PixelSize? _lastNotifiedBitmapSize;
    private SXMMetadata? _metadata;
    private IReadOnlyList<(SpectroscopyFile Spectrum, int IndexInGroup)> _markerSpectra =
        Array.Empty<(SpectroscopyFile, int)>();
    private Guid? _focusedSpectrumId;
    private ViewerTransform _transform = ViewerTransform.CreateDefault();
    private readonly List<MarkerHit> _markerHits = [];

    private bool _isDragging;
    private bool _didPan;
    private Point _lastPointerPoint;

    public Action<ViewerSize, ViewerSize>? OnGeometryChanged { get; set; }
    public Action<double, ViewerPoint>? OnZoom { get; set; }
    public Action<ViewerPoint>? OnPan { get; set; }
    public Action<ViewerPoint>? OnToggleFitActual { get; set; }
    public Action<Guid>? OnMarkerClicked { get; set; }

    public SingleImageCanvasControl()
    {
        ClipToBounds = true;
        ActualThemeVariantChanged += (_, _) => InvalidateVisual();
    }

    public void UpdateScene(
        WriteableBitmap? bitmap,
        SXMMetadata? metadata,
        ViewerTransform transform,
        IReadOnlyList<(SpectroscopyFile Spectrum, int IndexInGroup)> markerSpectra,
        Guid? focusedSpectrumId)
    {
        _bitmap = bitmap;
        _metadata = metadata;
        _transform = transform;
        _markerSpectra = markerSpectra;
        _focusedSpectrumId = focusedSpectrumId;
        if (bitmap is not null && bitmap.PixelSize != _lastNotifiedBitmapSize && Bounds.Width > 0 && Bounds.Height > 0)
        {
            _lastNotifiedBitmapSize = bitmap.PixelSize;
            NotifyGeometry();
        }
        InvalidateVisual();
    }

    protected override void OnSizeChanged(SizeChangedEventArgs e)
    {
        base.OnSizeChanged(e);
        NotifyGeometry();
    }

    private void NotifyGeometry()
    {
        if (_bitmap is null) return;
        OnGeometryChanged?.Invoke(
            new ViewerSize(_bitmap.PixelSize.Width, _bitmap.PixelSize.Height),
            new ViewerSize(Bounds.Width, Bounds.Height));
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        if (_bitmap is null) return;
        double delta = e.Delta.Y;
        if (Math.Abs(delta) < 1e-6) return;
        double factor = delta > 0 ? Math.Pow(1.15, Math.Min(3.0, delta)) : 1.0 / Math.Pow(1.15, Math.Min(3.0, -delta));
        Point pos = e.GetPosition(this);
        OnZoom?.Invoke(factor, new ViewerPoint(pos.X, pos.Y));
        e.Handled = true;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        Point pos = e.GetPosition(this);

        if (e.ClickCount >= 2)
        {
            OnToggleFitActual?.Invoke(new ViewerPoint(pos.X, pos.Y));
            e.Handled = true;
            return;
        }

        if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            _isDragging = true;
            _didPan = false;
            _lastPointerPoint = pos;
            e.Pointer.Capture(this);
            e.Handled = true;
        }
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (!_isDragging) return;
        Point pos = e.GetPosition(this);
        double dx = pos.X - _lastPointerPoint.X;
        double dy = pos.Y - _lastPointerPoint.Y;
        if (_didPan || dx * dx + dy * dy >= 9.0)
        {
            _didPan = true;
            _lastPointerPoint = pos;
            OnPan?.Invoke(new ViewerPoint(dx, dy));
        }
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (!_isDragging) return;
        Point pos = e.GetPosition(this);
        bool wasClick = !_didPan;
        _isDragging = false;
        _didPan = false;
        if (Equals(e.Pointer.Captured, this))
        {
            e.Pointer.Capture(null);
        }

        if (wasClick)
        {
            Guid? hitMarker = HitTestMarker(pos);
            if (hitMarker is { } markerId)
            {
                OnMarkerClicked?.Invoke(markerId);
            }
        }
        e.Handled = true;
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        _isDragging = false;
        _didPan = false;
    }

    private Guid? HitTestMarker(Point pos)
    {
        Guid? best = null;
        double bestDistSq = 14.0 * 14.0;
        foreach (MarkerHit m in _markerHits)
        {
            double dx = m.ScreenCenter.X - pos.X;
            double dy = m.ScreenCenter.Y - pos.Y;
            double d2 = dx * dx + dy * dy;
            if (d2 <= bestDistSq)
            {
                bestDistSq = d2;
                best = m.SpectrumId;
            }
        }
        return best;
    }

    public override void Render(DrawingContext context)
    {
        Rect viewport = new(Bounds.Size);
        if (viewport.Width <= 0 || viewport.Height <= 0) return;

        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        context.FillRectangle(theme.ImageWellBrush, viewport);

        if (_bitmap is null || _metadata is null) return;

        double imgW = _bitmap.PixelSize.Width;
        double imgH = _bitmap.PixelSize.Height;
        double drawW = imgW * _transform.Scale;
        double drawH = imgH * _transform.Scale;
        var destRect = new Rect(_transform.Translation.X, _transform.Translation.Y, drawW, drawH);

        MissingDataBackdropControl.DrawCheckerboard(context, destRect, 10.0, theme);

        BitmapInterpolationMode interp = _transform.Scale > 1.001
            ? BitmapInterpolationMode.None
            : BitmapInterpolationMode.HighQuality;
        using (context.PushRenderOptions(new Avalonia.Media.RenderOptions { BitmapInterpolationMode = interp }))
        {
            context.DrawImage(_bitmap, new Rect(0, 0, imgW, imgH), destRect);
        }

        context.DrawRectangle(null, new Pen(theme.HairlineBorderBrush, 1.0), destRect);

        DrawSpectroscopyMarkers(context, theme, imgW, imgH);
        DrawScaleBarOverlay(context, theme, viewport);
    }

    private void DrawSpectroscopyMarkers(
        DrawingContext context,
        AppThemePalette theme,
        double imgW,
        double imgH)
    {
        _markerHits.Clear();
        if (_metadata is null || _markerSpectra.Count == 0 || _metadata.ScanRange is not { } range)
        {
            return;
        }

        (double offsetX, double offsetY) = _metadata.ScanOffset ?? (0.0, 0.0);
        ScanCoordinateTransform? coordTransform = ScanCoordinateTransform.TryCreate(
            range.X,
            range.Y,
            offsetX,
            offsetY,
            _metadata.ScanAngle ?? 0.0,
            _metadata.ScanDir);
        if (coordTransform is null) return;

        for (int i = 0; i < _markerSpectra.Count; i++)
        {
            (SpectroscopyFile spectrum, int indexInGroup) = _markerSpectra[i];
            if (spectrum.Position is not { } pos) continue;
            PhysicalScanCoordinate? phys = PhysicalScanCoordinate.TryCreate(pos.X, pos.Y);
            if (phys is null) continue;
            NormalizedScanCoordinate? norm = coordTransform.NormalizedCoordinate(phys.Value);
            if (norm is null) continue;

            ViewerPoint? vp = _transform.ViewportPoint(new ViewerPoint(norm.Value.U * imgW, norm.Value.V * imgH));
            if (vp is null) continue;

            var center = new Point(vp.Value.X, vp.Value.Y);
            _markerHits.Add(new MarkerHit(spectrum.Id, center));

            bool isFocused = _focusedSpectrumId == spectrum.Id;
            SpectrumVisualStyle style = SpectrumVisualStyle.ForIndex(indexInGroup);
            Color c = theme.CurveColor(style);

            double radius = isFocused ? 7.0 : 5.5;
            var haloBrush = new SolidColorBrush(Color.FromArgb(isFocused ? (byte)240 : (byte)190, 18, 20, 24));
            var markerBrush = new SolidColorBrush(c);
            context.DrawEllipse(haloBrush, new Pen(Brushes.White, isFocused ? 2.0 : 1.3), center, radius + 1.5, radius + 1.5);
            context.DrawEllipse(markerBrush, null, center, radius - 1.5, radius - 1.5);
        }
    }

    private void DrawScaleBarOverlay(
        DrawingContext context,
        AppThemePalette theme,
        Rect viewport)
    {
        if (_metadata?.ScanRange is not { } range || _bitmap is null) return;
        ScaleBar? bar = ScaleBar.Resolve(
            range.X,
            _bitmap.PixelSize.Width,
            _transform,
            Math.Max(1.0, viewport.Width - 36.0));
        if (bar is null) return;

        var label = new FormattedText(
            bar.Label,
            CultureInfo.InvariantCulture,
            FlowDirection.LeftToRight,
            new Typeface(FontFamily.Default, FontStyle.Normal, FontWeight.SemiBold),
            11.5,
            theme.TextPrimaryBrush);

        double pillW = Math.Max(bar.ScreenLengthPoints + 20.0, label.Width + 20.0);
        double pillH = label.Height + 18.0;
        var pillRect = new Rect(
            viewport.Right - pillW - 16.0,
            viewport.Bottom - pillH - 16.0,
            pillW,
            pillH);

        context.FillRectangle(theme.PlotBadgeBackgroundBrush, pillRect, 6.0f);
        context.DrawRectangle(null, new Pen(theme.HairlineBorderBrush, 1.0), pillRect, 6.0, 6.0);

        context.DrawText(label, new Point(pillRect.Center.X - label.Width / 2.0, pillRect.Top + 4.0));

        double lineY = pillRect.Bottom - 7.0;
        double lineStartX = pillRect.Center.X - bar.ScreenLengthPoints / 2.0;
        double lineEndX = lineStartX + bar.ScreenLengthPoints;
        var barPen = new Pen(theme.TextPrimaryBrush, 2.2, lineCap: PenLineCap.Square);
        context.DrawLine(barPen, new Point(lineStartX, lineY), new Point(lineEndX, lineY));
        context.DrawLine(barPen, new Point(lineStartX, lineY - 2.5), new Point(lineStartX, lineY + 2.5));
        context.DrawLine(barPen, new Point(lineEndX, lineY - 2.5), new Point(lineEndX, lineY + 2.5));
    }
}
