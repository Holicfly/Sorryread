using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using ReadAI;
using ReadAI.Sync;

internal static class LocalBookSyncProbe
{
    public static async Task RunAsync(HttpClient phone, ReaderDatabase database, string root)
    {
        string legacySeq = database.GetLocalSyncSequence();
        var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "local-books-v1.json")))
            .RootElement.GetProperty("txt");
        byte[] desktopBytes = Encoding.UTF8.GetBytes(fixture.GetProperty("content").GetString()!);
        string path = Path.Combine(root, "同步样例.txt");
        await File.WriteAllBytesAsync(path, desktopBytes);
        var parsed = LocalBook.Parse(path, "txt", "同步样例");
        Check(parsed.Units.Select(unit => unit.Address).SequenceEqual(Strings(fixture, "addresses")) &&
            parsed.Units.Select(unit => unit.Title).SequenceEqual(Strings(fixture, "titles")) &&
            parsed.Units.Select(unit => unit.Blocks.Single().Text).SequenceEqual(Strings(fixture, "texts")),
            "TXT cross-platform fixture changed");

        var watch = phone.GetStringAsync($"/v1/watch?after={legacySeq}&localBooksAfter=0");
        var desktop = (await LocalBookImporter.ImportAsync(database, path)).Book;
        Check(desktop.State.Sha256 == fixture.GetProperty("sha256").GetString() &&
            LocalBook.BookKey(desktop.State.Sha256) == fixture.GetProperty("bookKey").GetString(), "Wrong file identity");
        Check(JsonDocument.Parse(await watch.WaitAsync(TimeSpan.FromSeconds(5))).RootElement
            .GetProperty("localBooksChanged").GetBoolean(), "Local book did not wake watch");
        var feed = JsonDocument.Parse(await phone.GetStringAsync("/v1/local-books?after=0")).RootElement;
        Check(feed.GetProperty("books").GetArrayLength() == 1 &&
            feed.GetProperty("nextRevision").GetString() == desktop.Revision, "Initial import missing from feed");
        string download = $"/v1/local-books/{desktop.State.Sha256}/file";
        using var request = new HttpRequestMessage(HttpMethod.Get, download);
        request.Headers.Range = new RangeHeaderValue(11, null);
        using var range = await phone.SendAsync(request);
        Check(range.StatusCode == HttpStatusCode.PartialContent && range.Content.Headers.ContentRange?.From == 11 &&
            (await range.Content.ReadAsByteArrayAsync()).SequenceEqual(desktopBytes[11..]), "Download resume returned wrong bytes");
        Check((await phone.GetByteArrayAsync(download)).SequenceEqual(desktopBytes), "Downloaded original bytes changed");
        string duplicate = Path.Combine(root, "改名.txt");
        File.Copy(path, duplicate);
        Check((await LocalBookImporter.ImportAsync(database, duplicate)).AlreadyInstalled &&
            database.GetLocalBook(desktop.State.Sha256)!.Revision == desktop.Revision, "Duplicate import changed state");

        byte[] phoneBytes = Encoding.UTF8.GetBytes("第一章\n" + new string('a', LocalBook.ChunkSize + 1024));
        string phoneFile = Path.Combine(root, "手机端图书.txt");
        await File.WriteAllBytesAsync(phoneFile, phoneBytes);
        var phoneBook = LocalBook.Parse(phoneFile, "txt", "手机端图书");
        string sha = LocalBook.Hash(phoneBytes);
        string route = $"/v1/local-books/{sha}";
        var now = DateTimeOffset.UtcNow;
        var proposed = new LocalBookState(sha, "txt", phoneBytes.Length, phoneBook.Title, LocalBook.ParserVersion,
            phoneBook.CatalogHash, phoneBook.Units.Count, false, new(3, .42), now, true, now, true);
        using (var stateResponse = await PutState(phone, route, proposed))
        {
            stateResponse.EnsureSuccessStatusCode();
            Check(!SyncProtocol.Decode<LocalBookRecord>(await stateResponse.Content.ReadAsStringAsync()).HasFile,
                "Metadata alone was marked readable");
        }
        Check((await phone.GetAsync(route + "/file")).StatusCode == HttpStatusCode.NotFound, "Partial file was downloadable");

        byte[] corrupt = [.. phoneBytes[..LocalBook.ChunkSize]];
        corrupt[^1] ^= 1;
        using (var first = await Chunk(phone, route, 0, corrupt)) first.EnsureSuccessStatusCode();
        using (var replay = await Chunk(phone, route, 0, corrupt))
            Check(replay.StatusCode == HttpStatusCode.Conflict &&
                JsonDocument.Parse(await replay.Content.ReadAsStringAsync()).RootElement.GetProperty("offset").GetInt64() == LocalBook.ChunkSize,
                "Lost upload acknowledgement did not return the durable offset");
        using (var early = await phone.PostAsync(route + "/finish", null))
            Check(early.StatusCode == HttpStatusCode.Conflict, "Incomplete upload was accepted");
        using (var remainder = await Chunk(phone, route, LocalBook.ChunkSize, phoneBytes[LocalBook.ChunkSize..]))
            remainder.EnsureSuccessStatusCode();
        using (var bad = await phone.PostAsync(route + "/finish", null))
            Check(bad.StatusCode == HttpStatusCode.UnprocessableEntity &&
                (await Offset(phone, route)) == 0 && !database.GetLocalBook(sha)!.HasFile, "Bad digest was not rolled back");

        using (var first = await Chunk(phone, route, 0, phoneBytes[..LocalBook.ChunkSize])) first.EnsureSuccessStatusCode();
        using (var disconnect = await phone.PostAsync("/v1/disconnect", null)) disconnect.EnsureSuccessStatusCode();
        Check((await Offset(phone, route)) == LocalBook.ChunkSize, "Reconnect lost the upload offset");
        using (var remainder = await Chunk(phone, route, LocalBook.ChunkSize, phoneBytes[LocalBook.ChunkSize..]))
            remainder.EnsureSuccessStatusCode();
        using (var finish = await phone.PostAsync(route + "/finish", null))
        {
            finish.EnsureSuccessStatusCode();
            Check(SyncProtocol.Decode<LocalBookRecord>(await finish.Content.ReadAsStringAsync()).HasFile,
                "Verified upload not marked ready");
        }
        var installed = database.GetLocalBook(sha)!;
        using (var retry = await phone.PostAsync(route + "/finish", null))
            Check(retry.IsSuccessStatusCode && database.GetLocalBook(sha)!.Revision == installed.Revision, "Finish retry produced a duplicate");
        Check((await phone.GetByteArrayAsync(route + "/file")).SequenceEqual(phoneBytes), "Upload was not the original");
        var projected = database.GetLibraryBook(LocalBook.BookKey(sha))!;
        Check(projected.ChapterUrl == LocalBook.UnitUrl(sha, 3) && projected.Progress == .42 &&
            projected.IsFavorite && projected.CatalogJson.Length > 0, "Attaching the file lost synchronized data");
        Check(projected.LastReadUtc is null && database.GetRecentLibraryBooks().All(book => book.BookKey != projected.BookKey),
            "Imported book polluted recent reading");
        database.UpdateLibraryReadingPosition(projected.BookKey, LocalBook.UnitUrl(sha, 4), "下一章", .1, DateTime.UtcNow);
        using (var replay = await PutState(phone, route, proposed)) replay.EnsureSuccessStatusCode();
        Check(database.GetLocalBook(sha)!.State.Position == new LocalBookPosition(4, .1), "Older position regressed progress");
        using (var mismatch = await PutState(phone, route, proposed with { CatalogHash = new string('a', 64) }))
            Check(mismatch.StatusCode == HttpStatusCode.Conflict, "Mismatched chapter maps merged");
        database.RemoveFavoriteLibraryBook(projected.BookKey);
        using (var replay = await PutState(phone, route, proposed)) replay.EnsureSuccessStatusCode();
        Check(!database.GetLibraryBook(projected.BookKey)!.IsFavorite, "Old favorite restored after cancellation");
        Check(database.GetLocalSyncSequence() == legacySeq &&
            database.GetSyncSnapshot().Records.All(record => !record.EntityId.StartsWith("book:local|")),
            "Local books polluted the legacy synchronization stream");
        database.Initialize();
        Check(database.GetLocalBook(sha) is { HasFile: true } && (await Offset(phone, route)) == phoneBytes.Length,
            "Reinitialization lost installed original");
        Console.WriteLine("PASS local books: independent feed/watch, TXT contract, original bytes, download range, upload resume, bad digest, retry, progress and legacy isolation");
        await ExerciseLifecycle(phone, database, proposed, phoneFile, route);
    }

    private static IEnumerable<string?> Strings(JsonElement fixture, string key) =>
        fixture.GetProperty(key).EnumerateArray().Select(value => value.GetString());

    private static async Task ExerciseLifecycle(HttpClient phone, ReaderDatabase database, LocalBookState state,
        string file, string route)
    {
        async Task<LocalBookPolicy> Policy(string action, int epoch, string? id = null)
        {
            using var response = await phone.PostAsync(route + "/policy", new StringContent(
                SyncProtocol.Encode(new LocalBookPolicyRequest(id ?? Guid.NewGuid().ToString("N"), action, epoch)),
                Encoding.UTF8, "application/json"));
            response.EnsureSuccessStatusCode();
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            Check(json.RootElement.GetProperty("applied").GetBoolean(), "Policy action not applied");
            return SyncProtocol.Decode<LocalBookPolicy>(json.RootElement.GetProperty("policy").GetRawText());
        }
        string sha = state.Sha256;
        Check((await Policy("removeHere", 0)).PhoneExcluded && database.GetLocalBook(sha) is { HasFile: true },
            "Phone-only removal affected desktop original");
        Check((await phone.GetAsync(route + "/file")).StatusCode == HttpStatusCode.Conflict,
            "Phone-only removal allowed an old file request");
        database.UpdateLibraryReadingPosition(LocalBook.BookKey(sha), LocalBook.UnitUrl(sha, 5), "5", .2, DateTime.UtcNow);
        var excluded = JsonDocument.Parse(await phone.GetStringAsync("/v1/local-books?after=0&lifecycle=true")).RootElement;
        Check(excluded.GetProperty("books").EnumerateArray().All(row => row.GetProperty("state")
            .GetProperty("sha256").GetString() != sha), "Excluded book still appeared in feed");
        Check(!(await Policy("resume", 0)).PhoneExcluded &&
            SyncProtocol.Decode<LocalBookRecord>(await phone.GetStringAsync(route + "/state?epoch=0")).State.Position?.Index == 5,
            "Explicit reimport did not reopen sync with retained progress");
        var catalog = JsonDocument.Parse(await phone.GetStringAsync(route + "/catalog?epoch=0&after=-1"))
            .RootElement.GetProperty("units");
        Check(catalog.GetArrayLength() == 128 && catalog[0].GetProperty("address").GetString()!.StartsWith("txt:"),
            "Catalog was not paginated with stable addresses");
        await database.RemoveLocalBookAsync(sha, both: false);
        Check(database.GetLocalBook(sha) is null && database.GetLibraryBook(LocalBook.BookKey(sha)) is null &&
            File.Exists(file), "Desktop-only removal did not preserve user source while clearing managed state");
        using (var stale = await PutState(phone, route, state))
            Check(stale.StatusCode == HttpStatusCode.Conflict, "Desktop-only removal accepted stale metadata");
        await LocalBookImporter.ImportAsync(database, file);
        Check((await phone.GetAsync(route + "/file?epoch=0")).IsSuccessStatusCode, "Desktop reimport did not resume");
        string removal = Guid.NewGuid().ToString("N");
        Check((await Policy("removeBoth", 0, removal)) is { Removed: true, Epoch: 1 } &&
            (await Policy("removeBoth", 0, removal)).Epoch == 1 && database.GetLocalBook(sha) is null,
            "Global removal did not advance epoch exactly once");
        database.Initialize();
        using (var old = await PutState(phone, route, state))
            Check(old.StatusCode == HttpStatusCode.Conflict, "Global removal allowed replay after restart");
        var imported = await LocalBookImporter.ImportAsync(database, file);
        Check(imported.Book.State.Position is null &&
            (await phone.GetAsync(route + "/file?epoch=1")).IsSuccessStatusCode &&
            (await phone.GetAsync(route + "/file?epoch=0")).StatusCode == HttpStatusCode.Conflict,
            "Recreated generation restored stale progress or served old requests");
        Console.WriteLine("PASS local books lifecycle: catalog paging, both single-device directions, reimport, global deletion, persisted replay protection");
    }

    private static async Task<long> Offset(HttpClient phone, string route) =>
        JsonDocument.Parse(await phone.GetStringAsync(route + "/upload")).RootElement.GetProperty("offset").GetInt64();

    private static async Task<HttpResponseMessage> PutState(HttpClient phone, string route, LocalBookState state)
    {
        using var content = new StringContent(SyncProtocol.Encode(state), Encoding.UTF8, "application/json");
        return await phone.PutAsync(route + "/state", content);
    }

    private static async Task<HttpResponseMessage> Chunk(HttpClient phone, string route, long offset, byte[] bytes)
    {
        using var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return await phone.PutAsync($"{route}/upload?offset={offset}", content);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
