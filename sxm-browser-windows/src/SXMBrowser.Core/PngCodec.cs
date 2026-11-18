using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace SXMBrowser.Core;

/// <summary>
/// Dependency-free RGBA8888 PNG encoder and reader writing explicit sRGB / gAMA / cHRM chunks.
/// </summary>
public static class PngCodec
{
    private static readonly byte[] PngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    private static readonly uint[] Crc32Table = BuildCrcTable();

    public static byte[] EncodeRgba8888(int width, int height, ReadOnlySpan<byte> rgbaBytes)
    {
        if (width <= 0 || height <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(width), "PNG dimensions must be positive.");
        }
        int expectedLength = checked(width * height * 4);
        if (rgbaBytes.Length < expectedLength)
        {
            throw new ArgumentException("RGBA buffer is shorter than width * height * 4.", nameof(rgbaBytes));
        }

        using var ms = new MemoryStream(Math.Max(1024, expectedLength / 2));
        ms.Write(PngSignature);

        // IHDR: 8-bit RGBA (color type 6)
        Span<byte> ihdr = stackalloc byte[13];
        BinaryPrimitives.WriteInt32BigEndian(ihdr[0..4], width);
        BinaryPrimitives.WriteInt32BigEndian(ihdr[4..8], height);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 6; // color type RGBA
        ihdr[10] = 0; // compression method
        ihdr[11] = 0; // filter method
        ihdr[12] = 0; // interlace none
        WriteChunk(ms, "IHDR"u8, ihdr);

        // Explicit sRGB chunk (Perceptual intent = 0)
        Span<byte> srgb = [0];
        WriteChunk(ms, "sRGB"u8, srgb);

        // Standard sRGB gAMA (1 / 2.2 * 100000 = 45455)
        Span<byte> gama = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(gama, 45455u);
        WriteChunk(ms, "gAMA"u8, gama);

        // Standard sRGB cHRM (white 0.3127,0.3290; R 0.64,0.33; G 0.30,0.60; B 0.15,0.06)
        Span<byte> chrm = stackalloc byte[32];
        BinaryPrimitives.WriteUInt32BigEndian(chrm[0..4], 31270u);
        BinaryPrimitives.WriteUInt32BigEndian(chrm[4..8], 32900u);
        BinaryPrimitives.WriteUInt32BigEndian(chrm[8..12], 64000u);
        BinaryPrimitives.WriteUInt32BigEndian(chrm[12..16], 33000u);
        BinaryPrimitives.WriteUInt32BigEndian(chrm[16..20], 30000u);
        BinaryPrimitives.WriteUInt32BigEndian(chrm[20..24], 60000u);
        BinaryPrimitives.WriteUInt32BigEndian(chrm[24..28], 15000u);
        BinaryPrimitives.WriteUInt32BigEndian(chrm[28..32], 6000u);
        WriteChunk(ms, "cHRM"u8, chrm);

        // IDAT: zlib-compressed scanlines with Sub filter (1) or None (0)
        int stride = width * 4;
        byte[] compressedIdat;
        using (var idatStream = new MemoryStream(Math.Max(256, expectedLength / 2)))
        {
            using (var zlib = new ZLibStream(idatStream, CompressionLevel.Fastest, leaveOpen: true))
            {
                byte[] rowBuf = new byte[1 + stride];
                rowBuf[0] = 0; // Filter type 0 (None) — very fast and clean
                for (int y = 0; y < height; y++)
                {
                    rgbaBytes.Slice(y * stride, stride).CopyTo(rowBuf.AsSpan(1));
                    zlib.Write(rowBuf, 0, rowBuf.Length);
                }
            }
            compressedIdat = idatStream.ToArray();
        }
        WriteChunk(ms, "IDAT"u8, compressedIdat);

        // IEND
        WriteChunk(ms, "IEND"u8, ReadOnlySpan<byte>.Empty);
        return ms.ToArray();
    }

    public static (int Width, int Height, bool HasSrgbChunk, byte[] RgbaBytes) DecodeRgba8888(ReadOnlySpan<byte> pngBytes)
    {
        if (pngBytes.Length < 8 || !pngBytes[0..8].SequenceEqual(PngSignature))
        {
            throw new InvalidDataException("Invalid PNG signature.");
        }

        int offset = 8;
        int width = 0;
        int height = 0;
        bool sawIhdr = false;
        bool hasSrgb = false;
        using var idat = new MemoryStream();

        while (offset + 12 <= pngBytes.Length)
        {
            uint chunkLen = BinaryPrimitives.ReadUInt32BigEndian(pngBytes.Slice(offset, 4));
            ReadOnlySpan<byte> type = pngBytes.Slice(offset + 4, 4);
            offset += 8;
            if (offset + (long)chunkLen + 4 > pngBytes.Length)
            {
                throw new InvalidDataException("Truncated PNG chunk.");
            }
            ReadOnlySpan<byte> payload = pngBytes.Slice(offset, (int)chunkLen);
            offset += (int)chunkLen + 4; // skip payload + CRC

            if (type.SequenceEqual("IHDR"u8))
            {
                width = BinaryPrimitives.ReadInt32BigEndian(payload[0..4]);
                height = BinaryPrimitives.ReadInt32BigEndian(payload[4..8]);
                if (payload[8] != 8 || payload[9] != 6)
                {
                    throw new NotSupportedException("Only 8-bit RGBA PNG decoding is supported.");
                }
                sawIhdr = true;
            }
            else if (type.SequenceEqual("sRGB"u8))
            {
                hasSrgb = true;
            }
            else if (type.SequenceEqual("IDAT"u8))
            {
                idat.Write(payload);
            }
            else if (type.SequenceEqual("IEND"u8))
            {
                break;
            }
        }

        if (!sawIhdr || width <= 0 || height <= 0)
        {
            throw new InvalidDataException("PNG missing valid IHDR.");
        }

        idat.Position = 0;
        int stride = width * 4;
        byte[] rgba = new byte[height * stride];
        byte[] rowBuf = new byte[1 + stride];
        byte[] prevRow = new byte[stride];

        using (var zlib = new ZLibStream(idat, CompressionMode.Decompress))
        {
            for (int y = 0; y < height; y++)
            {
                int read = 0;
                while (read < rowBuf.Length)
                {
                    int n = zlib.Read(rowBuf, read, rowBuf.Length - read);
                    if (n <= 0) throw new InvalidDataException("Truncated IDAT stream.");
                    read += n;
                }
                byte filter = rowBuf[0];
                Span<byte> cur = rgba.AsSpan(y * stride, stride);
                ReadOnlySpan<byte> src = rowBuf.AsSpan(1, stride);
                switch (filter)
                {
                    case 0:
                        src.CopyTo(cur);
                        break;
                    case 1:
                        for (int i = 0; i < stride; i++)
                        {
                            byte a = i >= 4 ? cur[i - 4] : (byte)0;
                            cur[i] = unchecked((byte)(src[i] + a));
                        }
                        break;
                    case 2:
                        for (int i = 0; i < stride; i++)
                        {
                            cur[i] = unchecked((byte)(src[i] + prevRow[i]));
                        }
                        break;
                    case 3:
                        for (int i = 0; i < stride; i++)
                        {
                            int a = i >= 4 ? cur[i - 4] : 0;
                            int b = prevRow[i];
                            cur[i] = unchecked((byte)(src[i] + ((a + b) >> 1)));
                        }
                        break;
                    case 4:
                        for (int i = 0; i < stride; i++)
                        {
                            byte a = i >= 4 ? cur[i - 4] : (byte)0;
                            byte b = prevRow[i];
                            byte c = i >= 4 ? prevRow[i - 4] : (byte)0;
                            cur[i] = unchecked((byte)(src[i] + Paeth(a, b, c)));
                        }
                        break;
                    default:
                        throw new InvalidDataException($"Unsupported PNG filter {filter}.");
                }
                cur.CopyTo(prevRow);
            }
        }

        return (width, height, hasSrgb, rgba);
    }

    private static byte Paeth(byte a, byte b, byte c)
    {
        int p = a + b - c;
        int pa = Math.Abs(p - a);
        int pb = Math.Abs(p - b);
        int pc = Math.Abs(p - c);
        if (pa <= pb && pa <= pc) return a;
        return pb <= pc ? b : c;
    }

    private static void WriteChunk(Stream output, ReadOnlySpan<byte> type, ReadOnlySpan<byte> data)
    {
        Span<byte> lenBytes = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(lenBytes, (uint)data.Length);
        output.Write(lenBytes);
        output.Write(type);
        output.Write(data);

        uint crc = UpdateCrc(0xFFFFFFFFu, type);
        crc = UpdateCrc(crc, data) ^ 0xFFFFFFFFu;
        Span<byte> crcBytes = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(crcBytes, crc);
        output.Write(crcBytes);
    }

    private static uint UpdateCrc(uint crc, ReadOnlySpan<byte> data)
    {
        foreach (byte b in data)
        {
            crc = Crc32Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        }
        return crc;
    }

    private static uint[] BuildCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++)
            {
                c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            }
            table[n] = c;
        }
        return table;
    }
}
