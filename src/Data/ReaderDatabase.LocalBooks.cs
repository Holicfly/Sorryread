using System.Globalization;
using System.IO;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using ReadAI.Sync;

namespace ReadAI;

public sealed partial class ReaderDatabase
{
    internal event EventHandler<LocalBookState>? RemoteLocalBookPositionAdvanced;
    internal string LocalBookDirectory => Path.Combine(Path.GetDirectoryName(Path.GetFullPath(_databasePath))!, "books");
    internal string LocalBookFilePath(LocalBookState book) => Path.Combine(LocalBookDirectory, $"{book.Sha256}.{book.Format}");
    internal SemaphoreSlim LocalBookFileGate { get; } = new(1, 1);

    private static void InitializeLocalBooks(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE IF NOT EXISTS LocalBooks (
                Sha256 TEXT PRIMARY KEY NOT NULL,
                Revision INTEGER NOT NULL,
                StateJson TEXT NOT NULL,
                Installed INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS IX_LocalBooks_Revision ON LocalBooks(Revision);
            CREATE TABLE IF NOT EXISTS LocalBookUnits (
                Sha256 TEXT NOT NULL,
                UnitIndex INTEGER NOT NULL,
                Title TEXT NOT NULL,
                BlocksJson TEXT NOT NULL,
                PRIMARY KEY(Sha256, UnitIndex)
            );
            """;
        command.ExecuteNonQuery();
    }

    public IReadOnlyList<LocalBookRecord> GetLocalBooks(long after = 0, int limit = 128)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT Revision,StateJson,Installed FROM LocalBooks WHERE Revision > $after
            ORDER BY Revision LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$after", after);
        command.Parameters.AddWithValue("$limit", limit);
        using var reader = command.ExecuteReader();
        var result = new List<LocalBookRecord>();
        while (reader.Read()) result.Add(ReadLocalBook(reader));
        return result;
    }

    public LocalBookRecord? GetLocalBook(string sha)
    {
        using var connection = OpenConnection();
        return ReadLocalBook(connection, null, sha);
    }

    internal (int Ready, int Waiting) GetLocalBookCounts()
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(CASE WHEN Installed=1 THEN 1 END),COUNT(CASE WHEN Installed=0 THEN 1 END) FROM LocalBooks;";
        using var reader = command.ExecuteReader();
        reader.Read();
        return (reader.GetInt32(0), reader.GetInt32(1));
    }

    internal long GetLocalBooksRevision()
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT Value FROM LocalBookRevision WHERE Id=1;";
        return (long)command.ExecuteScalar()!;
    }

    private LocalBookRecord ReadLocalBook(SqliteDataReader reader)
    {
        var state = SyncProtocol.Decode<LocalBookState>(reader.GetString(1)) with { Recent = false, RecentChangedUtc = null };
        var file = new FileInfo(LocalBookFilePath(state));
        bool ready = reader.GetBoolean(2) && file.Exists && file.Length == state.Size;
        return new(reader.GetInt64(0).ToString(CultureInfo.InvariantCulture), state, ready);
    }

    private LocalBookRecord? ReadLocalBook(SqliteConnection connection, SqliteTransaction? transaction, string sha)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT Revision,StateJson,Installed FROM LocalBooks WHERE Sha256=$sha;";
        command.Parameters.AddWithValue("$sha", sha);
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadLocalBook(reader) : null;
    }

    public IReadOnlyList<LocalBookBlock> GetLocalBookBlocks(string sha, int index)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT BlocksJson FROM LocalBookUnits WHERE Sha256=$sha AND UnitIndex=$index;";
        command.Parameters.AddWithValue("$sha", sha);
        command.Parameters.AddWithValue("$index", index);
        return command.ExecuteScalar() is string json ? SyncProtocol.Decode<List<LocalBookBlock>>(json) :
            throw new InvalidDataException("图书章节数据缺失，请重新导入。");
    }

    internal LocalBookRecord ApplyLocalBookState(string sha, LocalBookState incoming)
    {
        incoming.Validate(sha);
        incoming = incoming with { Recent = false, RecentChangedUtc = null };
        using var connection = OpenConnection();
        using var transaction = connection.BeginTransaction();
        var existing = ReadLocalBook(connection, transaction, sha);
        if (existing is not null && !existing.State.SameCatalog(incoming)) throw new LocalBookCatalogMismatchException();
        var merged = existing?.State.Merge(incoming) ?? incoming;
        if (existing is not null && merged == existing.State)
        {
            transaction.Commit();
            return existing;
        }
        var record = WriteLocalBook(connection, transaction, merged, existing?.HasFile == true);
        ProjectLocalBook(connection, transaction, merged);
        transaction.Commit();
        SyncDataChanged?.Invoke(this, EventArgs.Empty);
        if (record.HasFile && LocalBookState.IsFarther(merged.Position, existing?.State.Position))
            RemoteLocalBookPositionAdvanced?.Invoke(this, merged);
        return record;
    }

    internal LocalBookRecord InstallLocalBook(LocalBookState candidate, ParsedLocalBook parsed, string stagedPath,
        bool receivedFromPeer = false)
    {
        candidate.Validate(candidate.Sha256);
        using var connection = OpenConnection();
        using var transaction = connection.BeginTransaction();
        var existing = ReadLocalBook(connection, transaction, candidate.Sha256);
        if (existing?.HasFile == true)
        {
            transaction.Commit();
            return existing;
        }
        if (existing is not null && !existing.State.SameCatalog(candidate)) throw new LocalBookCatalogMismatchException();
        var state = (existing?.State ?? candidate) with { Recent = false, RecentChangedUtc = null };
        string sha = state.Sha256;
        var policy = ReadBookPolicy(connection, transaction, sha);
        if (!receivedFromPeer && (policy.DesktopExcluded || policy.Removed))
            WriteBookPolicy(connection, transaction, policy with { DesktopExcluded = false, Removed = false });
        ExecuteSyncSql(connection, transaction, "DELETE FROM LocalBookUnits WHERE Sha256=$sha;", ("$sha", sha));
        using (var command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = """
                INSERT INTO LocalBookUnits(Sha256,UnitIndex,Title,BlocksJson,Address)
                VALUES($sha,$index,$title,$blocks,$address);
                """;
            command.Parameters.AddWithValue("$sha", sha);
            var indexParam = command.Parameters.Add("$index", SqliteType.Integer);
            var titleParam = command.Parameters.Add("$title", SqliteType.Text);
            var blocksParam = command.Parameters.Add("$blocks", SqliteType.Text);
            var addressParam = command.Parameters.Add("$address", SqliteType.Text);
            for (int index = 0; index < parsed.Units.Count; index++)
            {
                var unit = parsed.Units[index];
                indexParam.Value = index;
                titleParam.Value = unit.Title;
                blocksParam.Value = SyncProtocol.Encode(unit.Blocks);
                addressParam.Value = unit.Address;
                command.ExecuteNonQuery();
            }
        }
        var catalog = parsed.Units.Select((unit, index) =>
            new NovelChapterItem { Title = unit.Title, Url = LocalBook.UnitUrl(sha, index) });
        ProjectLocalBook(connection, transaction, state);
        ExecuteSyncSql(connection, transaction, "UPDATE LibraryBooks SET CatalogJson=$catalog WHERE BookKey=$key;",
            ("$catalog", JsonSerializer.Serialize(catalog)), ("$key", LocalBook.BookKey(sha)));
        var record = WriteLocalBook(connection, transaction, state, true);
        if (receivedFromPeer)
            ExecuteSyncSql(connection, transaction, "INSERT INTO DeviceSyncLogs(TimeUtc,Success,Message) VALUES($utc,1,$message);",
                ("$utc", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture)),
                ("$message", $"手机 → 电脑 · 《{state.Title}》原文件已接收并校验"));
        File.Move(stagedPath, LocalBookFilePath(state), overwrite: true);
        transaction.Commit();
        SyncDataChanged?.Invoke(this, EventArgs.Empty);
        return record;
    }

    private LocalBookRecord WriteLocalBook(SqliteConnection connection, SqliteTransaction transaction,
        LocalBookState state, bool installed)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO LocalBooks(Sha256,Revision,StateJson,Installed)
            VALUES($sha,$rev,$state,$installed)
            ON CONFLICT(Sha256) DO UPDATE SET Revision=excluded.Revision,StateJson=excluded.StateJson,
                Installed=excluded.Installed
            RETURNING Revision;
            """;
        command.Parameters.AddWithValue("$sha", state.Sha256);
        command.Parameters.AddWithValue("$rev", AdvanceLocalBookRevision(connection, transaction));
        command.Parameters.AddWithValue("$state", SyncProtocol.Encode(state));
        command.Parameters.AddWithValue("$installed", installed);
        long revision = (long)command.ExecuteScalar()!;
        return new(revision.ToString(CultureInfo.InvariantCulture), state, installed);
    }

    private static void ProjectLocalBook(SqliteConnection connection, SqliteTransaction transaction, LocalBookState state)
    {
        ExecuteSyncSql(connection, transaction, """
            INSERT INTO LibraryBooks(BookKey,Title,SourceId,SourceName,DetailUrl,ChapterUrl,ChapterTitle,
                Progress,LastReadUtc,FavoriteUtc)
            VALUES($key,$title,'local',$source,$detail,$chapter,COALESCE(
                (SELECT Title FROM LocalBookUnits WHERE Sha256=$sha AND UnitIndex=$index),''),$progress,$recent,$favorite)
            ON CONFLICT(BookKey) DO UPDATE SET Title=excluded.Title,SourceName=excluded.SourceName,
                ChapterUrl=excluded.ChapterUrl,ChapterTitle=excluded.ChapterTitle,Progress=excluded.Progress,
                LastReadUtc=excluded.LastReadUtc,FavoriteUtc=excluded.FavoriteUtc;
            """, ("$key", LocalBook.BookKey(state.Sha256)), ("$title", state.Title),
            ("$source", $"本地书 · {state.Format.ToUpperInvariant()}"), ("$detail", LocalBook.UrlPrefix + state.Sha256),
            ("$sha", state.Sha256), ("$index", state.Position?.Index ?? -1),
            ("$chapter", state.Position is { } position ? LocalBook.UnitUrl(state.Sha256, position.Index) : ""),
            ("$progress", state.Position?.Progress ?? 0), ("$recent", ""),
            ("$favorite", UtcText(state.Favorite, state.FavoriteChangedUtc)));
    }

    private static string UtcText(bool active, DateTimeOffset? time) =>
        active && time.HasValue ? time.Value.UtcDateTime.ToString("O", CultureInfo.InvariantCulture) : "";

    private void RecordLocalBookActivity(SqliteConnection connection, SqliteTransaction transaction,
        LibraryBookEntry book, string group, bool active, DateTime time)
    {
        if (!book.DetailUrl.StartsWith(LocalBook.UrlPrefix, StringComparison.Ordinal)) return;
        string sha = book.DetailUrl[LocalBook.UrlPrefix.Length..];
        var existing = ReadLocalBook(connection, transaction, sha);
        if (existing is null) return;
        var state = existing.State;
        var timestamp = new DateTimeOffset(time.ToUniversalTime());
        var changed = group switch
        {
            "favorite" => state with { Favorite = active, FavoriteChangedUtc = timestamp },
            "position" when LocalBook.UnitIndex(book.ChapterUrl, sha) is int index && index < state.UnitCount =>
                state with { Position = new LocalBookPosition(index, state.Comic ? 0 : Math.Clamp(book.Progress, 0, 1)) },
            _ => state
        };
        var merged = state.Merge(changed);
        if (merged != state) WriteLocalBook(connection, transaction, merged, existing.HasFile);
        ProjectLocalBook(connection, transaction, merged);
    }
}
