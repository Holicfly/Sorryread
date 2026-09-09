namespace ReadAI;

public sealed class ReaderSettings
{
    public const int DefaultScrollDistance = 3;
    public const int MinimumScrollDistance = 1;
    public const int MaximumScrollDistance = 100;
    public int ScrollDistance { get; set; } = DefaultScrollDistance;
    public bool ScrollDistanceCustom { get; set; }

    public static int NormalizeScrollDistance(int value)
        => value is >= MinimumScrollDistance and <= MaximumScrollDistance ? value : DefaultScrollDistance;

    public double FontSize { get; set; } = 18;
    public string FontFamily { get; set; } = "Microsoft YaHei UI";
    public string AppTheme { get; set; } = "System";
    public string TextColor { get; set; } = string.Empty;
    public bool SearchHistoryEnabled { get; set; } = true;
    public bool TransparentMode { get; set; }
    public double WindowWidth { get; set; } = 520;
    public double WindowHeight { get; set; } = 180;
    public double WindowLeft { get; set; } = double.NaN;
    public double WindowTop { get; set; } = double.NaN;
    public string WindowState { get; set; } = "Normal";
    public string LastUrl { get; set; } = string.Empty;
}

public sealed class HistoryEntry
{
    public long Id { get; set; }
    public string Url { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public string PreviousUrl { get; set; } = string.Empty;
    public string NextUrl { get; set; } = string.Empty;
    public double Progress { get; set; }
    public DateTime CreatedUtc { get; set; }
    public DateTime LastReadUtc { get; set; }
    public DateTime LastParsedUtc { get; set; }
    public int ParseCount { get; set; } = 1;
    public string LocalPath { get; set; } = string.Empty;
    public string SourceId { get; set; } = string.Empty;
}

public sealed class PageParseResult
{
    public string Title { get; set; } = string.Empty;
    public string Text { get; set; } = string.Empty;
    public bool IsContentReady { get; set; }
    public string PreviousUrl { get; set; } = string.Empty;
    public string NextUrl { get; set; } = string.Empty;
    public string SourceUrl { get; set; } = string.Empty;
}

public sealed class NovelSearchResult
{
    public string SourceId { get; set; } = string.Empty;
    public string SourceName { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Url { get; set; } = string.Empty;
    public string Author { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string LatestChapter { get; set; } = string.Empty;
    public string LastUpdateTime { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string WordCount { get; set; } = string.Empty;
}

public sealed class NovelSearchPage
{
    public List<NovelSearchResult> Results { get; set; } = [];
    public bool HasNext { get; set; }
    public string NextPageUrl { get; set; } = string.Empty;
}

public sealed class NovelChapterItem
{
    public string Title { get; set; } = string.Empty;
    public string Url { get; set; } = string.Empty;
}

public sealed class BookSourceBookPage
{
    public string SourceId { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string DetailUrl { get; set; } = string.Empty;
    public List<NovelChapterItem> Chapters { get; set; } = [];

    public string FirstChapterUrl => Chapters.FirstOrDefault()?.Url ?? string.Empty;
}
