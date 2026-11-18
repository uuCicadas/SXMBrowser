using System;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Controls;

/// <summary>
/// Interactive contrast histogram with log-scaled distribution bars and stepless
/// draggable Min / Max / Window handles.
/// </summary>
public sealed class HistogramControl : Control
{
    private enum DragMode
    {
        None,
        MinHandle,
        MaxHandle,
        WindowShift,
        SweepNewWindow
    }

    private HistogramStats? _stats;
    private double? _scaleMin;
    private double? _scaleMax;
    private DragMode _dragMode = DragMode.None;
    private Point _dragStartPoint;
    private double _dragInitialMin;
    private double _dragInitialMax;
    private double _dragAnchorValue;
    private double? _hoverFraction;

    public Action<double, double>? OnScaleChanged { get; set; }
    public Action? OnResetScale { get; set; }

    public HistogramControl()
    {
        Height = 128;
        ClipToBounds = true;
        Cursor = new Cursor(StandardCursorType.SizeWestEast);
        ActualThemeVariantChanged += (_, _) => InvalidateVisual();
    }

    public void UpdateData(HistogramStats? stats, double? scaleMin, double? scaleMax)
    {
        _stats = stats;
        _scaleMin = scaleMin;
        _scaleMax = scaleMax;
        InvalidateVisual();
    }

    private Rect PlotRect()
    {
        const double padX = 6.0;
        const double padY = 8.0;
        return new Rect(
            padX,
            padY,
            Math.Max(1.0, Bounds.Width - 2.0 * padX),
            Math.Max(1.0, Bounds.Height - 2.0 * padY));
    }

    private (double DataMin, double DataMax, double ActiveMin, double ActiveMax)? ResolvedDomain()
    {
        if (_stats is not { } stats) return null;
        double dMin = stats.Min;
        double dMax = stats.Max;
        if (!double.IsFinite(dMin) || !double.IsFinite(dMax)) return null;
        double aMin = _scaleMin is { } sm && double.IsFinite(sm) ? sm : dMin;
        double aMax = _scaleMax is { } sx && double.IsFinite(sx) ? sx : dMax;
        if (aMax < aMin) (aMin, aMax) = (aMax, aMin);
        return (dMin, dMax, aMin, aMax);
    }

    private double ValueToX(double value, double dataMin, double dataMax, Rect plot)
    {
        double span = dataMax - dataMin;
        if (span <= 0.0) return plot.Center.X;
        double frac = Math.Min(1.0, Math.Max(0.0, (value - dataMin) / span));
        return plot.Left + frac * plot.Width;
    }

    private double XToValue(double x, double dataMin, double dataMax, Rect plot)
    {
        double frac = Math.Min(1.0, Math.Max(0.0, (x - plot.Left) / Math.Max(1.0, plot.Width)));
        return dataMin + frac * (dataMax - dataMin);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (e.ClickCount >= 2)
        {
            _dragMode = DragMode.None;
            OnResetScale?.Invoke();
            e.Handled = true;
            return;
        }

        if (ResolvedDomain() is not { } dom || dom.DataMax <= dom.DataMin) return;

        Point pt = e.GetPosition(this);
        Rect plot = PlotRect();
        double xMin = ValueToX(dom.ActiveMin, dom.DataMin, dom.DataMax, plot);
        double xMax = ValueToX(dom.ActiveMax, dom.DataMin, dom.DataMax, plot);

        const double hitTolerance = 9.0;
        double distMin = Math.Abs(pt.X - xMin);
        double distMax = Math.Abs(pt.X - xMax);

        _dragStartPoint = pt;
        _dragInitialMin = dom.ActiveMin;
        _dragInitialMax = dom.ActiveMax;
        _dragAnchorValue = XToValue(pt.X, dom.DataMin, dom.DataMax, plot);

        if (distMin <= hitTolerance && distMin <= distMax)
        {
            _dragMode = DragMode.MinHandle;
        }
        else if (distMax <= hitTolerance)
        {
            _dragMode = DragMode.MaxHandle;
        }
        else if (pt.X > xMin + hitTolerance && pt.X < xMax - hitTolerance)
        {
            _dragMode = DragMode.WindowShift;
        }
        else
        {
            _dragMode = DragMode.SweepNewWindow;
        }

        e.Pointer.Capture(this);
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        Point pt = e.GetPosition(this);
        Rect plot = PlotRect();

        if (_dragMode == DragMode.None)
        {
            double frac = Math.Min(1.0, Math.Max(0.0, (pt.X - plot.Left) / Math.Max(1.0, plot.Width)));
            _hoverFraction = plot.Contains(pt) ? frac : null;
            InvalidateVisual();
            return;
        }

        if (ResolvedDomain() is not { } dom || dom.DataMax <= dom.DataMin) return;
        double totalSpan = dom.DataMax - dom.DataMin;
        double minSeparation = totalSpan * 1e-4;
        double pointerValue = XToValue(pt.X, dom.DataMin, dom.DataMax, plot);

        double nextMin = dom.ActiveMin;
        double nextMax = dom.ActiveMax;

        switch (_dragMode)
        {
            case DragMode.MinHandle:
                nextMin = Math.Min(_dragInitialMax - minSeparation, Math.Max(dom.DataMin, pointerValue));
                nextMax = _dragInitialMax;
                break;

            case DragMode.MaxHandle:
                nextMin = _dragInitialMin;
                nextMax = Math.Max(_dragInitialMin + minSeparation, Math.Min(dom.DataMax, pointerValue));
                break;

            case DragMode.WindowShift:
            {
                double windowSpan = Math.Max(minSeparation, _dragInitialMax - _dragInitialMin);
                double dxVal = ((pt.X - _dragStartPoint.X) / Math.Max(1.0, plot.Width)) * totalSpan;
                double shiftedMin = _dragInitialMin + dxVal;
                shiftedMin = Math.Min(dom.DataMax - windowSpan, Math.Max(dom.DataMin, shiftedMin));
                nextMin = shiftedMin;
                nextMax = shiftedMin + windowSpan;
                break;
            }

            case DragMode.SweepNewWindow:
            {
                double lo = Math.Min(_dragAnchorValue, pointerValue);
                double hi = Math.Max(_dragAnchorValue, pointerValue);
                if (hi - lo < minSeparation)
                {
                    hi = Math.Min(dom.DataMax, lo + minSeparation);
                }
                nextMin = lo;
                nextMax = hi;
                break;
            }
        }

        if (nextMax > nextMin)
        {
            _scaleMin = nextMin;
            _scaleMax = nextMax;
            InvalidateVisual();
            OnScaleChanged?.Invoke(nextMin, nextMax);
        }
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (_dragMode != DragMode.None)
        {
            _dragMode = DragMode.None;
            if (Equals(e.Pointer.Captured, this))
            {
                e.Pointer.Capture(null);
            }
            InvalidateVisual();
            e.Handled = true;
        }
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        _dragMode = DragMode.None;
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        _hoverFraction = null;
        InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        Rect outer = new(Bounds.Size);
        if (outer.Width <= 2 || outer.Height <= 2) return;

        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        context.FillRectangle(theme.PlotCanvasBackgroundBrush, outer, 6.0f);
        context.DrawRectangle(null, new Pen(theme.PlotBorderBrush, 1.0), outer.Deflate(0.5), 6.0, 6.0);

        Rect plot = PlotRect();
        if (_stats is not { } stats || stats.Bins <= 0)
        {
            var emptyText = new FormattedText(
                "No histogram data",
                CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight,
                Typeface.Default,
                11,
                theme.TextMutedBrush);
            context.DrawText(
                emptyText,
                new Point(
                    outer.Center.X - emptyText.Width / 2.0,
                    outer.Center.Y - emptyText.Height / 2.0));
            return;
        }

        // Subtle horizontal gridlines
        var gridPen = new Pen(theme.PlotMajorGridBrush, 1.0);
        for (int g = 1; g <= 3; g++)
        {
            double gy = plot.Top + plot.Height * (g / 4.0);
            context.DrawLine(gridPen, new Point(plot.Left, gy), new Point(plot.Right, gy));
        }

        int[] counts = stats.Hist;
        double maxLog = 0.0;
        foreach (int c in counts)
        {
            double l = Math.Log(1.0 + Math.Max(0, c));
            if (l > maxLog) maxLog = l;
        }
        if (maxLog <= 0.0) maxLog = 1.0;

        double barWidth = plot.Width / counts.Length;
        var fillGeometry = new StreamGeometry();
        var strokeGeometry = new StreamGeometry();
        using (StreamGeometryContext fCtx = fillGeometry.Open())
        using (StreamGeometryContext sCtx = strokeGeometry.Open())
        {
            fCtx.BeginFigure(new Point(plot.Left, plot.Bottom), isFilled: true);
            for (int i = 0; i < counts.Length; i++)
            {
                double hFrac = Math.Log(1.0 + Math.Max(0, counts[i])) / maxLog;
                double yTop = plot.Bottom - hFrac * (plot.Height - 4.0);
                double x0 = plot.Left + i * barWidth;
                double x1 = x0 + barWidth;
                if (i == 0)
                {
                    sCtx.BeginFigure(new Point(x0, yTop), isFilled: false);
                }
                else
                {
                    sCtx.LineTo(new Point(x0, yTop));
                }
                sCtx.LineTo(new Point(x1, yTop));

                fCtx.LineTo(new Point(x0, yTop));
                fCtx.LineTo(new Point(x1, yTop));
            }
            fCtx.LineTo(new Point(plot.Right, plot.Bottom));
            fCtx.EndFigure(isClosed: true);
            sCtx.EndFigure(isClosed: false);
        }

        context.DrawGeometry(theme.HistogramBarFillBrush, null, fillGeometry);
        context.DrawGeometry(null, new Pen(theme.HistogramBarStrokeBrush, 1.35), strokeGeometry);

        if (ResolvedDomain() is { } dom)
        {
            double xMin = ValueToX(dom.ActiveMin, dom.DataMin, dom.DataMax, plot);
            double xMax = ValueToX(dom.ActiveMax, dom.DataMin, dom.DataMax, plot);

            if (xMin > plot.Left)
            {
                context.FillRectangle(
                    theme.HistogramClipOverlayBrush,
                    new Rect(plot.Left, outer.Top + 1, xMin - plot.Left, outer.Height - 2));
            }
            if (xMax < plot.Right)
            {
                context.FillRectangle(
                    theme.HistogramClipOverlayBrush,
                    new Rect(xMax, outer.Top + 1, plot.Right - xMax, outer.Height - 2));
            }

            var handlePen = new Pen(theme.HistogramHandleStrokeBrush, 1.8);
            context.DrawLine(handlePen, new Point(xMin, outer.Top + 2), new Point(xMin, outer.Bottom - 2));
            context.DrawLine(handlePen, new Point(xMax, outer.Top + 2), new Point(xMax, outer.Bottom - 2));

            // Small top handle caps for visual affordance
            context.FillRectangle(theme.HistogramHandleStrokeBrush, new Rect(xMin - 3.5, outer.Top + 2, 7.0, 5.0), 1.5f);
            context.FillRectangle(theme.HistogramHandleStrokeBrush, new Rect(xMax - 3.5, outer.Top + 2, 7.0, 5.0), 1.5f);

            if (_hoverFraction is { } hf && dom.DataMax > dom.DataMin)
            {
                double hoverVal = dom.DataMin + hf * (dom.DataMax - dom.DataMin);
                string txt = ScientificFormatters.FormatCompactNumber(hoverVal);
                var ft = new FormattedText(
                    txt,
                    CultureInfo.InvariantCulture,
                    FlowDirection.LeftToRight,
                    Typeface.Default,
                    10,
                    theme.PlotAxisTextBrush);
                var pill = new Rect(outer.Right - ft.Width - 12, outer.Top + 4, ft.Width + 8, ft.Height + 2);
                context.FillRectangle(theme.PlotBadgeBackgroundBrush, pill, 3.0f);
                context.DrawText(ft, new Point(pill.X + 4, pill.Y + 1));
            }
        }
    }
}
