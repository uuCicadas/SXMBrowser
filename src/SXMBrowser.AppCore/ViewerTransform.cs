using System;

namespace SXMBrowser.AppCore;

public readonly record struct ViewerPoint
{
    public double X { get; }
    public double Y { get; }

    public ViewerPoint(double x, double y)
    {
        X = double.IsFinite(x) ? x : 0.0;
        Y = double.IsFinite(y) ? y : 0.0;
    }

    public static readonly ViewerPoint Zero = new(0.0, 0.0);
}

public readonly record struct ViewerSize
{
    public double Width { get; }
    public double Height { get; }

    public ViewerSize(double width, double height)
    {
        Width = double.IsFinite(width) && width > 0.0 ? width : 0.0;
        Height = double.IsFinite(height) && height > 0.0 ? height : 0.0;
    }

    public static readonly ViewerSize Zero = new(0.0, 0.0);
    public bool IsUsable => Width > 0.0 && Height > 0.0;
    public ViewerPoint Center => new(Width / 2.0, Height / 2.0);
}

public enum ViewerScaleMode
{
    Fit,
    Custom
}

public struct ViewerTransform : IEquatable<ViewerTransform>
{
    public const double MinimumCustomScale = 0.25;
    public const double MaximumCustomScale = 16.0;

    public ViewerSize ImageSize { get; private set; }
    public ViewerSize ViewportSize { get; private set; }
    public ViewerScaleMode Mode { get; private set; }
    public double Scale { get; private set; }
    public ViewerPoint Translation { get; private set; }

    public ViewerTransform(ViewerSize imageSize, ViewerSize viewportSize)
    {
        ImageSize = imageSize;
        ViewportSize = viewportSize;
        Mode = ViewerScaleMode.Fit;
        Scale = 1.0;
        Translation = ViewerPoint.Zero;
        ApplyFit();
    }

    public static ViewerTransform CreateDefault() => new(ViewerSize.Zero, ViewerSize.Zero);

    public double ZoomPercentage => Scale * 100.0;

    public static double? FitScale(ViewerSize imageSize, ViewerSize viewportSize)
    {
        if (!imageSize.IsUsable || !viewportSize.IsUsable) return null;
        double required = Math.Min(
            viewportSize.Width / imageSize.Width,
            viewportSize.Height / imageSize.Height);
        if (!double.IsFinite(required) || required <= 0.0) return null;
        return Math.Min(required, MaximumCustomScale);
    }

    public void Fit()
    {
        Mode = ViewerScaleMode.Fit;
        ApplyFit();
    }

    public void ShowActualSize(ViewerPoint? anchor = null)
    {
        SetCustomScale(1.0, anchor);
    }

    public void SetCustomScale(double requestedScale, ViewerPoint? anchor = null)
    {
        if (double.IsNaN(requestedScale)) return;
        double nextScale = Math.Min(MaximumCustomScale, Math.Max(MinimumCustomScale, requestedScale));
        ViewerPoint resolvedAnchor = ConstrainedViewportPoint(anchor ?? ViewportSize.Center);
        ViewerPoint? anchoredImagePoint = ImagePoint(resolvedAnchor);

        Mode = ViewerScaleMode.Custom;
        Scale = nextScale;
        Translation = anchoredImagePoint is { } pt
            ? new ViewerPoint(resolvedAnchor.X - pt.X * Scale, resolvedAnchor.Y - pt.Y * Scale)
            : CenteredTranslation();
        ConstrainTranslation();
    }

    public void Zoom(double factor, ViewerPoint anchor)
    {
        if (!double.IsFinite(factor) || factor <= 0.0) return;
        SetCustomScale(Scale * factor, anchor);
    }

    public void Pan(ViewerPoint delta)
    {
        if (!ImageSize.IsUsable || !ViewportSize.IsUsable)
        {
            Translation = ViewerPoint.Zero;
            return;
        }
        Translation = new ViewerPoint(
            FiniteSum(Translation.X, delta.X, Translation.X),
            FiniteSum(Translation.Y, delta.Y, Translation.Y));
        ConstrainTranslation();
    }

    public void Reconcile(ViewerSize newImageSize, ViewerSize newViewportSize)
    {
        ViewerPoint? preservedImagePoint = Mode == ViewerScaleMode.Custom
            && ImageSize.IsUsable
            && ViewportSize.IsUsable
            ? ImagePoint(ViewportSize.Center)
            : null;

        ImageSize = newImageSize;
        ViewportSize = newViewportSize;

        if (Mode == ViewerScaleMode.Fit)
        {
            ApplyFit();
            return;
        }

        Scale = ClampedCustomScale(Scale);
        if (!ImageSize.IsUsable || !ViewportSize.IsUsable)
        {
            Translation = ViewerPoint.Zero;
            return;
        }

        ViewerPoint pt = ConstrainedImagePoint(preservedImagePoint ?? ImageSize.Center);
        Translation = new ViewerPoint(
            ViewportSize.Center.X - pt.X * Scale,
            ViewportSize.Center.Y - pt.Y * Scale);
        ConstrainTranslation();
    }

    public ViewerPoint? ImagePoint(ViewerPoint viewportPoint)
    {
        if (!ImageSize.IsUsable || !ViewportSize.IsUsable || !double.IsFinite(Scale) || Scale <= 0.0)
        {
            return null;
        }
        return new ViewerPoint(
            (viewportPoint.X - Translation.X) / Scale,
            (viewportPoint.Y - Translation.Y) / Scale);
    }

    public ViewerPoint? ViewportPoint(ViewerPoint imagePoint)
    {
        if (!ImageSize.IsUsable || !ViewportSize.IsUsable || !double.IsFinite(Scale) || Scale <= 0.0)
        {
            return null;
        }
        return new ViewerPoint(
            imagePoint.X * Scale + Translation.X,
            imagePoint.Y * Scale + Translation.Y);
    }

    private static double ClampedCustomScale(double value) =>
        double.IsNaN(value) ? 1.0 : Math.Min(MaximumCustomScale, Math.Max(MinimumCustomScale, value));

    private void ApplyFit()
    {
        double? fitted = FitScale(ImageSize, ViewportSize);
        if (fitted is null)
        {
            Scale = 1.0;
            Translation = ViewerPoint.Zero;
            return;
        }
        Scale = fitted.Value;
        Translation = CenteredTranslation();
        ConstrainTranslation();
    }

    private ViewerPoint CenteredTranslation()
    {
        if (!ImageSize.IsUsable || !ViewportSize.IsUsable) return ViewerPoint.Zero;
        return new ViewerPoint(
            (ViewportSize.Width - ImageSize.Width * Scale) / 2.0,
            (ViewportSize.Height - ImageSize.Height * Scale) / 2.0);
    }

    private void ConstrainTranslation()
    {
        if (!ImageSize.IsUsable || !ViewportSize.IsUsable || !double.IsFinite(Scale) || Scale <= 0.0)
        {
            Translation = ViewerPoint.Zero;
            return;
        }
        Translation = new ViewerPoint(
            ConstrainedAxisTranslation(Translation.X, ImageSize.Width, ViewportSize.Width, Scale),
            ConstrainedAxisTranslation(Translation.Y, ImageSize.Height, ViewportSize.Height, Scale));
    }

    private static double ConstrainedAxisTranslation(
        double proposed,
        double imageLength,
        double viewportLength,
        double scale)
    {
        double scaledImageLength = imageLength * scale;
        if (scaledImageLength <= viewportLength)
        {
            return (viewportLength - scaledImageLength) / 2.0;
        }
        double minimum = viewportLength - scaledImageLength;
        double finiteProposed = double.IsFinite(proposed) ? proposed : 0.0;
        return Math.Min(0.0, Math.Max(minimum, finiteProposed));
    }

    private ViewerPoint ConstrainedViewportPoint(ViewerPoint point)
    {
        if (!ViewportSize.IsUsable) return ViewerPoint.Zero;
        return new ViewerPoint(
            Math.Min(ViewportSize.Width, Math.Max(0.0, point.X)),
            Math.Min(ViewportSize.Height, Math.Max(0.0, point.Y)));
    }

    private ViewerPoint ConstrainedImagePoint(ViewerPoint point)
    {
        if (!ImageSize.IsUsable) return ViewerPoint.Zero;
        return new ViewerPoint(
            Math.Min(ImageSize.Width, Math.Max(0.0, point.X)),
            Math.Min(ImageSize.Height, Math.Max(0.0, point.Y)));
    }

    private static double FiniteSum(double lhs, double rhs, double fallback)
    {
        double sum = lhs + rhs;
        return double.IsFinite(sum) ? sum : fallback;
    }

    public bool Equals(ViewerTransform other) =>
        ImageSize.Equals(other.ImageSize)
        && ViewportSize.Equals(other.ViewportSize)
        && Mode == other.Mode
        && Scale == other.Scale
        && Translation.Equals(other.Translation);

    public override bool Equals(object? obj) => obj is ViewerTransform other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(ImageSize, ViewportSize, Mode, Scale, Translation);
}
