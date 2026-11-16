using System;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using SXMBrowser.Core;

namespace SXMBrowser.Desktop.Services;

public static class BitmapBridge
{
    public static WriteableBitmap CreateWriteableBitmap(RenderedImage image)
    {
        int width = Math.Max(1, image.Width);
        int height = Math.Max(1, image.Height);
        var bitmap = new WriteableBitmap(
            new PixelSize(width, height),
            new Vector(96.0, 96.0),
            PixelFormat.Rgba8888,
            AlphaFormat.Unpremul);

        using ILockedFramebuffer fb = bitmap.Lock();
        int rowBytes = width * 4;
        for (int y = 0; y < height; y++)
        {
            int srcOffset = y * rowBytes;
            if (srcOffset + rowBytes > image.RgbaBytes.Length) break;
            Marshal.Copy(image.RgbaBytes, srcOffset, fb.Address + y * fb.RowBytes, rowBytes);
        }

        return bitmap;
    }

    public static WriteableBitmap CreatePaletteSwatchBitmap(
        PaletteName palette,
        int width = 42,
        int height = 13,
        bool invert = false)
    {
        int w = Math.Max(2, width);
        int h = Math.Max(1, height);
        PaletteLookup lookup = PaletteStore.Shared.Lookup(palette);

        byte[] row = new byte[w * 4];
        for (int x = 0; x < w; x++)
        {
            double t = (double)x / (w - 1);
            if (invert) t = 1.0 - t;
            (double r, double g, double b) = lookup.ColorAt(t);
            int offset = x * 4;
            row[offset] = ToByte(r);
            row[offset + 1] = ToByte(g);
            row[offset + 2] = ToByte(b);
            row[offset + 3] = 255;
        }

        var bitmap = new WriteableBitmap(
            new PixelSize(w, h),
            new Vector(96.0, 96.0),
            PixelFormat.Rgba8888,
            AlphaFormat.Unpremul);

        using ILockedFramebuffer fb = bitmap.Lock();
        for (int y = 0; y < h; y++)
        {
            Marshal.Copy(row, 0, fb.Address + y * fb.RowBytes, row.Length);
        }

        return bitmap;
    }

    private static byte ToByte(double v)
    {
        double clamped = Math.Min(1.0, Math.Max(0.0, double.IsFinite(v) ? v : 0.0));
        return (byte)Math.Round(clamped * 255.0, MidpointRounding.AwayFromZero);
    }
}
