using System;
using System.Globalization;

namespace SXMBrowser.Core;

internal sealed class PosixDateParser
{
    private readonly string[] _formats;

    public PosixDateParser(params string[] formats)
    {
        _formats = formats;
    }

    public DateTimeOffset? Parse(string raw)
    {
        foreach (string format in _formats)
        {
            if (DateTime.TryParseExact(
                raw,
                format,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal,
                out DateTime parsed))
            {
                return new DateTimeOffset(parsed);
            }
        }
        return null;
    }
}
