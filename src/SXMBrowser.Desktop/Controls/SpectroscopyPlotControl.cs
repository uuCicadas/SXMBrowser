using System;
using System.Collections.Generic;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using SXMBrowser.AppCore;
using SXMBrowser.Core;
using SXMBrowser.Desktop.Theme;

namespace SXMBrowser.Desktop.Controls;

public sealed class SpectroscopyPlotControl : Control
{
    private sealed record PlottedSeries(
        SpectroscopyFile Spectrum,
        SpectrumVisualStyle Style,
        double[] X,
        double[] Y);

    private PresentedSpectroscopyGroup? _presentation;
    private AxisSelection? _axisSelection;
    private Guid? _focusedSpectrumId;
    private bool _isCompact;
    private List<PlottedSeries> _series = [];
    private double _minX, _maxX, _minY, _maxY;
    private Point? _hoverPoint;

    public bool IsCompact
    {
        get => _isCompact;
        set
        {
            _isCompact = value;
            InvalidateVisual();
        }
    }

    public Action<Guid>? OnSpectrumClicked { get; set; }

    public SpectroscopyPlotControl()
    {
        ClipToBounds = true;
        ActualThemeVariantChanged += (_, _) => InvalidateVisual();
    }

    public void UpdatePlot(
        PresentedSpectroscopyGroup? presentation,
        AxisSelection? axisSelection,
        Guid? focusedSpectrumId)
    {
        _presentation = presentation;
        _axisSelection = axisSelection;
        _focusedSpectrumId = focusedSpectrumId;
        RebuildSeries();
        InvalidateVisual();
    }

    private void RebuildSeries()
    {
        _series.Clear();
        if (_presentation is null || _presentation.VisibleSpectra.Count == 0)
        {
            _minX = _maxX = _minY = _maxY = 0.0;
            return;
        }

        string xCol = _axisSelection?.XColumn ?? _presentation.Group.XLabel;
        string yCol = _axisSelection?.YColumn ?? _presentation.Group.YLabel;

        var indexById = new Dictionary<Guid, int>(_presentation.AllSpectra.Count);
        for (int i = 0; i < _presentation.AllSpectra.Count; i++)
        {
            indexById[_presentation.AllSpectra[i].Id] = i;
        }

        double minX = double.PositiveInfinity;
        double maxX = double.NegativeInfinity;
        double minY = double.PositiveInfinity;
        double maxY = double.NegativeInfinity;

        foreach (SpectroscopyFile spectrum in _presentation.VisibleSpectra)
        {
            (double[] X, double[] Y)? cols = _presentation.Group.ColumnSeries(spectrum, xCol, yCol);
            double[] xs = cols?.X ?? spectrum.Curve.X;
            double[] ys = cols?.Y ?? spectrum.Curve.Y;
            int n = Math.Min(xs.Length, ys.Length);
            if (n < 2) continue;

            for (int i = 0; i < n; i++)
            {
                double x = xs[i];
                double y = ys[i];
                if (!double.IsFinite(x) || !double.IsFinite(y)) continue;
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }

            int idx = indexById.TryGetValue(spectrum.Id, out int found) ? found : 0;
            _series.Add(new PlottedSeries(spectrum, SpectrumVisualStyle.ForIndex(idx), xs, ys));
        }

        if (!double.IsFinite(minX) || !double.IsFinite(maxX))
        {
            _minX = 0.0;
            _maxX = 1.0;
        }
        else if (maxX == minX)
        {
            double pad = Math.Max(1e-12, Math.Abs(minX) * 0.05);
            _minX = minX - pad;
            _maxX = maxX + pad;
        }
        else
        {
            _minX = minX;
            _maxX = maxX;
        }

        if (!double.IsFinite(minY) || !double.IsFinite(maxY))
        {
            _minY = 0.0;
            _maxY = 1.0;
        }
        else if (maxY == minY)
        {
            double pad = Math.Max(1e-12, Math.Abs(minY) * 0.05);
            _minY = minY - pad;
            _maxY = maxY + pad;
        }
        else
        {
            double margin = (maxY - minY) * 0.06;
            _minY = minY - margin;
            _maxY = maxY + margin;
        }
    }

    private Rect PlotBounds()
    {
        if (_isCompact)
        {
            return new Rect(
                10.0,
                8.0,
                Math.Max(1.0, Bounds.Width - 20.0),
                Math.Max(1.0, Bounds.Height - 16.0));
        }

        const double leftMargin = 60.0;
        const double rightMargin = 16.0;
        const double topMargin = 12.0;
        const double bottomMargin = 32.0;
        return new Rect(
            leftMargin,
            topMargin,
            Math.Max(1.0, Bounds.Width - leftMargin - rightMargin),
            Math.Max(1.0, Bounds.Height - topMargin - bottomMargin));
    }

    private Point DataToScreen(double x, double y, Rect plot)
    {
        double fx = (x - _minX) / Math.Max(1e-30, _maxX - _minX);
        double fy = (y - _minY) / Math.Max(1e-30, _maxY - _minY);
        return new Point(
            plot.Left + fx * plot.Width,
            plot.Bottom - fy * plot.Height);
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (_isCompact || _series.Count == 0) return;
        Point pt = e.GetPosition(this);
        Rect plot = PlotBounds();
        _hoverPoint = plot.Contains(pt) ? pt : null;
        InvalidateVisual();
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        if (_hoverPoint is not null)
        {
            _hoverPoint = null;
            InvalidateVisual();
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (_isCompact || _series.Count == 0 || OnSpectrumClicked is null) return;

        Point pt = e.GetPosition(this);
        Rect plot = PlotBounds();
        if (!plot.Contains(pt)) return;

        Guid? closestId = null;
        double closestDistSq = double.PositiveInfinity;
        foreach (PlottedSeries s in _series)
        {
            int n = Math.Min(s.X.Length, s.Y.Length);
            for (int i = 0; i < n; i++)
            {
                if (!double.IsFinite(s.X[i]) || !double.IsFinite(s.Y[i])) continue;
                Point sp = DataToScreen(s.X[i], s.Y[i], plot);
                double dx = sp.X - pt.X;
                double dy = sp.Y - pt.Y;
                double d2 = dx * dx + dy * dy;
                if (d2 < closestDistSq)
                {
                    closestDistSq = d2;
                    closestId = s.Spectrum.Id;
                }
            }
        }

        if (closestId is { } id && closestDistSq <= 24.0 * 24.0)
        {
            OnSpectrumClicked.Invoke(id);
            e.Handled = true;
        }
    }

    public override void Render(DrawingContext context)
    {
        Rect outer = new(Bounds.Size);
        if (outer.Width <= 4 || outer.Height <= 4) return;

        AppThemePalette theme = AppTheme.Resolve(ActualThemeVariant);
        context.FillRectangle(theme.PlotCanvasBackgroundBrush, outer, _isCompact ? 6.0f : 4.0f);

        Rect plot = PlotBounds();
        if (plot.Width <= 2 || plot.Height <= 2) return;

        if (_series.Count == 0)
        {
            var ft = new FormattedText(
                "No visible curves",
                CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight,
                Typeface.Default,
                11,
                theme.TextMutedBrush);
            context.DrawText(ft, new Point(outer.Center.X - ft.Width / 2.0, outer.Center.Y - ft.Height / 2.0));
            return;
        }

        IReadOnlyList<ScientificAxisTick> xTicks = ScientificPlotTicks.Ticks(_minX, _maxX, _isCompact ? 3 : 5);
        IReadOnlyList<ScientificAxisTick> yTicks = ScientificPlotTicks.Ticks(_minY, _maxY, _isCompact ? 3 : 4);

        var gridPen = new Pen(theme.PlotMajorGridBrush, 1.0);
        foreach (ScientificAxisTick tick in xTicks)
        {
            double x = plot.Left + tick.Fraction * plot.Width;
            context.DrawLine(gridPen, new Point(x, plot.Top), new Point(x, plot.Bottom));
        }
        foreach (ScientificAxisTick tick in yTicks)
        {
            double y = plot.Bottom - tick.Fraction * plot.Height;
            context.DrawLine(gridPen, new Point(plot.Left, y), new Point(plot.Right, y));
        }

        // Zero axes if in range
        var zeroPen = new Pen(theme.PlotZeroLineBrush, 1.0);
        if (_minX < 0.0 && _maxX > 0.0)
        {
            double zx = DataToScreen(0.0, _minY, plot).X;
            context.DrawLine(zeroPen, new Point(zx, plot.Top), new Point(zx, plot.Bottom));
        }
        if (_minY < 0.0 && _maxY > 0.0)
        {
            double zy = DataToScreen(_minX, 0.0, plot).Y;
            context.DrawLine(zeroPen, new Point(plot.Left, zy), new Point(plot.Right, zy));
        }

        // Plot border
        context.DrawRectangle(null, new Pen(theme.PlotBorderBrush, 1.0), plot);

        // Curves (draw focused last so it always sits on top)
        bool hasFocus = _focusedSpectrumId is not null;
        using (context.PushClip(plot))
        {
            foreach (int pass in new[] { 0, 1 })
            {
                foreach (PlottedSeries s in _series)
                {
                    bool isFocused = _focusedSpectrumId == s.Spectrum.Id;
                    if ((pass == 0 && isFocused) || (pass == 1 && !isFocused)) continue;

                    Color baseColor = theme.CurveColor(s.Style);
                    byte alpha = hasFocus && !isFocused ? (byte)135 : (byte)255;
                    var brush = new SolidColorBrush(Color.FromArgb(alpha, baseColor.R, baseColor.G, baseColor.B));
                    DashStyle? dashStyle = s.Style.Pattern.DashLengths.Length > 0
                        ? new DashStyle(s.Style.Pattern.DashLengths, 0.0)
                        : null;
                    double thickness = _isCompact ? 1.3 : (isFocused ? 2.4 : 1.5);
                    var pen = new Pen(brush, thickness, dashStyle, PenLineCap.Round, PenLineJoin.Round);

                    var geometry = new StreamGeometry();
                    using (StreamGeometryContext ctx = geometry.Open())
                    {
                        bool started = false;
                        int n = Math.Min(s.X.Length, s.Y.Length);
                        for (int i = 0; i < n; i++)
                        {
                            double x = s.X[i];
                            double y = s.Y[i];
                            if (!double.IsFinite(x) || !double.IsFinite(y))
                            {
                                if (started)
                                {
                                    ctx.EndFigure(false);
                                    started = false;
                                }
                                continue;
                            }
                            Point sp = DataToScreen(x, y, plot);
                            if (!started)
                            {
                                ctx.BeginFigure(sp, isFilled: false);
                                started = true;
                            }
                            else
                            {
                                ctx.LineTo(sp);
                            }
                        }
                        if (started)
                        {
                            ctx.EndFigure(false);
                        }
                    }

                    context.DrawGeometry(null, pen, geometry);
                }
            }
        }

        if (!_isCompact)
        {
            // Draw axis ticks and titles
            foreach (ScientificAxisTick tick in xTicks)
            {
                double x = plot.Left + tick.Fraction * plot.Width;
                var ft = new FormattedText(
                    tick.Label,
                    CultureInfo.InvariantCulture,
                    FlowDirection.LeftToRight,
                    Typeface.Default,
                    10,
                    theme.PlotAxisTextBrush);
                double tx = Math.Min(plot.Right - ft.Width, Math.Max(plot.Left, x - ft.Width / 2.0));
                context.DrawText(ft, new Point(tx, plot.Bottom + 3.0));
            }

            foreach (ScientificAxisTick tick in yTicks)
            {
                double y = plot.Bottom - tick.Fraction * plot.Height;
                var ft = new FormattedText(
                    tick.Label,
                    CultureInfo.InvariantCulture,
                    FlowDirection.LeftToRight,
                    Typeface.Default,
                    10,
                    theme.PlotAxisTextBrush);
                double ty = Math.Min(plot.Bottom - ft.Height, Math.Max(plot.Top, y - ft.Height / 2.0));
                context.DrawText(ft, new Point(Math.Max(2.0, plot.Left - ft.Width - 6.0), ty));
            }

            string xTitle = _axisSelection?.XColumn ?? _presentation?.Group.XLabel ?? "";
            if (!string.IsNullOrEmpty(xTitle))
            {
                var xft = new FormattedText(
                    xTitle,
                    CultureInfo.InvariantCulture,
                    FlowDirection.LeftToRight,
                    Typeface.Default,
                    10.5,
                    theme.TextSecondaryBrush);
                context.DrawText(xft, new Point(plot.Center.X - xft.Width / 2.0, outer.Bottom - xft.Height - 2.0));
            }

            if (_hoverPoint is { } hp)
            {
                double fx = (hp.X - plot.Left) / Math.Max(1.0, plot.Width);
                double fy = (plot.Bottom - hp.Y) / Math.Max(1.0, plot.Height);
                double vx = _minX + fx * (_maxX - _minX);
                double vy = _minY + fy * (_maxY - _minY);
                string badge = $"({ScientificFormatters.FormatCompactNumber(vx)}, {ScientificFormatters.FormatCompactNumber(vy)})";
                var bft = new FormattedText(
                    badge,
                    CultureInfo.InvariantCulture,
                    FlowDirection.LeftToRight,
                    Typeface.Default,
                    10.5,
                    theme.TextPrimaryBrush);
                var pill = new Rect(plot.Right - bft.Width - 14.0, plot.Top + 6.0, bft.Width + 10.0, bft.Height + 4.0);
                context.FillRectangle(theme.PlotBadgeBackgroundBrush, pill, 4.0f);
                context.DrawText(bft, new Point(pill.X + 5.0, pill.Y + 2.0));
            }
        }
    }
}
