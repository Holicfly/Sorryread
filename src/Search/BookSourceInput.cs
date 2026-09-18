using System.Text.RegularExpressions;

namespace ReadAI;

public enum SearchInputScope
{
    Aggregated,
    BookSourceInput,
    Legacy18Mh
}

/// <summary>Parses an explicitly enabled source's book id or same-site link.</summary>
public static class BookSourceInput
{
    public static bool TryParse(BookSourceDefinition source, string input,
        out string bookId, out string detailUrl, out string targetChapterUrl)
    {
        bookId = detailUrl = targetChapterUrl = string.Empty;
        if (string.IsNullOrWhiteSpace(source.BookIdUriTemplate)) return false;
        input = input.Trim();
        if (input.Length == 0 || input.Any(c => c > 0x7f || char.IsControl(c))) return false;
        if (Regex.IsMatch(input, @"\A[0-9]+\z"))
        {
            bookId = input;
        }
        else
        {
            if (!Uri.TryCreate(input, UriKind.Absolute, out Uri? uri) ||
                uri.Scheme is not ("http" or "https") || !uri.IsDefaultPort ||
                uri.UserInfo.Length != 0 ||
                !string.Equals(uri.Host, source.BaseUri.Host, StringComparison.OrdinalIgnoreCase) ||
                string.IsNullOrWhiteSpace(source.Detail.BookUrlPattern)) return false;
            Match match = Regex.Match(uri.GetLeftPart(UriPartial.Path), source.Detail.BookUrlPattern,
                RegexOptions.IgnoreCase);
            if (!match.Success || match.Groups.Count < 2 ||
                !Regex.IsMatch(match.Groups[1].Value, @"\A[0-9]+\z")) return false;
            bookId = match.Groups[1].Value;
            targetChapterUrl = NormalizeChapterUrl(source, uri.AbsoluteUri);
        }
        detailUrl = source.BookIdUriTemplate.Replace("{bookId}", bookId, StringComparison.Ordinal);
        return true;
    }

    public static string NormalizeChapterUrl(BookSourceDefinition source, string url)
    {
        if (string.IsNullOrEmpty(source.InputChapterPathPattern) ||
            !Uri.TryCreate(url, UriKind.Absolute, out Uri? uri) ||
            !string.Equals(uri.Host, source.BaseUri.Host, StringComparison.OrdinalIgnoreCase)) return string.Empty;
        Match match = Regex.Match(uri.AbsolutePath, source.InputChapterPathPattern, RegexOptions.IgnoreCase);
        return match.Success ? new Uri(source.BaseUri, match.Groups["path"].Value + ".html").AbsoluteUri : string.Empty;
    }
}
