using System.Globalization;
using System.IO;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using ReadAI.Sync;

namespace ReadAI;

public sealed partial class ReaderDatabase
{
    internal event EventHandler<string>? LocalBookRemoved;

    public async Task RemoveLocalBookAsync(string sha, bool both, string? targetPeer = null)
    {
        if (both && !Guid.TryParseExact(targetPeer, "N", out _))
            throw new InvalidDataException("双端移除需要已配对的设备。");
        await LocalBookFileGate.WaitAsync().ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                var policy = GetLocalBookPolicy(sha, "");
                ChangeLocalBookPolicy(sha, null, new(Guid.NewGuid().ToString("N"),
                    both ? "removeBoth" : "removeHere", policy.Epoch), targetPeer);
            }).ConfigureAwait(false);
        }
        finally { LocalBookFileGate.Release(); }
    }

    private static void InitializeLocalBookPolicy(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE IF NOT EXISTS LocalBookRevision (Id INTEGER PRIMARY KEY CHECK(Id=1), Value INTEGER NOT NULL);
            INSERT OR IGNORE INTO LocalBookRevision VALUES (1,(SELECT COALESCE(MAX(Revision),0) FROM LocalBooks));
            CREATE TABLE IF NOT EXISTS LocalBookPolicies (
                Sha256 TEXT PRIMARY KEY NOT NULL, Revision INTEGER NOT NULL, Epoch INTEGER NOT NULL,
                Removed INTEGER NOT NULL, DesktopExcluded INTEGER NOT NULL, ExcludedPeers TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS IX_LocalBookPolicies_Revision ON LocalBookPolicies(Revision);
            CREATE TABLE IF NOT EXISTS LocalBookOperations (
                Peer TEXT NOT NULL, Id TEXT NOT NULL, PRIMARY KEY(Peer,Id)
            );
            UPDATE LibraryBooks SET LastReadUtc='' WHERE SourceId='local' AND LastReadUtc<>'';
            """;
        command.ExecuteNonQuery();
        EnsureColumn(connection, "LocalBookUnits", "Address", "TEXT NOT NULL DEFAULT ''");
        EnsureColumn(connection, "LocalBookPolicies", "ResetPeers", "TEXT NOT NULL DEFAULT '{}'");
    }

    private sealed record BookPolicy(string Sha, long Revision = 0, int Epoch = 0, bool Removed = false,
        bool DesktopExcluded = false, string ExcludedPeers = "", string ResetPeers = "{}")
    {
        public bool PhoneExcluded(string peer) => peer.Length > 0 && ExcludedPeers.Split(',').Contains(peer, StringComparer.Ordinal);
        public LocalBookPolicy ForPeer(string peer)
        {
            var resets = JsonSerializer.Deserialize<Dictionary<string, int>>(ResetPeers)!;
            int reset = Math.Max(resets.GetValueOrDefault(peer), resets.GetValueOrDefault("*"));
            return new(Sha, Revision.ToString(CultureInfo.InvariantCulture),
                Epoch, Removed && reset == Epoch, DesktopExcluded, PhoneExcluded(peer), reset);
        }
    }

    private static long AdvanceLocalBookRevision(SqliteConnection connection, SqliteTransaction transaction)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "UPDATE LocalBookRevision SET Value=Value+1 WHERE Id=1 RETURNING Value;";
        return (long)command.ExecuteScalar()!;
    }

    private static BookPolicy ReadBookPolicy(SqliteConnection connection, SqliteTransaction? transaction, string sha)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT Sha256,Revision,Epoch,Removed,DesktopExcluded,ExcludedPeers,ResetPeers FROM LocalBookPolicies WHERE Sha256=$sha;
            """;
        command.Parameters.AddWithValue("$sha", sha);
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadBookPolicy(reader) : new(sha);
    }

    private static BookPolicy ReadBookPolicy(SqliteDataReader reader) => new(reader.GetString(0), reader.GetInt64(1),
        reader.GetInt32(2), reader.GetBoolean(3), reader.GetBoolean(4), reader.GetString(5), reader.GetString(6));

    internal LocalBookPolicy GetLocalBookPolicy(string sha, string peer)
    {
        using var connection = OpenConnection();
        return ReadBookPolicy(connection, null, sha).ForPeer(peer);
    }

    internal IReadOnlyList<LocalBookPolicy> GetLocalBookPolicies(long after, string peer)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT Sha256,Revision,Epoch,Removed,DesktopExcluded,ExcludedPeers,ResetPeers FROM LocalBookPolicies
            WHERE Revision>$after ORDER BY Revision LIMIT 128;
            """;
        command.Parameters.AddWithValue("$after", after);
        using var reader = command.ExecuteReader();
        var policies = new List<LocalBookPolicy>();
        while (reader.Read()) policies.Add(ReadBookPolicy(reader).ForPeer(peer));
        return policies;
    }

    private static BookPolicy WriteBookPolicy(SqliteConnection connection, SqliteTransaction transaction, BookPolicy policy)
    {
        policy = policy with { Revision = AdvanceLocalBookRevision(connection, transaction) };
        ExecuteSyncSql(connection, transaction, """
            INSERT INTO LocalBookPolicies VALUES($sha,$rev,$epoch,$removed,$desktop,$peers,$resets)
            ON CONFLICT(Sha256) DO UPDATE SET Revision=excluded.Revision,Epoch=excluded.Epoch,Removed=excluded.Removed,
                DesktopExcluded=excluded.DesktopExcluded,ExcludedPeers=excluded.ExcludedPeers,ResetPeers=excluded.ResetPeers;
            """, ("$sha", policy.Sha), ("$rev", policy.Revision), ("$epoch", policy.Epoch),
            ("$removed", policy.Removed), ("$desktop", policy.DesktopExcluded), ("$peers", policy.ExcludedPeers),
            ("$resets", policy.ResetPeers));
        return policy;
    }

    internal (bool Applied, LocalBookPolicy Policy) ChangeLocalBookPolicy(string sha, string? peer,
        LocalBookPolicyRequest request, string? targetPeer = null)
    {
        if (!LocalBook.IsHash(sha) || !Guid.TryParseExact(request.Id, "N", out _) ||
            request.Action is not ("removeHere" or "removeBoth" or "resume") || request.Epoch < 0)
            throw new InvalidDataException("本地书移出指令无效。");

        using var connection = OpenConnection();
        using var transaction = connection.BeginTransaction();
        var old = ReadBookPolicy(connection, transaction, sha);
        if (peer is not null)
        {
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = "INSERT OR IGNORE INTO LocalBookOperations VALUES($peer,$id);";
            command.Parameters.AddWithValue("$peer", peer);
            command.Parameters.AddWithValue("$id", request.Id);
            if (command.ExecuteNonQuery() == 0)
            {
                transaction.Commit();
                return (true, old.ForPeer(peer));
            }
        }
        if (request.Epoch != old.Epoch)
        {
            transaction.Rollback();
            return (false, old.ForPeer(peer ?? ""));
        }

        var peers = old.ExcludedPeers.Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
        if (peer is not null && request.Action == "removeHere") peers.Add(peer);
        if (peer is not null && request.Action == "resume") peers.Remove(peer);
        var policy = request.Action switch
        {
            "removeBoth" => old with { Epoch = checked(old.Epoch + 1), Removed = true,
                DesktopExcluded = false },
            "removeHere" when peer is null => old with { DesktopExcluded = true },
            "resume" => old with { Removed = false, DesktopExcluded = peer is null ? false : old.DesktopExcluded,
                ExcludedPeers = string.Join(',', peers.Order(StringComparer.Ordinal)) },
            _ => old with { ExcludedPeers = string.Join(',', peers.Order(StringComparer.Ordinal)) }
        };
        if (request.Action == "removeBoth")
        {
            var resets = JsonSerializer.Deserialize<Dictionary<string, int>>(old.ResetPeers)!;
            resets[peer ?? targetPeer!] = policy.Epoch;
            policy = policy with { ResetPeers = JsonSerializer.Serialize(resets) };
        }
        bool purge = request.Action == "removeBoth" || request.Action == "removeHere" && peer is null;
        if (purge)
        {
            string key = LocalBook.BookKey(sha);
            ExecuteSyncSql(connection, transaction, """
                DELETE FROM LocalBooks WHERE Sha256=$sha;
                DELETE FROM LocalBookUnits WHERE Sha256=$sha;
                DELETE FROM LibraryChapterCache WHERE BookKey=$key;
                DELETE FROM LibraryBooks WHERE BookKey=$key;
                """, ("$sha", sha), ("$key", key));
        }
        if (policy != old) policy = WriteBookPolicy(connection, transaction, policy);
        // A previously excluded peer needs the latest book state on resume.
        if (request.Action == "resume" && policy != old && ReadLocalBook(connection, transaction, sha) is { } book)
            WriteLocalBook(connection, transaction, book.State, book.HasFile);
        transaction.Commit();
        if (purge)
        {
            foreach (string format in new[] { "txt", "epub", "mobi" })
                DeleteBookFile(Path.Combine(LocalBookDirectory, $"{sha}.{format}"));
            LocalBookRemoved?.Invoke(this, sha);
        }
        if (purge || request.Action == "removeHere") DeleteBookPartials(sha, purge ? null : peer);
        SyncDataChanged?.Invoke(this, EventArgs.Empty);
        return (true, policy.ForPeer(peer ?? ""));
    }

    private void DeleteBookPartials(string sha, string? peer)
    {
        string directory = Path.Combine(LocalBookDirectory, ".incoming");
        if (!Directory.Exists(directory)) return;
        foreach (string path in Directory.EnumerateFiles(directory, $"{peer ?? "*"}-{sha}.part"))
            DeleteBookFile(path);
    }

    private static void DeleteBookFile(string path)
    {
        try { File.Delete(path); }
        catch (IOException error) { System.Diagnostics.Debug.WriteLine(error); }
        catch (UnauthorizedAccessException error) { System.Diagnostics.Debug.WriteLine(error); }
    }

    internal IReadOnlyList<LocalBookCatalogUnit> GetLocalBookCatalog(LocalBookState state, int after)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT UnitIndex,Title,Address FROM LocalBookUnits WHERE Sha256=$sha AND UnitIndex>$after
            ORDER BY UnitIndex LIMIT 128;
            """;
        command.Parameters.AddWithValue("$sha", state.Sha256);
        command.Parameters.AddWithValue("$after", after);
        using var reader = command.ExecuteReader();
        var units = new List<LocalBookCatalogUnit>();
        while (reader.Read()) units.Add(new(reader.GetInt32(0), reader.GetString(1), reader.GetString(2)));
        if (units.Any(unit => unit.Address.Length == 0))
        {
            var parsed = LocalBook.Parse(LocalBookFilePath(state), state.Format, state.Title);
            if (parsed.CatalogHash != state.CatalogHash || parsed.Units.Count != state.UnitCount)
                throw new LocalBookCatalogMismatchException();
            units = units.Select(unit => unit with { Address = parsed.Units[unit.Index].Address }).ToList();
            reader.Close();
            using var transaction = connection.BeginTransaction();
            for (int index = 0; index < parsed.Units.Count; index++)
                ExecuteSyncSql(connection, transaction,
                    "UPDATE LocalBookUnits SET Address=$address WHERE Sha256=$sha AND UnitIndex=$index;",
                    ("$address", parsed.Units[index].Address), ("$sha", state.Sha256), ("$index", index));
            transaction.Commit();
        }
        return units;
    }
}
