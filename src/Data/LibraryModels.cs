namespace ReadAI;

public enum LibraryScope
{
    Normal,
    Legacy18Mh
}

public sealed class LibraryBookEntry
{
    public string BookKey { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string SourceId { get; set; } = string.Empty;
    public string SourceName { get; set; } = string.Empty;
    public string DetailUrl { get; set; } = string.Empty;
    public string ChapterUrl { get; set; } = string.Empty;
    public string ChapterTitle { get; set; } = string.Empty;
    public double Progress { get; set; }
    public DateTime? LastReadUtc { get; set; }
    public DateTime? FavoriteUtc { get; set; }
    public string CatalogJson { get; set; } = string.Empty;

    public bool IsFavorite => FavoriteUtc.HasValue;

    // Keep desktop grouping consistent with the phone's ShelfBook.isSpecialSource,
    // including older synced metadata that identifies the source only by its URL.
    public static bool IsSpecialSource(string sourceId, string detailUrl)
    {
        string id = sourceId.Trim().ToLowerInvariant();
        if (id is "18mh" or "yeshe") return true;
        if (!Uri.TryCreate(detailUrl, UriKind.Absolute, out Uri? uri) ||
            uri.Scheme is not ("http" or "https")) return false;
        string host = uri.Host.ToLowerInvariant();
        return host == "18mh.net" || host.EndsWith(".18mh.net", StringComparison.Ordinal)
            || host == "yeshezy1.com";
    }

    public static string CreateBookKey(string sourceId, string detailUrl)
    {
        string normalizedSourceId = sourceId.Trim().ToLowerInvariant();
        string normalizedDetailUrl = detailUrl.Trim().TrimEnd('/');
        return $"{normalizedSourceId}|{normalizedDetailUrl}";
    }
}
