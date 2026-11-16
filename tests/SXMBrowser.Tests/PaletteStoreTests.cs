using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using SXMBrowser.Core;
using Xunit;

namespace SXMBrowser.Tests;

public sealed class PaletteStoreTests
{
    private static string PaletteFingerprint(PaletteName palette)
    {
        var stops = PaletteStore.Shared.Stops(palette);
        using var ms = new MemoryStream();
        using var bw = new BinaryWriter(ms);
        foreach (PaletteStop stop in stops)
        {
            bw.Write(stop.Position);
            bw.Write(stop.R);
            bw.Write(stop.G);
            bw.Write(stop.B);
        }
        bw.Flush();
        byte[] hash = SHA256.HashData(ms.ToArray());
        return Convert.ToHexStringLower(hash);
    }

    [Fact]
    public void AllFivePalettesLoadAndSpanZeroToOne()
    {
        Assert.Equal(5, SXMValueExtensions.AllPalettes.Count);
        foreach (PaletteName palette in SXMValueExtensions.AllPalettes)
        {
            var stops = PaletteStore.Shared.Stops(palette);
            Assert.True(stops.Count >= 2, $"Expected >=2 stops for {palette}");
            Assert.Equal(0.0, stops[0].Position);
            Assert.Equal(1.0, stops[^1].Position);
        }
    }

    [Fact]
    public void OriginalPalettesMatchExactMacOsSha256Fingerprints()
    {
        Assert.Equal(
            "eef29bb173702cd500a5668b6de08ace1f332bb0e0c6c0cde0c0f47c7c893528",
            PaletteFingerprint(PaletteName.BlueViolet));
        Assert.Equal(
            "5c48fafdc3d046448bb10d0388078288382730550bb655bb69419b0ee382dd08",
            PaletteFingerprint(PaletteName.DuskViolet));
        Assert.Equal(
            "b06bafb7097b0b0cfb6086354dbc40dacc8c9f58fcfa172362e560ff1a35be8d",
            PaletteFingerprint(PaletteName.Ember));
    }

    [Fact]
    public void GwyddionPaletteHasExactOfficialStopsAndNonUniformLookup()
    {
        PaletteLookup lookup = PaletteStore.Shared.Lookup(PaletteName.Gwyddion);
        Assert.False(lookup.IsUniformUnitGrid);
        Assert.Equal(4, lookup.Stops.Count);

        PaletteStop s0 = lookup.Stops[0];
        PaletteStop s1 = lookup.Stops[1];
        PaletteStop s2 = lookup.Stops[2];
        PaletteStop s3 = lookup.Stops[3];

        Assert.Equal((0.0, 0.0, 0.0, 0.0), (s0.Position, s0.R, s0.G, s0.B));
        Assert.Equal((0.344671, 0.658824, 0.156863, 0.0588235), (s1.Position, s1.R, s1.G, s1.B));
        Assert.Equal((0.687075, 0.953506, 0.759686, 0.363821), (s2.Position, s2.R, s2.G, s2.B));
        Assert.Equal((1.0, 1.0, 1.0, 1.0), (s3.Position, s3.R, s3.G, s3.B));

        (double r, double g, double b) = lookup.ColorAt(0.344671);
        Assert.Equal(0.658824, r, 10);
        Assert.Equal(0.156863, g, 10);
        Assert.Equal(0.0588235, b, 10);
    }

    [Fact]
    public void ChannelDefaultPaletteUsesGwyddionForStmAndGrayForAfm()
    {
        Assert.Equal(PaletteName.Gwyddion, SXMChannelRules.DefaultPalette("Z"));
        Assert.Equal(PaletteName.Gwyddion, SXMChannelRules.DefaultPalette("Current"));
        Assert.Equal(PaletteName.Gwyddion, SXMChannelRules.DefaultPalette("LI_Demod_1_X"));
        Assert.Equal(PaletteName.Gray, SXMChannelRules.DefaultPalette("OC_M1_Freq._Shift"));
        Assert.Equal(PaletteName.Gray, SXMChannelRules.DefaultPalette("Delta f"));
    }
}
