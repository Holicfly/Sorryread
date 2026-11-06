using System.Globalization;
using System.IO;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using ReadAI.Sync;

namespace ReadAI;

public sealed partial class ReaderDatabase
{
    public event EventHandler? SyncDataChanged;
    public event EventHandler<SyncChange>? RemotePositionAdvanced;

    private void NotifyPositionAdvances(IEnumerable<SyncChange> changes)
    {
        foreach (var change in changes) RemotePositionAdvanced?.Invoke(this, change);
    }

    private static bool PositionAdvanced(SyncRecord? old, SyncRecord next) =>
        next.Group == "position" && next.EntityId.StartsWith("book:", StringComparison.Ordinal) &&
        !next.HasPositionConflict && (old == null ||
            SyncProtocol.CompareBookPositions(SyncProtocol.Effective(next).Payload,
                SyncProtocol.Effective(old).Payload) > 0);
    public string SyncDeviceId { get; private set; } = "";

    private void InitializeSync()
    {
        using var connection = OpenConnection();
        using (var check = connection.CreateCommand())
        {
            check.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name = 'DeviceSyncMeta';";
            bool firstMigration = Convert.ToInt32(check.ExecuteScalar()) == 0;
            if (firstMigration)
            {
                using var count = connection.CreateCommand();
                count.CommandText = "SELECT (SELECT COUNT(*) FROM History) + (SELECT COUNT(*) FROM LibraryBooks);";
                string backup = _databasePath + ".before-device-sync-v1.bak";
                if (Convert.ToInt64(count.ExecuteScalar()) > 0 && !System.IO.File.Exists(backup))
                {
                    using var target = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = backup }.ToString());
                    target.Open();
                    connection.BackupDatabase(target);
                }
            }
        }
        using var transaction = connection.BeginTransaction();
        ExecuteSyncSql(connection, transaction, """
            CREATE TABLE IF NOT EXISTS DeviceSyncMeta(Key TEXT PRIMARY KEY, Value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS DeviceSyncRecords(
                EntityId TEXT NOT NULL, FieldGroup TEXT NOT NULL, Json TEXT NOT NULL,
                PRIMARY KEY(EntityId,FieldGroup));
            CREATE TABLE IF NOT EXISTS DeviceSyncChanges(
                Origin TEXT NOT NULL, Seq INTEGER NOT NULL, Json TEXT NOT NULL,
                PRIMARY KEY(Origin,Seq));
            CREATE TABLE IF NOT EXISTS DeviceSyncReceived(Origin TEXT PRIMARY KEY, Seq INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS DeviceSyncLogs(
                Id INTEGER PRIMARY KEY AUTOINCREMENT, TimeUtc TEXT NOT NULL,
                Success INTEGER NOT NULL, Message TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS IX_DeviceSyncLogs_Time ON DeviceSyncLogs(julianday(TimeUtc));
            """);
        SyncDeviceId = ReadSyncMeta(connection, transaction, "deviceId") ?? Guid.NewGuid().ToString("N");
        WriteSyncMeta(connection, transaction, "deviceId", SyncDeviceId);
        if (ReadSyncMeta(connection, transaction, "seq") == null) WriteSyncMeta(connection, transaction, "seq", "0");
        if (ReadSyncMeta(connection, transaction, "seeded") != "1")
        {
            List<LibraryBookEntry> books = [];
            using (var query = connection.CreateCommand())
            {
                query.Transaction = transaction;
                query.CommandText = LibraryBookSelectSql;
                using var reader = query.ExecuteReader();
                while (reader.Read()) books.Add(ReadLibraryBook(reader));
            }
            foreach (var book in books)
            {
                if (book.IsFavorite) RecordBook(connection, transaction, book, "favorite", true, book.FavoriteUtc!.Value);
                if (book.LastReadUtc.HasValue) RecordBook(connection, transaction, book, "recent", true, book.LastReadUtc.Value);
                RecordBook(connection, transaction, book, "position", true, book.LastReadUtc ?? DateTime.UtcNow);
            }
            List<HistoryEntry> history = [];
            using (var query = connection.CreateCommand())
            {
                query.Transaction = transaction;
                query.CommandText = SyncHistorySelect;
                using var reader = query.ExecuteReader();
                while (reader.Read()) history.Add(ReadHistory(reader));
            }
            foreach (var entry in history) RecordUrl(connection, transaction, entry, true);
            WriteSyncMeta(connection, transaction, "seeded", "1");
        }
        transaction.Commit();
        PruneSyncLogs();
    }

    internal static void ExecuteSyncSql(SqliteConnection connection, SqliteTransaction transaction, string sql,
        params (string Name, object Value)[] parameters)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
        command.ExecuteNonQuery();
    }

    private static string? ReadSyncMeta(SqliteConnection connection, SqliteTransaction transaction, string key)
    {
        using var query = connection.CreateCommand();
        query.Transaction = transaction;
        query.CommandText = "SELECT Value FROM DeviceSyncMeta WHERE Key=$key;";
        query.Parameters.AddWithValue("$key", key);
        return query.ExecuteScalar() as string;
    }

    private static void WriteSyncMeta(SqliteConnection connection, SqliteTransaction transaction, string key, string value)
        => ExecuteSyncSql(connection, transaction,
            "INSERT INTO DeviceSyncMeta VALUES($key,$value) ON CONFLICT(Key) DO UPDATE SET Value=excluded.Value;",
            ("$key", key), ("$value", value));

    private static SyncRecord? ReadRecord(SqliteConnection connection, SqliteTransaction transaction, string entity, string group)
    {
        using var query = connection.CreateCommand();
        query.Transaction = transaction;
        query.CommandText = "SELECT Json FROM DeviceSyncRecords WHERE EntityId=$entity AND FieldGroup=$group;";
        query.Parameters.AddWithValue("$entity", entity);
        query.Parameters.AddWithValue("$group", group);
        return query.ExecuteScalar() is string json ? SyncProtocol.Decode<SyncRecord>(json) : null;
    }

    private const string SyncHistorySelect = "SELECT Id,Url,Title,'' AS Content,PreviousUrl,NextUrl,Progress,CreatedUtc,LastReadUtc,LastParsedUtc,ParseCount,LocalPath,SourceId FROM History";

    private static HistoryEntry? ReadHistoryForSync(SqliteConnection connection, SqliteTransaction transaction, string url)
    {
        using var query = connection.CreateCommand();
        query.Transaction = transaction;
        query.CommandText = SyncHistorySelect + " WHERE Url=$url;";
        query.Parameters.AddWithValue("$url", url);
        using var reader = query.ExecuteReader();
        return reader.Read() ? ReadHistory(reader) : null;
    }

    private static LibraryBookEntry? ReadBookForSync(SqliteConnection connection, SqliteTransaction transaction, string key)
    {
        using var query = connection.CreateCommand();
        query.Transaction = transaction;
        query.CommandText = LibraryBookSelectSql + " WHERE BookKey=$key;";
        query.Parameters.AddWithValue("$key", key);
        using var reader = query.ExecuteReader();
        return reader.Read() ? ReadLibraryBook(reader) : null;
    }

    public string GetLocalSyncSequence()
    {
        using var connection = OpenConnection();
        using var transaction = connection.BeginTransaction();
        return ReadSyncMeta(connection, transaction, "seq") ?? "0";
    }

    private static void WriteRecord(SqliteConnection connection, SqliteTransaction transaction, SyncRecord record)
        => ExecuteSyncSql(connection, transaction, """
            INSERT INTO DeviceSyncRecords VALUES($entity,$group,$json)
            ON CONFLICT(EntityId,FieldGroup) DO UPDATE SET Json=excluded.Json;
            """, ("$entity", record.EntityId), ("$group", record.Group), ("$json", SyncProtocol.Encode(record)));

    private void RecordLocal(SqliteConnection connection, SqliteTransaction transaction, string entity,
        string group, SyncPayload payload, bool resolve = false)
    {
        var old = ReadRecord(connection, transaction, entity, group);
        var effective = old == null ? null : SyncProtocol.Effective(old);
        // Keep fields introduced by a newer peer when changing known local fields.
        payload = payload with { Extra = payload.Extra ?? effective?.Payload.Extra };
        if (group == "position" && payload.Kind == "book" && effective != null &&
            payload.ChapterUrl == effective.Payload.ChapterUrl && payload.ChapterIndex == null)
            payload = payload with { ChapterIndex = effective.Payload.ChapterIndex,
                ChapterCount = effective.Payload.ChapterCount,
                BookProgressChapterUrl = effective.Payload.BookProgressChapterUrl };
        if (group == "position" && payload.Kind == "book" && effective != null &&
            SyncProtocol.CompareBookPositions(effective.Payload, payload) == 0 &&
            payload.ChapterIndex == effective.Payload.ChapterIndex &&
            payload.ChapterCount == effective.Payload.ChapterCount)
        {
            ApplySyncProjection(connection, transaction, old!);
            return;
        }
        // Re-parsing, receiving, or opening an unchanged position is not a new reading operation.
        if (!resolve && group != "recent" && effective != null && old!.Versions.Count == 1 &&
            SyncProtocol.Encode(effective.Payload with { UpdatedUtc = "" }) ==
            SyncProtocol.Encode(payload with { UpdatedUtc = "" })) return;
        if (group == "position" && payload.Kind == "book" && old != null &&
            old.Positions.Any(v => SyncProtocol.CompareBookPositions(v.Payload, payload) > 0))
        {
            ApplySyncProjection(connection, transaction, old);
            return;
        }
        var observed = old?.Versions ?? [];
        if (!resolve && group == "position" && payload.Kind != "book" && observed.Count > 1)
        {
            var branch = observed.Find(v => v.Origin == SyncDeviceId) ?? observed[0];
            observed = [branch];
        }
        long seq = checked(SyncProtocol.Number(ReadSyncMeta(connection, transaction, "seq") ?? "0") + 1);
        string sequence = seq.ToString(CultureInfo.InvariantCulture);
        var clock = SyncProtocol.Join(observed);
        clock[SyncDeviceId] = sequence;
        var change = new SyncChange(entity, group, SyncDeviceId, sequence, clock, payload);
        var merged = SyncProtocol.Merge(old, change);
        WriteSyncMeta(connection, transaction, "seq", sequence);
        ExecuteSyncSql(connection, transaction, "INSERT INTO DeviceSyncChanges VALUES($origin,$seq,$json);",
            ("$origin", SyncDeviceId), ("$seq", seq), ("$json", SyncProtocol.Encode(change)));
        WriteRecord(connection, transaction, merged);
        if (group == "position" && payload.Kind == "book") ApplySyncProjection(connection, transaction, merged);
        if (seq % 100 == 0)
            ExecuteSyncSql(connection, transaction,
                "DELETE FROM DeviceSyncChanges WHERE Origin=$origin AND Seq<=$before;",
                ("$origin", SyncDeviceId), ("$before", Math.Max(0, seq - 10000)));
    }

    private void RecordBook(SqliteConnection connection, SqliteTransaction transaction, LibraryBookEntry book,
        string group, bool active, DateTime time)
    {
        if (book.SourceId == LocalBook.SourceId)
        {
            RecordLocalBookActivity(connection, transaction, book, group, active, time);
            return;
        }
        int? index = null, count = null;
        if (group == "position" && !string.IsNullOrWhiteSpace(book.CatalogJson))
        {
            try
            {
                var chapters = JsonSerializer.Deserialize<List<NovelChapterItem>>(book.CatalogJson) ?? [];
                int found = chapters.FindIndex(c => c.Url == book.ChapterUrl);
                if (found >= 0) { index = found; count = chapters.Count; }
            }
            catch (JsonException) { /* A missing catalog must not prevent saving. */ }
        }
        RecordLocal(connection, transaction, SyncProtocol.BookId(book.BookKey), group, new SyncPayload
        {
            Kind = "book", Title = book.Title[..Math.Min(book.Title.Length, 512)], SourceId = book.SourceId,
            SourceName = book.SourceName, DetailUrl = book.DetailUrl,
            ChapterUrl = group == "position" ? book.ChapterUrl : "",
            ChapterTitle = group == "position" ? book.ChapterTitle[..Math.Min(book.ChapterTitle.Length, 512)] : "",
            Progress = group == "position" ? Math.Clamp(book.Progress, 0, 1) : 0,
            Active = active, UpdatedUtc = time.ToUniversalTime().ToString("O"),
            ChapterIndex = index, ChapterCount = count,
            BookProgressChapterUrl = index.HasValue ? book.ChapterUrl : null
        });
    }

    private void RecordUrl(SqliteConnection connection, SqliteTransaction transaction, HistoryEntry entry, bool active)
        => RecordLocal(connection, transaction, SyncProtocol.UrlId(entry.Url), "position", new SyncPayload
        {
            Kind = "url", Title = entry.Title[..Math.Min(entry.Title.Length, 512)], SourceId = entry.SourceId,
            DetailUrl = entry.Url, ChapterUrl = entry.Url, Progress = Math.Clamp(entry.Progress, 0, 1),
            Active = active, UpdatedUtc = entry.LastReadUtc.ToUniversalTime().ToString("O")
        });

    public (string Seq, List<SyncRecord> Records) GetSyncSnapshot()
    {
        using var connection = OpenConnection();
        using var transaction = connection.BeginTransaction();
        string seq = ReadSyncMeta(connection, transaction, "seq") ?? "0";
        using var query = connection.CreateCommand();
        query.Transaction = transaction;
        query.CommandText = "SELECT Json FROM DeviceSyncRecords ORDER BY EntityId,FieldGroup;";
        List<SyncRecord> records = [];
        using (var reader = query.ExecuteReader())
            while (reader.Read()) records.Add(SyncProtocol.Decode<SyncRecord>(reader.GetString(0)));
        transaction.Commit();
        return (seq, records);
    }

    public long GetReceivedSyncSequence(string origin)
    {
        using var connection = OpenConnection();
        using var query = connection.CreateCommand();
        query.CommandText = "SELECT Seq FROM DeviceSyncReceived WHERE Origin=$origin;";
        query.Parameters.AddWithValue("$origin", origin);
        return Convert.ToInt64(query.ExecuteScalar() ?? 0L);
    }

    public List<SyncChange> GetSyncChanges(string origin, long after)
    {
        using var connection = OpenConnection();
        using var query = connection.CreateCommand();
        query.CommandText = "SELECT Json FROM DeviceSyncChanges WHERE Origin=$origin AND Seq>$after ORDER BY Seq LIMIT 128;";
        query.Parameters.AddWithValue("$origin", origin);
        query.Parameters.AddWithValue("$after", after);
        List<SyncChange> changes = [];
        using var reader = query.ExecuteReader();
        while (reader.Read()) changes.Add(SyncProtocol.Decode<SyncChange>(reader.GetString(0)));
        return changes;
    }

    public long ApplySyncChanges(string origin, List<SyncChange> changes)
    {
        if (changes.Count > SyncProtocol.BatchSize) throw new InvalidDataException("同步批次过大。");
        foreach (var change in changes)
        {
            SyncProtocol.Validate(change);
            if (change.Origin != origin) throw new InvalidDataException("发送设备身份不一致。");
        }
        using var connection = OpenConnection();
        using var transaction = connection.BeginTransaction();
        long received;
        using (var query = connection.CreateCommand())
        {
            query.Transaction = transaction;
            query.CommandText = "SELECT Seq FROM DeviceSyncReceived WHERE Origin=$origin;";
            query.Parameters.AddWithValue("$origin", origin);
            received = Convert.ToInt64(query.ExecuteScalar() ?? 0L);
        }
        var advanced = new Dictionary<string, SyncChange>();
        foreach (var change in changes)
        {
            long seq = SyncProtocol.Number(change.Seq);
            if (seq <= received) continue;
            if (seq != received + 1) throw new InvalidDataException("同步序号不连续，请重新对账。");
            var old = ReadRecord(connection, transaction, change.EntityId, change.Group);
            var record = SyncProtocol.Merge(old, change);
            if (PositionAdvanced(old, record)) advanced[record.EntityId] = SyncProtocol.Effective(record);
            WriteRecord(connection, transaction, record);
            ApplySyncProjection(connection, transaction, record);
            received = seq;
        }
        ExecuteSyncSql(connection, transaction, """
            INSERT INTO DeviceSyncReceived VALUES($origin,$seq)
            ON CONFLICT(Origin) DO UPDATE SET Seq=excluded.Seq;
            """, ("$origin", origin), ("$seq", received));
        transaction.Commit();
        SyncDataChanged?.Invoke(this, EventArgs.Empty);
        NotifyPositionAdvances(advanced.Values);
        return received;
    }

    public long ApplyClientSnapshot(string origin, string sequence, List<SyncRecord> records)
    {
        long watermark = SyncProtocol.Number(sequence);
        if (records.Count > 50000) throw new InvalidDataException("快照过大。");
        foreach (var record in records)
        {
            if (record == null || record.Versions == null || record.Versions.Count is < 1 or > 64)
                throw new InvalidDataException("快照候选无效。");
            if (record.PositionFrontier != null && (record.Group != "position" ||
                !record.EntityId.StartsWith("book:", StringComparison.Ordinal) || record.PositionFrontier.Count is < 1 or > 64))
                throw new InvalidDataException("最远进度状态无效。");
            foreach (var change in record.Versions.Concat(record.PositionFrontier ?? []))
            {
                SyncProtocol.Validate(change);
                if (change.EntityId != record.EntityId || change.Group != record.Group ||
                    (change.Clock.TryGetValue(origin, out var own) && SyncProtocol.Number(own) > watermark))
                    throw new InvalidDataException("快照水位或实体不一致。");
            }
        }
        using var connection = OpenConnection();
        using var transaction = connection.BeginTransaction();
        var advanced = new List<SyncChange>();
        foreach (var record in records.OrderBy(r => r.Group == "position" ? 1 : 0))
        {
            var merged = ReadRecord(connection, transaction, record.EntityId, record.Group);
            var old = merged;
            foreach (var change in record.Versions.Concat(record.PositionFrontier ?? [])) merged = SyncProtocol.Merge(merged, change);
            if (PositionAdvanced(old, merged!)) advanced.Add(SyncProtocol.Effective(merged!));
            WriteRecord(connection, transaction, merged!);
            ApplySyncProjection(connection, transaction, merged!);
        }
        ExecuteSyncSql(connection, transaction, """
            INSERT INTO DeviceSyncReceived VALUES($origin,$seq)
            ON CONFLICT(Origin) DO UPDATE SET Seq=MAX(Seq,excluded.Seq);
            """, ("$origin", origin), ("$seq", watermark));
        transaction.Commit();
        SyncDataChanged?.Invoke(this, EventArgs.Empty);
        NotifyPositionAdvances(advanced);
        return GetReceivedSyncSequence(origin);
    }

    private static void ApplySyncProjection(SqliteConnection connection, SqliteTransaction transaction, SyncRecord record)
    {
        var payload = SyncProtocol.Effective(record).Payload;
        string timestamp = DateTimeOffset.Parse(payload.UpdatedUtc, CultureInfo.InvariantCulture).UtcDateTime.ToString("O");
        if (record.HasPositionConflict) return;
        if (payload.Kind == "book")
        {
            string key = record.EntityId[5..];
            ExecuteSyncSql(connection, transaction, """
                INSERT INTO LibraryBooks(BookKey,Title,SourceId,SourceName,DetailUrl)
                VALUES($key,$title,$source,$name,$url) ON CONFLICT(BookKey) DO UPDATE SET
                Title=excluded.Title,SourceName=excluded.SourceName;
                """, ("$key", key), ("$title", payload.Title), ("$source", payload.SourceId),
                ("$name", payload.SourceName), ("$url", payload.DetailUrl));
            if (record.Group is "favorite" or "recent")
            {
                string column = record.Group == "favorite" ? "FavoriteUtc" : "LastReadUtc";
                ExecuteSyncSql(connection, transaction, $"UPDATE LibraryBooks SET {column}=$time WHERE BookKey=$key;",
                    ("$time", payload.Active ? timestamp : ""), ("$key", key));
            }
            else
            {
                ExecuteSyncSql(connection, transaction, """
                    UPDATE LibraryBooks SET ChapterUrl=$url,ChapterTitle=$title,Progress=$progress WHERE BookKey=$key;
                    """, ("$key", key), ("$url", payload.ChapterUrl), ("$title", payload.ChapterTitle), ("$progress", payload.Progress));
                var recent = ReadRecord(connection, transaction, record.EntityId, "recent");
                if (recent != null && SyncProtocol.Effective(recent).Payload.Active)
                {
                    string recentTime = DateTimeOffset.Parse(SyncProtocol.Effective(recent).Payload.UpdatedUtc,
                        CultureInfo.InvariantCulture).UtcDateTime.ToString("O");
                    ExecuteSyncSql(connection, transaction, "UPDATE LibraryBooks SET LastReadUtc=$time WHERE BookKey=$key;",
                        ("$key", key), ("$time", string.CompareOrdinal(recentTime, timestamp) > 0 ? recentTime : timestamp));
                }
            }
        }
        else if (!payload.Active)
            ExecuteSyncSql(connection, transaction, "DELETE FROM History WHERE Url=$url;", ("$url", payload.DetailUrl));
        else
            ExecuteSyncSql(connection, transaction, """
                INSERT INTO History(Url,Title,Content,Progress,CreatedUtc,LastReadUtc,LastParsedUtc,SourceId)
                VALUES($url,$title,'',$progress,$time,$time,$time,$source)
                ON CONFLICT(Url) DO UPDATE SET Progress=excluded.Progress,LastReadUtc=excluded.LastReadUtc;
                """, ("$url", payload.DetailUrl), ("$title", payload.Title), ("$progress", payload.Progress),
                ("$time", timestamp), ("$source", payload.SourceId));
    }

    public void ResolveSyncPosition(string entityId, string origin, string seq)
    {
        using var connection = OpenConnection();
        using var transaction = connection.BeginTransaction();
        var record = ReadRecord(connection, transaction, entityId, "position") ?? throw new InvalidOperationException("进度已更新。");
        var chosen = record.Positions.Find(v => v.Origin == origin && v.Seq == seq)
            ?? throw new InvalidOperationException("候选位置已更新，请重新选择。");
        RecordLocal(connection, transaction, entityId, "position", chosen.Payload with { UpdatedUtc = DateTime.UtcNow.ToString("O") }, true);
        ApplySyncProjection(connection, transaction, ReadRecord(connection, transaction, entityId, "position")!);
        transaction.Commit();
        SyncDataChanged?.Invoke(this, EventArgs.Empty);
    }

    public void AddSyncLog(bool success, string message) => AddSyncLogs(success, [message]);

    public void AddSyncLogs(bool success, IEnumerable<string> messages)
    {
        using var connection = OpenConnection();
        using var transaction = connection.BeginTransaction();
        string time = DateTime.UtcNow.ToString("O");
        foreach (string message in messages)
            ExecuteSyncSql(connection, transaction, "INSERT INTO DeviceSyncLogs(TimeUtc,Success,Message) VALUES($time,$success,$message);",
                ("$time", time), ("$success", success ? 1 : 0), ("$message", message[..Math.Min(message.Length, 2048)]));
        ExecuteSyncSql(connection, transaction, "DELETE FROM DeviceSyncLogs WHERE julianday(TimeUtc) <= julianday($cutoff);",
            ("$cutoff", DateTime.UtcNow.AddDays(-1).ToString("O")));
        transaction.Commit();
    }

    public List<SyncLogEntry> GetSyncLogs()
    {
        PruneSyncLogs();
        using var connection = OpenConnection();
        using var query = connection.CreateCommand();
        query.CommandText = "SELECT TimeUtc,Success,Message FROM DeviceSyncLogs ORDER BY Id DESC;";
        List<SyncLogEntry> entries = [];
        using var reader = query.ExecuteReader();
        while (reader.Read()) entries.Add(new(reader.GetString(0), reader.GetInt64(1) != 0, reader.GetString(2)));
        return entries;
    }

    public void PruneSyncLogs()
    {
        using var connection = OpenConnection();
        using var prune = connection.CreateCommand();
        prune.CommandText = "DELETE FROM DeviceSyncLogs WHERE julianday(TimeUtc) <= julianday($cutoff);";
        prune.Parameters.AddWithValue("$cutoff", DateTime.UtcNow.AddDays(-1).ToString("O"));
        prune.ExecuteNonQuery();
    }
}
