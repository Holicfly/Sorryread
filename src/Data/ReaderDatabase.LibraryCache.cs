using Microsoft.Data.Sqlite;

namespace ReadAI;

public sealed partial class ReaderDatabase
{
    public event EventHandler? LibraryChapterCacheChanged;

    // One local chapter per book. This cache is independent of URL parsing records and sync.
    public void SaveLibraryChapterCache(string bookKey, string chapterUrl, PageParseResult page)
    {
        if (!page.IsContentReady || string.IsNullOrWhiteSpace(page.Text)) return;
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO LibraryChapterCache(BookKey,ChapterUrl,Title,Content,PreviousUrl,NextUrl,CachedUtc)
            VALUES($book,$url,$title,$content,$previous,$next,$time)
            ON CONFLICT(BookKey) DO UPDATE SET ChapterUrl=excluded.ChapterUrl,Title=excluded.Title,
                Content=excluded.Content,PreviousUrl=excluded.PreviousUrl,NextUrl=excluded.NextUrl,
                CachedUtc=excluded.CachedUtc;
            """;
        command.Parameters.AddWithValue("$book", bookKey);
        command.Parameters.AddWithValue("$url", chapterUrl);
        command.Parameters.AddWithValue("$title", page.Title);
        command.Parameters.AddWithValue("$content", page.Text);
        command.Parameters.AddWithValue("$previous", page.PreviousUrl);
        command.Parameters.AddWithValue("$next", page.NextUrl);
        command.Parameters.AddWithValue("$time", DateTime.UtcNow.ToString("O"));
        command.ExecuteNonQuery();
        LibraryChapterCacheChanged?.Invoke(this, EventArgs.Empty);
    }

    public PageParseResult? GetLibraryChapterCache(LibraryBookEntry book)
        => GetLibraryChapterCache(book.BookKey, book.ChapterUrl);

    public PageParseResult? GetLatestLibraryChapterCache(string bookKey)
        => GetLibraryChapterCache(bookKey, chapterUrl: null);

    private PageParseResult? GetLibraryChapterCache(string bookKey, string? chapterUrl)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            SELECT Title,Content,PreviousUrl,NextUrl,ChapterUrl FROM LibraryChapterCache
            WHERE BookKey=$book AND ($url IS NULL OR ChapterUrl=$url) AND CachedUtc >= $cutoff;
            """;
        command.Parameters.AddWithValue("$book", bookKey);
        command.Parameters.AddWithValue("$url", (object?)chapterUrl ?? DBNull.Value);
        command.Parameters.AddWithValue("$cutoff", DateTime.UtcNow.AddDays(-15).ToString("O"));
        using SqliteDataReader reader = command.ExecuteReader();
        if (!reader.Read() || string.IsNullOrWhiteSpace(reader.GetString(1))) return null;
        return new PageParseResult
        {
            Title = reader.GetString(0), Text = reader.GetString(1),
            PreviousUrl = reader.GetString(2), NextUrl = reader.GetString(3),
            SourceUrl = reader.GetString(4), IsContentReady = true
        };
    }
}
