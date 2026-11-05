using System.Globalization;
using ReadAI.Sync;

namespace ReadAI;

public sealed record DesktopReadingEntry(
    long Revision, string Day, string BookId, string Title, string SourceId, string DetailUrl,
    string ChapterUrl, string ChapterTitle, int? ChapterIndex, int? ChapterCount,
    double Progress, string LastRead, long Milliseconds);

public sealed partial class ReaderDatabase
{
    public void RecordDesktopReading(DesktopReadingEntry chapter, DateTime startUtc, long milliseconds)
    {
        if (milliseconds <= 0) return;

        using (var connection = OpenConnection())
        using (var transaction = connection.BeginTransaction())
        {
            while (milliseconds > 0)
            {
                DateTime local = startUtc.ToLocalTime();
                DateTime midnightUtc = local.Date.AddDays(1).ToUniversalTime();
                long part = Math.Min(milliseconds, (long)Math.Ceiling((midnightUtc - startUtc).TotalMilliseconds));
                startUtc = startUtc.AddMilliseconds(part);
                milliseconds -= part;

                using var command = connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandText = """
                    INSERT INTO DesktopReading(Day, BookId, ChapterUrl, Revision, Json, Milliseconds)
                    VALUES($day,$book,$chapter,(SELECT COALESCE(MAX(Revision),0)+1 FROM DesktopReading),$json,$ms)
                    ON CONFLICT(Day, BookId, ChapterUrl) DO UPDATE SET
                        Revision=excluded.Revision, Json=excluded.Json, Milliseconds=DesktopReading.Milliseconds+excluded.Milliseconds;
                    """;
                string day = local.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                command.Parameters.AddWithValue("$day", day);
                command.Parameters.AddWithValue("$book", chapter.BookId);
                command.Parameters.AddWithValue("$chapter", chapter.ChapterUrl);
                command.Parameters.AddWithValue("$json", SyncProtocol.Encode(chapter with
                {
                    Day = day, LastRead = startUtc.AddTicks(-1).ToString("O")
                }));
                command.Parameters.AddWithValue("$ms", part);
                command.ExecuteNonQuery();
            }
            transaction.Commit();
        }
        SyncDataChanged?.Invoke(this, EventArgs.Empty);
    }

    public long GetDesktopReadingRevision()
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COALESCE(MAX(Revision),0) FROM DesktopReading;";
        return (long)command.ExecuteScalar()!;
    }

    public List<DesktopReadingEntry> GetDesktopReadingAfter(long revision)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT Revision, Json, Milliseconds FROM DesktopReading WHERE Revision>$after ORDER BY Revision LIMIT 128;";
        command.Parameters.AddWithValue("$after", revision);
        using var reader = command.ExecuteReader();
        List<DesktopReadingEntry> result = [];
        while (reader.Read())
            result.Add(SyncProtocol.Decode<DesktopReadingEntry>(reader.GetString(1)) with
            {
                Revision = reader.GetInt64(0), Milliseconds = reader.GetInt64(2)
            });
        return result;
    }
}
