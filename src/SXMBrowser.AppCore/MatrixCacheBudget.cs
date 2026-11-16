using System;

namespace SXMBrowser.AppCore;

public static class MatrixCacheBudget
{
    public const int MaximumBytes = 512 * 1024 * 1024;

    public static int ByteLimit(ulong physicalMemoryBytes)
    {
        ulong oneEighth = physicalMemoryBytes / 8UL;
        ulong capped = Math.Min((ulong)MaximumBytes, oneEighth);
        return capped <= int.MaxValue ? (int)capped : int.MaxValue;
    }

    public static int DefaultByteLimit
    {
        get
        {
            long total = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
            return total > 0 ? ByteLimit((ulong)total) : 256 * 1024 * 1024;
        }
    }
}
