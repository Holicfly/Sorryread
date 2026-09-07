using Microsoft.Data.Sqlite;
using System.IO;

namespace ReadAI;

public sealed class ReaderDatabase : IDisposable
{
    public const int MaximumRecentLibraryBooks = 10;
    public const int MaximumFavoriteLibraryBooks = 50;
    public const int MaximumSearchHistoryEntries = 15;

    private readonly string _databasePath;
    private readonly string _connectionString;

    public ReaderDatabase(string databasePath)
    {
        _databasePath = databasePath;
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared
        }.ToString();
    }

    public void Initialize()
    {
        string? directory = Path.GetDirectoryName(_databasePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS Settings (
                Key TEXT PRIMARY KEY NOT NULL,
                Value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS History (
                Id INTEGER PRIMARY KEY AUTOINCREMENT,
                Url TEXT NOT NULL UNIQUE,
                Title TEXT NOT NULL,
                Content TEXT NOT NULL,
                PreviousUrl TEXT NOT NULL DEFAULT '',
                NextUrl TEXT NOT NULL DEFAULT '',
                Progress REAL NOT NULL DEFAULT 0,
                CreatedUtc TEXT NOT NULL,
                LastReadUtc TEXT NOT NULL,
                LastParsedUtc TEXT NOT NULL DEFAULT '',
                ParseCount INTEGER NOT NULL DEFAULT 1,
                LocalPath TEXT NOT NULL DEFAULT '',
                SourceId TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS IX_History_LastReadUtc ON History(LastReadUtc DESC);
            CREATE TABLE IF NOT EXISTS SearchHistory (
                Id INTEGER PRIMARY KEY AUTOINCREMENT,
                Mode TEXT NOT NULL,
                Keyword TEXT NOT NULL COLLATE NOCASE,
                SearchTimeUtc TEXT NOT NULL,
                UNIQUE(Mode, Keyword)
            );
            CREATE INDEX IF NOT EXISTS IX_SearchHistory_Mode_Id ON SearchHistory(Mode, Id DESC);
            CREATE TABLE IF NOT EXISTS LibraryBooks (
                BookKey TEXT PRIMARY KEY NOT NULL,
                Title TEXT NOT NULL,
                SourceId TEXT NOT NULL,
                SourceName TEXT NOT NULL,
                DetailUrl TEXT NOT NULL,
                ChapterUrl TEXT NOT NULL DEFAULT '',
                ChapterTitle TEXT NOT NULL DEFAULT '',
                Progress REAL NOT NULL DEFAULT 0,
                LastReadUtc TEXT NOT NULL DEFAULT '',
                FavoriteUtc TEXT NOT NULL DEFAULT '',
                CatalogJson TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS IX_LibraryBooks_LastReadUtc
                ON LibraryBooks(LastReadUtc DESC)
                WHERE LastReadUtc <> '';
            CREATE INDEX IF NOT EXISTS IX_LibraryBooks_FavoriteUtc
                ON LibraryBooks(FavoriteUtc DESC)
                WHERE FavoriteUtc <> '';
            """;
        command.ExecuteNonQuery();
        EnsureHistoryColumn(connection, "LastParsedUtc", "TEXT NOT NULL DEFAULT ''");
        EnsureHistoryColumn(connection, "ParseCount", "INTEGER NOT NULL DEFAULT 1");
        EnsureHistoryColumn(connection, "SourceId", "TEXT NOT NULL DEFAULT ''");

        using SqliteCommand migrateCommand = connection.CreateCommand();
        migrateCommand.CommandText = """
            UPDATE History
            SET LastParsedUtc = CreatedUtc
            WHERE LastParsedUtc IS NULL OR LastParsedUtc = '';

            UPDATE History
            SET ParseCount = 1
            WHERE ParseCount IS NULL OR ParseCount < 1;

            DELETE FROM Settings
            WHERE Key = 'Theme';

            CREATE INDEX IF NOT EXISTS IX_History_LastParsedUtc ON History(LastParsedUtc DESC);
            """;
        migrateCommand.ExecuteNonQuery();
    }

    public ReaderSettings LoadSettings()
    {
        Dictionary<string, string> values = new(StringComparer.OrdinalIgnoreCase);
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT Key, Value FROM Settings;";
        using SqliteDataReader reader = command.ExecuteReader();
        while (reader.Read())
        {
            values[reader.GetString(0)] = reader.GetString(1);
        }

        return new ReaderSettings
        {
            ScrollDistance = int.TryParse(ReadString(values, "ScrollDistance", string.Empty), out int scrollDistance)
                ? ReaderSettings.NormalizeScrollDistance(scrollDistance) : ReaderSettings.DefaultScrollDistance,
            ScrollDistanceCustom = ReadBool(values, "ScrollDistanceCustom", false),
            FontSize = ReadDouble(values, "FontSize", 18),
            FontFamily = ReadString(values, "FontFamily", "Microsoft YaHei UI"),
            AppTheme = ReadString(values, "AppTheme", "System"),
            TextColor = ReadString(values, "TextColor", string.Empty),
            SearchHistoryEnabled = ReadBool(values, "SearchHistoryEnabled", true),
            TransparentMode = ReadBool(values, "TransparentMode", false),
            WindowWidth = ReadDouble(values, "WindowWidth", 520),
            WindowHeight = ReadDouble(values, "WindowHeight", 180),
            WindowLeft = ReadDouble(values, "WindowLeft", double.NaN),
            WindowTop = ReadDouble(values, "WindowTop", double.NaN),
            WindowState = ReadString(values, "WindowState", "Normal"),
            LastUrl = ReadString(values, "LastUrl", string.Empty)
        };
    }

    public void SaveSettings(ReaderSettings settings)
    {
        SetSetting("ScrollDistance", ReaderSettings.NormalizeScrollDistance(settings.ScrollDistance).ToString(System.Globalization.CultureInfo.InvariantCulture));
        SetSetting("ScrollDistanceCustom", settings.ScrollDistanceCustom.ToString());
        SetSetting("FontSize", settings.FontSize.ToString(System.Globalization.CultureInfo.InvariantCulture));
        SetSetting("FontFamily", settings.FontFamily);
        SetSetting("AppTheme", settings.AppTheme);
        SetSetting("TextColor", settings.TextColor);
        SetSetting("SearchHistoryEnabled", settings.SearchHistoryEnabled.ToString());
        SetSetting("TransparentMode", settings.TransparentMode.ToString());
        SetSetting("WindowWidth", settings.WindowWidth.ToString(System.Globalization.CultureInfo.InvariantCulture));
        SetSetting("WindowHeight", settings.WindowHeight.ToString(System.Globalization.CultureInfo.InvariantCulture));
        SetSetting("WindowLeft", settings.WindowLeft.ToString(System.Globalization.CultureInfo.InvariantCulture));
        SetSetting("WindowTop", settings.WindowTop.ToString(System.Globalization.CultureInfo.InvariantCulture));
        SetSetting("WindowState", settings.WindowState);
        SetSetting("LastUrl", settings.LastUrl);
    }

    public void SetSetting(string key, string value)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO Settings(Key, Value) VALUES ($key, $value)
            ON CONFLICT(Key) DO UPDATE SET Value = excluded.Value;
            """;
        command.Parameters.AddWithValue("$key", key);
        command.Parameters.AddWithValue("$value", value);
        command.ExecuteNonQuery();
    }

    public void AddSearchHistory(string mode, string keyword)
    {
        SearchHistoryModes.Validate(mode);
        keyword = keyword.Trim();
        if (keyword.Length == 0) return;

        using SqliteConnection connection = OpenConnection();
        using (SqliteCommand enabledCommand = connection.CreateCommand())
        {
            enabledCommand.CommandText = "SELECT Value FROM Settings WHERE Key = 'SearchHistoryEnabled';";
            if (bool.TryParse(enabledCommand.ExecuteScalar()?.ToString(), out bool enabled) && !enabled) return;
        }
        using SqliteTransaction transaction = connection.BeginTransaction();
        using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        // A fresh sequence id puts repeated searches first even within the same clock tick.
        // Delete, insert and trim are atomic and always scoped to the selected search mode.
        command.CommandText = """
            DELETE FROM SearchHistory WHERE Mode = $mode AND Keyword = $keyword;
            INSERT INTO SearchHistory(Mode, Keyword, SearchTimeUtc) VALUES ($mode, $keyword, $time);
            DELETE FROM SearchHistory
            WHERE Mode = $mode AND Id NOT IN (
                SELECT Id FROM SearchHistory WHERE Mode = $mode ORDER BY Id DESC LIMIT $limit
            );
            """;
        command.Parameters.AddWithValue("$mode", mode);
        command.Parameters.AddWithValue("$keyword", keyword);
        command.Parameters.AddWithValue("$time", DateTime.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$limit", MaximumSearchHistoryEntries);
        command.ExecuteNonQuery();
        transaction.Commit();
    }

    public IReadOnlyList<SearchHistoryEntry> GetSearchHistory(string mode)
    {
        SearchHistoryModes.Validate(mode);
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            SELECT Keyword FROM SearchHistory WHERE Mode = $mode ORDER BY Id DESC LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$mode", mode);
        command.Parameters.AddWithValue("$limit", MaximumSearchHistoryEntries);
        using SqliteDataReader reader = command.ExecuteReader();
        List<SearchHistoryEntry> entries = [];
        while (reader.Read())
        {
            entries.Add(new SearchHistoryEntry(mode, reader.GetString(0)));
        }
        return entries;
    }

    public void DeleteSearchHistory(string mode, string keyword)
    {
        SearchHistoryModes.Validate(mode);
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "DELETE FROM SearchHistory WHERE Mode = $mode AND Keyword = $keyword;";
        command.Parameters.AddWithValue("$mode", mode);
        command.Parameters.AddWithValue("$keyword", keyword.Trim());
        command.ExecuteNonQuery();
    }

    public void ClearSearchHistory(string mode)
    {
        SearchHistoryModes.Validate(mode);
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "DELETE FROM SearchHistory WHERE Mode = $mode;";
        command.Parameters.AddWithValue("$mode", mode);
        command.ExecuteNonQuery();
    }

    public void ClearAllSearchHistory()
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "DELETE FROM SearchHistory;";
        command.ExecuteNonQuery();
    }

    public HistoryEntry? GetHistoryByUrl(string url)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT Id, Url, Title, Content, PreviousUrl, NextUrl, Progress, CreatedUtc, LastReadUtc, LastParsedUtc, ParseCount, LocalPath, SourceId FROM History WHERE Url = $url LIMIT 1;";
        command.Parameters.AddWithValue("$url", url);
        using SqliteDataReader reader = command.ExecuteReader();
        return reader.Read() ? ReadHistory(reader) : null;
    }

    public IReadOnlyList<HistoryEntry> GetRecentHistory(int limit)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT Id, Url, Title, Content, PreviousUrl, NextUrl, Progress, CreatedUtc, LastReadUtc, LastParsedUtc, ParseCount, LocalPath, SourceId FROM History ORDER BY LastParsedUtc DESC, LastReadUtc DESC LIMIT $limit;";
        command.Parameters.AddWithValue("$limit", limit);
        using SqliteDataReader reader = command.ExecuteReader();
        List<HistoryEntry> result = [];
        while (reader.Read())
        {
            result.Add(ReadHistory(reader));
        }
        return result;
    }

    public int GetHistoryCount()
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM History;";
        return Convert.ToInt32(command.ExecuteScalar());
    }

    public void SaveHistory(HistoryEntry entry)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO History(Url, Title, Content, PreviousUrl, NextUrl, Progress, CreatedUtc, LastReadUtc, LastParsedUtc, ParseCount, LocalPath, SourceId)
            VALUES ($url, $title, $content, $previousUrl, $nextUrl, $progress, $createdUtc, $lastReadUtc, $lastParsedUtc, $parseCount, $localPath, $sourceId)
            ON CONFLICT(Url) DO UPDATE SET
                Title = excluded.Title,
                Content = excluded.Content,
                PreviousUrl = excluded.PreviousUrl,
                NextUrl = excluded.NextUrl,
                Progress = excluded.Progress,
                LastReadUtc = excluded.LastReadUtc,
                LastParsedUtc = excluded.LastParsedUtc,
                ParseCount = excluded.ParseCount,
                LocalPath = excluded.LocalPath,
                SourceId = excluded.SourceId;
            """;
        command.Parameters.AddWithValue("$url", entry.Url);
        command.Parameters.AddWithValue("$title", entry.Title);
        command.Parameters.AddWithValue("$content", entry.Content);
        command.Parameters.AddWithValue("$previousUrl", entry.PreviousUrl);
        command.Parameters.AddWithValue("$nextUrl", entry.NextUrl);
        command.Parameters.AddWithValue("$progress", entry.Progress);
        command.Parameters.AddWithValue("$createdUtc", entry.CreatedUtc.ToString("O"));
        command.Parameters.AddWithValue("$lastReadUtc", entry.LastReadUtc.ToString("O"));
        command.Parameters.AddWithValue("$lastParsedUtc", entry.LastParsedUtc.ToString("O"));
        command.Parameters.AddWithValue("$parseCount", Math.Max(1, entry.ParseCount));
        command.Parameters.AddWithValue("$localPath", entry.LocalPath);
        command.Parameters.AddWithValue("$sourceId", entry.SourceId);
        command.ExecuteNonQuery();
    }

    public void DeleteHistory(string url)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "DELETE FROM History WHERE Url = $url;";
        command.Parameters.AddWithValue("$url", url);
        command.ExecuteNonQuery();
    }

    public int ClearHistory()
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "DELETE FROM History;";
        return command.ExecuteNonQuery();
    }

    public int ClearExpiredContent(DateTime cutoffUtc)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            UPDATE History
            SET Content = ''
            WHERE Content <> ''
              AND LastReadUtc < $cutoffUtc;
            """;
        command.Parameters.AddWithValue("$cutoffUtc", cutoffUtc.ToUniversalTime().ToString("O"));
        return command.ExecuteNonQuery();
    }

    public void UpdateProgress(string url, double progress)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "UPDATE History SET Progress = $progress, LastReadUtc = $lastReadUtc WHERE Url = $url;";
        command.Parameters.AddWithValue("$progress", Math.Clamp(progress, 0, 1));
        command.Parameters.AddWithValue("$lastReadUtc", DateTime.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$url", url);
        command.ExecuteNonQuery();
    }

    public IReadOnlyList<LibraryBookEntry> GetRecentLibraryBooks(
        int limit = MaximumRecentLibraryBooks)
        => GetLibraryBooks(
            "LastReadUtc <> ''",
            "LastReadUtc DESC",
            Math.Clamp(limit, 1, MaximumRecentLibraryBooks));

    public IReadOnlyList<LibraryBookEntry> GetFavoriteLibraryBooks(
        int limit = MaximumFavoriteLibraryBooks)
        => GetLibraryBooks(
            "FavoriteUtc <> ''",
            "FavoriteUtc DESC",
            Math.Clamp(limit, 1, MaximumFavoriteLibraryBooks));

    public LibraryBookEntry? GetLibraryBook(string bookKey)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = $"{LibraryBookSelectSql} WHERE BookKey = $bookKey LIMIT 1;";
        command.Parameters.AddWithValue("$bookKey", bookKey);
        using SqliteDataReader reader = command.ExecuteReader();
        return reader.Read() ? ReadLibraryBook(reader) : null;
    }

    public int GetFavoriteLibraryBookCount()
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM LibraryBooks WHERE FavoriteUtc <> '';";
        return Convert.ToInt32(command.ExecuteScalar());
    }

    public bool IsLibraryBookFavorite(string bookKey)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT EXISTS(SELECT 1 FROM LibraryBooks WHERE BookKey = $bookKey AND FavoriteUtc <> '');";
        command.Parameters.AddWithValue("$bookKey", bookKey);
        return Convert.ToInt32(command.ExecuteScalar()) != 0;
    }

    public void SaveRecentLibraryBook(LibraryBookEntry entry)
    {
        ValidateLibraryBook(entry);
        DateTime lastReadUtc = entry.LastReadUtc ?? DateTime.UtcNow;
        using SqliteConnection connection = OpenConnection();
        using SqliteTransaction transaction = connection.BeginTransaction();
        using (SqliteCommand command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = """
                INSERT INTO LibraryBooks(
                    BookKey, Title, SourceId, SourceName, DetailUrl, ChapterUrl, ChapterTitle,
                    Progress, LastReadUtc, FavoriteUtc, CatalogJson)
                VALUES (
                    $bookKey, $title, $sourceId, $sourceName, $detailUrl, $chapterUrl, $chapterTitle,
                    $progress, $lastReadUtc, $favoriteUtc, $catalogJson)
                ON CONFLICT(BookKey) DO UPDATE SET
                    Title = excluded.Title,
                    SourceId = excluded.SourceId,
                    SourceName = excluded.SourceName,
                    DetailUrl = excluded.DetailUrl,
                    ChapterUrl = excluded.ChapterUrl,
                    ChapterTitle = excluded.ChapterTitle,
                    Progress = excluded.Progress,
                    LastReadUtc = excluded.LastReadUtc,
                    FavoriteUtc = CASE
                        WHEN LibraryBooks.FavoriteUtc <> '' THEN LibraryBooks.FavoriteUtc
                        ELSE excluded.FavoriteUtc
                    END,
                    CatalogJson = CASE
                        WHEN excluded.CatalogJson <> '' THEN excluded.CatalogJson
                        ELSE LibraryBooks.CatalogJson
                    END;
                """;
            AddLibraryBookParameters(command, entry, lastReadUtc, entry.FavoriteUtc);
            command.ExecuteNonQuery();
        }

        using (SqliteCommand trimCommand = connection.CreateCommand())
        {
            trimCommand.Transaction = transaction;
            trimCommand.CommandText = """
                UPDATE LibraryBooks
                SET LastReadUtc = ''
                WHERE BookKey IN (
                    SELECT BookKey
                    FROM LibraryBooks
                    WHERE LastReadUtc <> ''
                    ORDER BY LastReadUtc DESC
                    LIMIT -1 OFFSET $maximumRecent
                );
                DELETE FROM LibraryBooks
                WHERE LastReadUtc = '' AND FavoriteUtc = '';
                """;
            trimCommand.Parameters.AddWithValue("$maximumRecent", MaximumRecentLibraryBooks);
            trimCommand.ExecuteNonQuery();
        }
        transaction.Commit();
    }

    public bool TryAddFavoriteLibraryBook(LibraryBookEntry entry)
    {
        ValidateLibraryBook(entry);
        using SqliteConnection connection = OpenConnection();
        using SqliteTransaction transaction = connection.BeginTransaction();

        using (SqliteCommand existingCommand = connection.CreateCommand())
        {
            existingCommand.Transaction = transaction;
            existingCommand.CommandText = "SELECT FavoriteUtc FROM LibraryBooks WHERE BookKey = $bookKey LIMIT 1;";
            existingCommand.Parameters.AddWithValue("$bookKey", entry.BookKey);
            string existingFavoriteUtc = Convert.ToString(existingCommand.ExecuteScalar()) ?? string.Empty;
            if (existingFavoriteUtc.Length > 0)
            {
                transaction.Commit();
                return true;
            }
        }

        using (SqliteCommand countCommand = connection.CreateCommand())
        {
            countCommand.Transaction = transaction;
            countCommand.CommandText = "SELECT COUNT(*) FROM LibraryBooks WHERE FavoriteUtc <> '';";
            if (Convert.ToInt32(countCommand.ExecuteScalar()) >= MaximumFavoriteLibraryBooks)
            {
                transaction.Rollback();
                return false;
            }
        }

        DateTime favoriteUtc = entry.FavoriteUtc ?? DateTime.UtcNow;
        using (SqliteCommand command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = """
                INSERT INTO LibraryBooks(
                    BookKey, Title, SourceId, SourceName, DetailUrl, ChapterUrl, ChapterTitle,
                    Progress, LastReadUtc, FavoriteUtc, CatalogJson)
                VALUES (
                    $bookKey, $title, $sourceId, $sourceName, $detailUrl, $chapterUrl, $chapterTitle,
                    $progress, $lastReadUtc, $favoriteUtc, $catalogJson)
                ON CONFLICT(BookKey) DO UPDATE SET
                    Title = excluded.Title,
                    SourceId = excluded.SourceId,
                    SourceName = excluded.SourceName,
                    DetailUrl = excluded.DetailUrl,
                    ChapterUrl = excluded.ChapterUrl,
                    ChapterTitle = excluded.ChapterTitle,
                    Progress = excluded.Progress,
                    LastReadUtc = CASE
                        WHEN excluded.LastReadUtc <> '' THEN excluded.LastReadUtc
                        ELSE LibraryBooks.LastReadUtc
                    END,
                    FavoriteUtc = excluded.FavoriteUtc,
                    CatalogJson = CASE
                        WHEN excluded.CatalogJson <> '' THEN excluded.CatalogJson
                        ELSE LibraryBooks.CatalogJson
                    END;
                """;
            AddLibraryBookParameters(command, entry, entry.LastReadUtc, favoriteUtc);
            command.ExecuteNonQuery();
        }
        transaction.Commit();
        return true;
    }

    public void RemoveFavoriteLibraryBook(string bookKey)
        => ClearLibraryTimestamp(bookKey, "FavoriteUtc");

    public void DeleteRecentLibraryBook(string bookKey)
        => ClearLibraryTimestamp(bookKey, "LastReadUtc");

    public void UpdateLibraryReadingPosition(
        string bookKey,
        string chapterUrl,
        string chapterTitle,
        double progress,
        DateTime lastReadUtc)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            UPDATE LibraryBooks
            SET ChapterUrl = $chapterUrl,
                ChapterTitle = $chapterTitle,
                Progress = $progress,
                LastReadUtc = $lastReadUtc
            WHERE BookKey = $bookKey;
            """;
        command.Parameters.AddWithValue("$chapterUrl", chapterUrl);
        command.Parameters.AddWithValue("$chapterTitle", chapterTitle);
        command.Parameters.AddWithValue("$progress", Math.Clamp(progress, 0, 1));
        command.Parameters.AddWithValue("$lastReadUtc", lastReadUtc.ToUniversalTime().ToString("O"));
        command.Parameters.AddWithValue("$bookKey", bookKey);
        command.ExecuteNonQuery();
    }

    private const string LibraryBookSelectSql = """
        SELECT BookKey, Title, SourceId, SourceName, DetailUrl, ChapterUrl, ChapterTitle,
               Progress, LastReadUtc, FavoriteUtc, CatalogJson
        FROM LibraryBooks
        """;

    private IReadOnlyList<LibraryBookEntry> GetLibraryBooks(string filter, string orderBy, int limit)
    {
        using SqliteConnection connection = OpenConnection();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = $"{LibraryBookSelectSql} WHERE {filter} ORDER BY {orderBy} LIMIT $limit;";
        command.Parameters.AddWithValue("$limit", limit);
        using SqliteDataReader reader = command.ExecuteReader();
        List<LibraryBookEntry> books = [];
        while (reader.Read())
        {
            books.Add(ReadLibraryBook(reader));
        }
        return books;
    }

    private void ClearLibraryTimestamp(string bookKey, string columnName)
    {
        if (columnName is not ("FavoriteUtc" or "LastReadUtc"))
        {
            throw new ArgumentOutOfRangeException(nameof(columnName));
        }

        using SqliteConnection connection = OpenConnection();
        using SqliteTransaction transaction = connection.BeginTransaction();
        using (SqliteCommand updateCommand = connection.CreateCommand())
        {
            updateCommand.Transaction = transaction;
            updateCommand.CommandText = $"UPDATE LibraryBooks SET {columnName} = '' WHERE BookKey = $bookKey;";
            updateCommand.Parameters.AddWithValue("$bookKey", bookKey);
            updateCommand.ExecuteNonQuery();
        }
        using (SqliteCommand cleanupCommand = connection.CreateCommand())
        {
            cleanupCommand.Transaction = transaction;
            cleanupCommand.CommandText = "DELETE FROM LibraryBooks WHERE BookKey = $bookKey AND LastReadUtc = '' AND FavoriteUtc = '';";
            cleanupCommand.Parameters.AddWithValue("$bookKey", bookKey);
            cleanupCommand.ExecuteNonQuery();
        }
        transaction.Commit();
    }

    private static void ValidateLibraryBook(LibraryBookEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (string.IsNullOrWhiteSpace(entry.BookKey) ||
            string.IsNullOrWhiteSpace(entry.Title) ||
            string.IsNullOrWhiteSpace(entry.SourceId) ||
            string.IsNullOrWhiteSpace(entry.DetailUrl))
        {
            throw new ArgumentException("书库记录缺少必要字段。", nameof(entry));
        }
    }

    private static void AddLibraryBookParameters(
        SqliteCommand command,
        LibraryBookEntry entry,
        DateTime? lastReadUtc,
        DateTime? favoriteUtc)
    {
        command.Parameters.AddWithValue("$bookKey", entry.BookKey);
        command.Parameters.AddWithValue("$title", entry.Title);
        command.Parameters.AddWithValue("$sourceId", entry.SourceId);
        command.Parameters.AddWithValue("$sourceName", entry.SourceName);
        command.Parameters.AddWithValue("$detailUrl", entry.DetailUrl);
        command.Parameters.AddWithValue("$chapterUrl", entry.ChapterUrl);
        command.Parameters.AddWithValue("$chapterTitle", entry.ChapterTitle);
        command.Parameters.AddWithValue("$progress", Math.Clamp(entry.Progress, 0, 1));
        command.Parameters.AddWithValue("$lastReadUtc", lastReadUtc?.ToUniversalTime().ToString("O") ?? string.Empty);
        command.Parameters.AddWithValue("$favoriteUtc", favoriteUtc?.ToUniversalTime().ToString("O") ?? string.Empty);
        command.Parameters.AddWithValue("$catalogJson", entry.CatalogJson);
    }

    private static LibraryBookEntry ReadLibraryBook(SqliteDataReader reader)
        => new()
        {
            BookKey = reader.GetString(0),
            Title = reader.GetString(1),
            SourceId = reader.GetString(2),
            SourceName = reader.GetString(3),
            DetailUrl = reader.GetString(4),
            ChapterUrl = reader.GetString(5),
            ChapterTitle = reader.GetString(6),
            Progress = reader.GetDouble(7),
            LastReadUtc = ParseNullableUtc(reader.GetString(8)),
            FavoriteUtc = ParseNullableUtc(reader.GetString(9)),
            CatalogJson = reader.GetString(10)
        };

    private static DateTime? ParseNullableUtc(string value)
        => DateTime.TryParse(
            value,
            null,
            System.Globalization.DateTimeStyles.RoundtripKind,
            out DateTime parsed)
            ? parsed
            : null;

    private SqliteConnection OpenConnection()
    {
        SqliteConnection connection = new(_connectionString);
        connection.Open();
        return connection;
    }

    private static void EnsureHistoryColumn(SqliteConnection connection, string columnName, string columnDefinition)
    {
        bool exists = false;
        using (SqliteCommand tableInfoCommand = connection.CreateCommand())
        {
            tableInfoCommand.CommandText = "PRAGMA table_info(History);";
            using SqliteDataReader reader = tableInfoCommand.ExecuteReader();
            while (reader.Read())
            {
                if (string.Equals(reader.GetString(1), columnName, StringComparison.OrdinalIgnoreCase))
                {
                    exists = true;
                    break;
                }
            }
        }

        if (exists) return;

        using SqliteCommand alterCommand = connection.CreateCommand();
        alterCommand.CommandText = $"ALTER TABLE History ADD COLUMN {columnName} {columnDefinition};";
        alterCommand.ExecuteNonQuery();
    }

    private static HistoryEntry ReadHistory(SqliteDataReader reader)
    {
        return new HistoryEntry
        {
            Id = reader.GetInt64(0),
            Url = reader.GetString(1),
            Title = reader.GetString(2),
            Content = reader.GetString(3),
            PreviousUrl = reader.GetString(4),
            NextUrl = reader.GetString(5),
            Progress = reader.GetDouble(6),
            CreatedUtc = DateTime.Parse(reader.GetString(7), null, System.Globalization.DateTimeStyles.RoundtripKind),
            LastReadUtc = DateTime.Parse(reader.GetString(8), null, System.Globalization.DateTimeStyles.RoundtripKind),
            LastParsedUtc = DateTime.Parse(reader.GetString(9), null, System.Globalization.DateTimeStyles.RoundtripKind),
            ParseCount = Math.Max(1, reader.GetInt32(10)),
            LocalPath = reader.GetString(11),
            SourceId = reader.GetString(12)
        };
    }

    private static string ReadString(IReadOnlyDictionary<string, string> values, string key, string fallback)
        => values.TryGetValue(key, out string? value) ? value : fallback;

    private static double ReadDouble(IReadOnlyDictionary<string, string> values, string key, double fallback)
        => values.TryGetValue(key, out string? value) && double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double result)
            ? result
            : fallback;

    private static bool ReadBool(IReadOnlyDictionary<string, string> values, string key, bool fallback)
        => values.TryGetValue(key, out string? value) && bool.TryParse(value, out bool result) ? result : fallback;

    public void Dispose()
    {
    }
}
