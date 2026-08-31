namespace ReadAI;

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

    public static string CreateBookKey(string sourceId, string detailUrl)
    {
        string normalizedSourceId = sourceId.Trim().ToLowerInvariant();
        string normalizedDetailUrl = detailUrl.Trim().TrimEnd('/');
        return $"{normalizedSourceId}|{normalizedDetailUrl}";
    }
}
