using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace SXMBrowser.Core;

public static class NaturalStringComparer
{
    public static readonly IComparer<string> Instance =
        CultureInfo.InvariantCulture.CompareInfo.GetStringComparer(
            CompareOptions.NumericOrdering | CompareOptions.IgnoreCase);

    public static int CompareFilenamesAndPaths(string leftPath, string rightPath)
    {
        string leftName = Path.GetFileName(leftPath);
        string rightName = Path.GetFileName(rightPath);
        int nameOrder = Instance.Compare(leftName, rightName);
        if (nameOrder != 0)
        {
            return nameOrder;
        }
        return string.CompareOrdinal(
            Path.GetFullPath(leftPath),
            Path.GetFullPath(rightPath));
    }

    public static int CompareFilenames(string leftName, string rightName) =>
        Instance.Compare(leftName, rightName);
}

internal static class TextSplitHelpers
{
    private static readonly char[] NewlineChars =
        ['\r', '\n', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];

    public static IEnumerable<string> SplitNonEmptyLines(string text)
    {
        int start = 0;
        int len = text.Length;
        while (start < len)
        {
            while (start < len && IsNewline(text[start]))
            {
                start++;
            }
            if (start >= len) yield break;
            int end = start;
            while (end < len && !IsNewline(text[end]))
            {
                end++;
            }
            yield return text[start..end];
            start = end;
        }
    }

    public static string[] SplitWhitespace(string text)
    {
        var result = new List<string>();
        int i = 0;
        int len = text.Length;
        while (i < len)
        {
            while (i < len && char.IsWhiteSpace(text[i])) i++;
            if (i >= len) break;
            int start = i;
            while (i < len && !char.IsWhiteSpace(text[i])) i++;
            result.Add(text[start..i]);
        }
        return result.ToArray();
    }

    public static string JoinWhitespaceNormalized(string text)
    {
        return string.Join(' ', SplitWhitespace(text));
    }

    private static bool IsNewline(char c) => Array.IndexOf(NewlineChars, c) >= 0;
}
