namespace ReadAI;

public static class SearchInputClassifier
{
    // 无协议的输入只接受明确的站点特征，避免把小说名、邮件地址或 .txt 文件名当作网址。
    private static readonly HashSet<string> CommonDomainSuffixes = new(StringComparer.OrdinalIgnoreCase)
    {
        "com", "net", "org", "cn", "cc", "la", "tw", "hk", "io", "co", "me",
        "info", "biz", "top", "xyz", "site", "online", "app", "dev", "edu", "gov",
        "vip", "club", "link", "book", "books", "fun", "mobi", "world"
    };

    public static bool TryGetHttpUrl(string input, out string url)
    {
        url = string.Empty;
        string value = input.Trim();
        bool explicitScheme = value.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
            value.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
        if (value.Length == 0 || value.Any(char.IsWhiteSpace)) return false;
        if (!explicitScheme && (value.Contains("://", StringComparison.Ordinal) || value.Contains('@')))
            return false;

        if (!Uri.TryCreate(explicitScheme ? value : $"https://{value}", UriKind.Absolute, out Uri? uri) ||
            uri.Host.Length == 0 || uri.HostNameType == UriHostNameType.Unknown ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            return false;
        }

        if (!explicitScheme && uri.HostNameType is not (UriHostNameType.IPv4 or UriHostNameType.IPv6))
        {
            string host = uri.IdnHost.TrimEnd('.');
            int separator = host.LastIndexOf('.');
            if (separator <= 0) return false;
            string suffix = host[(separator + 1)..];
            bool wwwDomain = host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) &&
                separator > "www.".Length && suffix.Length >= 2 && suffix.All(char.IsAsciiLetter);
            if (!wwwDomain && !CommonDomainSuffixes.Contains(suffix)) return false;
        }

        url = uri.AbsoluteUri;
        return true;
    }
}
