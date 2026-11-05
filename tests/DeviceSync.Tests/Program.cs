using System.IO;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using ReadAI;
using ReadAI.Sync;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;

if (args.Length > 0 && args[0] == "--lifecycle-child")
{
    LifecycleProbe.RunChild(args[1], args[2], args[3]);
    return;
}
if (args.Length > 0 && args[0] == "--window-flow-child")
{
    WindowFlowProbe.RunChild(args[1], args[2], args[3]);
    return;
}

static void Check(bool value, string message)
{
    if (!value) throw new Exception(message);
}

var book = new LibraryBookEntry
{
    BookKey = LibraryBookEntry.CreateBookKey("test", "https://example.invalid/book/1"),
    Title = "Synthetic book", SourceId = "test", SourceName = "Synthetic source",
    DetailUrl = "https://example.invalid/book/1", ChapterUrl = "https://example.invalid/chapter/1",
    ChapterTitle = "Synthetic chapter", Progress = .25, LastReadUtc = DateTime.UtcNow,
};
var readingChapter = new DesktopReadingEntry(0, "", SyncProtocol.BookId(book.BookKey),
    book.Title, book.SourceId, book.DetailUrl, book.ChapterUrl, book.ChapterTitle, 0, 10, .25, "", 0);
if (args.Length > 0 && args[0] == "--serve")
{
    await ServeSyntheticAsync(args, book, readingChapter);
    return;
}

var fixtures = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "sync-v1.json")));
foreach (var test in fixtures.RootElement.EnumerateArray())
{
    var changes = SyncProtocol.Decode<List<SyncChange>>(test.GetProperty("changes").GetRawText());
    SyncRecord? forward = null, reverse = null;
    foreach (var change in changes) forward = SyncProtocol.Merge(forward, change);
    foreach (var change in changes.AsEnumerable().Reverse()) reverse = SyncProtocol.Merge(reverse, change);
    Check(SyncProtocol.Encode(forward) == SyncProtocol.Encode(reverse), "Order did not converge");
    Check(forward!.Versions.Count == test.GetProperty("expectedVersions").GetInt32(), "Unexpected candidate count");
    if (test.TryGetProperty("expectedProgress", out var progress))
    {
        Check(SyncProtocol.Effective(forward).Payload.Progress == progress.GetDouble(), "Farthest progress regressed");
        Check(!forward.HasPositionConflict, "Comparable positions require manual resolution");
        var restored = SyncProtocol.Decode<SyncRecord>(SyncProtocol.Encode(forward));
        Check(SyncProtocol.Effective(restored).Payload.Progress == progress.GetDouble(), "Restart lost farthest progress");
    }
    if (test.TryGetProperty("expectedChapterIndex", out var chapter))
        Check(SyncProtocol.Effective(forward).Payload.ChapterIndex == chapter.GetInt32(), "Wrong chapter order");
    if (test.TryGetProperty("expectedActive", out var active))
        Check(SyncProtocol.Effective(forward).Payload.Active == active.GetBoolean(), "Removal did not win");
    Console.WriteLine("PASS fixture: " + test.GetProperty("name").GetString());
}

string root = Path.Combine(Path.GetTempPath(), "sorryread-sync-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
LibraryScopeProbe.Run(root);
using var left = new ReaderDatabase(Path.Combine(root, "left.db"));
using var right = new ReaderDatabase(Path.Combine(root, "right.db"));
left.Initialize(); right.Initialize();
var midnight = DateTime.Today;
left.RecordDesktopReading(readingChapter, midnight.AddSeconds(-5).ToUniversalTime(), 10000);
var acrossMidnight = left.GetDesktopReadingAfter(0);
Check(acrossMidnight.Count == 2 && acrossMidnight.All(row => row.Milliseconds == 5000),
    "Desktop reading time did not split at local midnight");
Check(left.GetLocalSyncSequence() == "0", "Desktop reading altered the position sync sequence");
left.RecordDesktopReading(readingChapter with { Progress = .5 }, midnight.ToUniversalTime(), 2000);
var revision = left.GetDesktopReadingAfter(acrossMidnight[^1].Revision).Single();
Check(revision.Milliseconds == 7000 && revision.Progress == .5,
    "Desktop reading cursor must receive cumulative time with the latest progress");
left.SaveRecentLibraryBook(book);
left.TryAddFavoriteLibraryBook(book);
long beforeReread = SyncProtocol.Number(left.GetLocalSyncSequence());
book.LastReadUtc = DateTime.UtcNow.AddSeconds(1);
left.SaveRecentLibraryBook(book);
Check(SyncProtocol.Number(left.GetLocalSyncSequence()) == beforeReread + 1,
    "Reopening the same position must update recent reading without a false position event");
var batch = left.GetSyncChanges(left.SyncDeviceId, 0);
long received = right.ApplySyncChanges(left.SyncDeviceId, batch);
right.ApplySyncChanges(left.SyncDeviceId, batch);
Check(right.GetFavoriteLibraryBookCount() == 1, "Duplicate favorite");
Check(right.GetLibraryBook(book.BookKey)!.Progress == .25, "Position not applied");
Check(right.GetLocalSyncSequence() == "0", "Receiving generated a local change");
left.RemoveFavoriteLibraryBook(book.BookKey);
left.DeleteRecentLibraryBook(book.BookKey);
right.ApplySyncChanges(left.SyncDeviceId, left.GetSyncChanges(left.SyncDeviceId, received));
Check(right.GetFavoriteLibraryBookCount() == 0 && right.GetRecentLibraryBooks().Count == 0, "Removal not propagated");
Check(left.GetLibraryBook(book.BookKey)!.Progress == .25, "Removal discarded progress");

for (int index = 0; index < 55; index++)
{
    var extra = new LibraryBookEntry
    {
        BookKey = LibraryBookEntry.CreateBookKey("test", $"https://example.invalid/book/{index + 2}"),
        Title = "Synthetic", SourceId = "test", SourceName = "Test",
        DetailUrl = $"https://example.invalid/book/{index + 2}", Progress = .1,
    };
    Check(left.TryAddFavoriteLibraryBook(extra), "Favorite cap remained");
    left.SaveRecentLibraryBook(extra);
}
Check(left.GetFavoriteLibraryBooks().Count == 55, "Favorites were truncated");
Check(left.GetRecentLibraryBooks().Count == 10, "Display limit changed");
Check(left.GetSyncSnapshot().Records.Count(r => r.Group == "position") == 56, "Old positions were trimmed");

left.SaveHistory(new HistoryEntry
{
    Url = "https://example.invalid/article", Title = "Synthetic article", Progress = .62,
    Content = "This private body must never enter the sync log.", CreatedUtc = DateTime.UtcNow,
    LastReadUtc = DateTime.UtcNow, LastParsedUtc = DateTime.UtcNow,
});
Check(!SyncProtocol.Encode(left.GetSyncSnapshot().Records).Contains("private body"), "Body leaked");
string before = left.GetLocalSyncSequence();
left.ClearExpiredContent(DateTime.UtcNow.AddDays(1));
Check(left.GetLocalSyncSequence() == before, "Cache clearing changed sync state");

// Reject an entire invalid batch without committing earlier items or its cursor.
string third = Guid.NewGuid().ToString("N");
var baseChange = batch[0] with { Origin = third, Seq = "1", Clock = new() { [third] = "1" } };
bool rejected = false;
try { right.ApplySyncChanges(third, [baseChange, baseChange with { Seq = "3", Clock = new() { [third] = "3" } }]); }
catch (InvalidDataException) { rejected = true; }
Check(rejected && right.GetReceivedSyncSequence(third) == 0, "Gap advanced cursor");
Console.WriteLine("PASS persistence, no echo, deletions, all positions, no body, atomic cursor");
for (int i = 0; i < 205; i++) left.AddSyncLog(true, "Daily log " + i);
using (var connection = new SqliteConnection("Data Source=" + Path.Combine(root, "left.db")))
{
    connection.Open();
    using var command = connection.CreateCommand();
    command.CommandText = "INSERT INTO DeviceSyncLogs(TimeUtc,Success,Message) VALUES($time,1,'expired');";
    command.Parameters.AddWithValue("$time", DateTime.UtcNow.AddHours(-25).ToString("O"));
    command.ExecuteNonQuery();
}
Check(left.GetSyncLogs().Count == 205 && left.GetSyncLogs().All(l => l.Message != "expired"), "Rolling daily retention failed");
Console.WriteLine("PASS rolling 24-hour logs without a 200-entry truncation");
using (var replacement = new ReaderDatabase(Path.Combine(root, "replacement-desktop.db")))
{
    replacement.Initialize();
    string phoneId = Guid.NewGuid().ToString("N");
    var previousData = left.GetSyncSnapshot();
    replacement.ApplyClientSnapshot(phoneId, "0", previousData.Records);
    Check(replacement.GetSyncSnapshot().Records.Count == previousData.Records.Count,
        "A new desktop lost data originally received by the phone");
    Check(replacement.GetLocalSyncSequence() == "0", "Snapshot produced local echo operations");
    Check(replacement.GetLibraryBook(book.BookKey)!.LastReadUtc == left.GetLibraryBook(book.BookKey)!.LastReadUtc,
        "An older position timestamp overwrote the latest recent-reading time");
    replacement.ApplyClientSnapshot(phoneId, "0", previousData.Records);
    Check(replacement.GetSyncSnapshot().Records.Count == previousData.Records.Count, "Snapshot retry duplicated data");
    Console.WriteLine("PASS replacement-device full state, snapshot retry and no echo");
}
Console.WriteLine("Isolated synthetic test data: " + root);

await using (var server = new DeviceLinkService(right, Path.Combine(root, "identity"), allowLoopback: true))
{
    server.ConfirmPairingAsync = _ => Task.FromResult(true);
    await server.StartAsync();
    var offer = await server.CreatePairOfferAsync();
    using var handler = new HttpClientHandler { ServerCertificateCustomValidationCallback = (_, certificate, _, _) =>
        certificate != null && Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant() == offer.CertificateSha256 };
    using var client = new HttpClient(handler) { BaseAddress = new Uri($"https://127.0.0.1:{server.Port}"), Timeout = TimeSpan.FromSeconds(10) };
    Check((await client.GetAsync("/v1/hello")).StatusCode == HttpStatusCode.Unauthorized, "Unauthenticated data access");
    Check((await client.GetAsync("/v1/reading-history?after=0")).StatusCode == HttpStatusCode.Unauthorized,
        "Unauthenticated desktop reading access");
    string clientId = left.SyncDeviceId;
    using var pairResponse = await client.PostAsync("/v1/pair", new StringContent(SyncProtocol.Encode(
        new PairRequest(clientId, "Synthetic phone", offer.Token)), Encoding.UTF8, "application/json"));
    Check(pairResponse.IsSuccessStatusCode, "Pairing failed: " + pairResponse.StatusCode);
    var pair = JsonDocument.Parse(await pairResponse.Content.ReadAsStringAsync());
    string credential = pair.RootElement.GetProperty("credential").GetString()!;
    using var retryPair = await client.PostAsync("/v1/pair", new StringContent(SyncProtocol.Encode(
        new PairRequest(clientId, "Synthetic phone", offer.Token)), Encoding.UTF8, "application/json"));
    Check(retryPair.IsSuccessStatusCode && JsonDocument.Parse(await retryPair.Content.ReadAsStringAsync())
        .RootElement.GetProperty("credential").GetString() == credential, "Lost pair response could not be retried");
    client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", credential);
    Check((await client.GetAsync("/v1/hello")).IsSuccessStatusCode, "Authenticated hello failed");
    var hello = JsonDocument.Parse(await client.GetStringAsync("/v1/hello"));
    Check(hello.RootElement.GetProperty("capabilities").EnumerateArray().Any(c => c.GetString() == "watch"), "Watch capability absent");
    Check(hello.RootElement.GetProperty("capabilities").EnumerateArray().Any(c => c.GetString() == "reading-history"),
        "Desktop reading capability absent");
    var readingWatch = client.GetStringAsync($"/v1/watch?after={right.GetLocalSyncSequence()}&readingAfter=0");
    right.RecordDesktopReading(readingChapter, DateTime.UtcNow, 5000);
    using (var result = JsonDocument.Parse(await readingWatch.WaitAsync(TimeSpan.FromSeconds(5))))
        Check(result.RootElement.GetProperty("readingChanged").GetBoolean(), "Desktop reading did not wake the watcher");
    using (var result = JsonDocument.Parse(await client.GetStringAsync("/v1/reading-history?after=0")))
        Check(result.RootElement.GetProperty("entries")[0].GetProperty("milliseconds").GetInt64() == 5000,
            "Desktop reading record missing from authenticated endpoint");
    string watched = right.GetLocalSyncSequence();
    var idle = System.Diagnostics.Stopwatch.StartNew();
    using (var timeout = await client.GetAsync($"/v1/watch?after={watched}&wait=1"))
    {
        Check(timeout.IsSuccessStatusCode && idle.ElapsedMilliseconds >= 800, "Idle watch busy-polled");
        Check(JsonDocument.Parse(await timeout.Content.ReadAsStringAsync()).RootElement.GetProperty("serverSeq").GetString() == watched,
            "Idle watch altered the watermark");
    }
    var pendingWatch = client.GetAsync($"/v1/watch?after={watched}");
    await Task.Delay(100);
    Check(!pendingWatch.IsCompleted, "Unchanged watch completed early");
    right.TryAddFavoriteLibraryBook(new LibraryBookEntry {
        BookKey = LibraryBookEntry.CreateBookKey("test", "https://example.invalid/watch"),
        Title = "Watch book", SourceId = "test", SourceName = "Test", DetailUrl = "https://example.invalid/watch",
    });
    using (var changed = await pendingWatch.WaitAsync(TimeSpan.FromSeconds(2)))
        Check(JsonDocument.Parse(await changed.Content.ReadAsStringAsync()).RootElement.GetProperty("serverSeq").GetString() == right.GetLocalSyncSequence(),
            "Watch missed a committed local change");
    using (var cancelWatch = new CancellationTokenSource(100))
    {
        try { await client.GetAsync($"/v1/watch?after={right.GetLocalSyncSequence()}", cancelWatch.Token); throw new Exception("Watch ignored cancellation"); }
        catch (OperationCanceledException) when (cancelWatch.IsCancellationRequested) { }
    }
    using (var complete = await client.PostAsync("/v1/complete", new StringContent(SyncProtocol.Encode(new CompleteRequest(false,
        ["手机 → 电脑 · 《合成书》\n阅读进度 · 第一章 · 25.0%"])), Encoding.UTF8, "application/json")))
        Check(complete.IsSuccessStatusCode && right.GetSyncLogs().Any(l => l.Message.Contains("合成书")), "Detailed logs were not retained");
    using var duplicatePair = await client.PostAsync("/v1/pair", new StringContent(SyncProtocol.Encode(
        new PairRequest(Guid.NewGuid().ToString("N"), "Second phone", offer.Token)), Encoding.UTF8, "application/json"));
    Check(duplicatePair.StatusCode == HttpStatusCode.Conflict, "A second device paired");
    var response = await client.PostAsync("/v1/snapshot", new StringContent("{}", Encoding.UTF8, "application/json"));
    var descriptor = SyncProtocol.Decode<SyncSnapshot>(await response.Content.ReadAsStringAsync());
    var page = SyncProtocol.Decode<SyncSnapshotPage>(await client.GetStringAsync($"/v1/snapshot/{descriptor.Id}?page=0"));
    Check(page.Records.Count > 0, "Snapshot empty");
    Check((await client.PostAsync("/v1/disconnect", new StringContent("{}", Encoding.UTF8, "application/json"))).IsSuccessStatusCode,
        "Disconnect failed");
    Check(!server.IsConnected, "Disconnect still connected");
    using var wrongHandler = new HttpClientHandler { ServerCertificateCustomValidationCallback = (_, _, _, _) => false };
    using var wrong = new HttpClient(wrongHandler) { BaseAddress = client.BaseAddress };
    wrong.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", credential);
    bool tlsRejected = false;
    try { await wrong.GetAsync("/v1/hello"); } catch (HttpRequestException) { tlsRejected = true; }
    Check(tlsRejected && !server.IsConnected, "Credentials reached an untrusted TLS endpoint");
    var revokedWatch = client.GetAsync($"/v1/watch?after={right.GetLocalSyncSequence()}");
    await Task.Delay(100);
    Check((await client.DeleteAsync("/v1/pair")).IsSuccessStatusCode, "Revoke failed");
    using (var revoked = await revokedWatch.WaitAsync(TimeSpan.FromSeconds(2)))
        Check(revoked.StatusCode == HttpStatusCode.Unauthorized, "Active watch survived revocation");
    Check((await client.GetAsync("/v1/hello")).StatusCode == HttpStatusCode.Unauthorized, "Revoked credential still worked");
    Console.WriteLine("PASS HTTPS pairing, one-device limit, authentication, snapshot, disconnect, TLS rejection and revocation");
}

await PortRecoveryProbe.RunAsync();
await LifecycleProbe.RunParentAsync();

static async Task ServeSyntheticAsync(string[] args, LibraryBookEntry book, DesktopReadingEntry readingChapter)
{
    string output = Path.GetFullPath(args[1]);
    Directory.CreateDirectory(output);
    using var phoneTestDb = new ReaderDatabase(Path.Combine(output, "synthetic.db"));
    phoneTestDb.Initialize();
    phoneTestDb.SaveRecentLibraryBook(book);
    phoneTestDb.TryAddFavoriteLibraryBook(book);
    phoneTestDb.RecordDesktopReading(readingChapter, DateTime.Today.AddHours(12).ToUniversalTime(), 120000);
    phoneTestDb.SaveHistory(new HistoryEntry { Url = "https://example.invalid/plain", Title = "Synthetic article",
        Progress = .6, CreatedUtc = DateTime.UtcNow, LastReadUtc = DateTime.UtcNow, LastParsedUtc = DateTime.UtcNow });
    await using var service = new DeviceLinkService(phoneTestDb, Path.Combine(output, "identity"), allowLoopback: args.Contains("--loopback"));
    service.ConfirmPairingAsync = _ => Task.FromResult(true); // Isolated test host only; production always asks the user.
    await service.StartAsync();
    DateTime nextTicket = DateTime.MinValue;
    Console.WriteLine("READY: isolated synthetic synchronization host");
    while (!File.Exists(Path.Combine(output, "stop")))
    {
        string commandPath = Path.Combine(output, "command.json");
        if (File.Exists(commandPath))
        {
            var command = JsonDocument.Parse(File.ReadAllText(commandPath));
            if (command.RootElement.GetProperty("kind").GetString() == "desktop-read")
                phoneTestDb.UpdateLibraryReadingPosition(book.BookKey, book.ChapterUrl, "Desktop test chapter",
                    command.RootElement.GetProperty("progress").GetDouble(), DateTime.UtcNow);
            if (command.RootElement.GetProperty("kind").GetString() == "desktop-time")
                phoneTestDb.RecordDesktopReading(readingChapter, DateTime.Today.AddHours(13).ToUniversalTime(), 60000);
            File.Delete(commandPath);
        }
        string refreshPath = Path.Combine(output, "refresh-ticket");
        if (service.Peer == null && (DateTime.UtcNow >= nextTicket || File.Exists(refreshPath)))
        {
            var ticket = await service.CreatePairOfferAsync();
            if (args.Contains("--loopback")) ticket = ticket with { Endpoints = [$"https://127.0.0.1:{service.Port}"] };
            File.WriteAllText(Path.Combine(output, "pairing.json"), SyncProtocol.Encode(ticket));
            using var qr = QRCoder.QRCodeGenerator.GenerateQrCode(SyncProtocol.Encode(ticket), QRCoder.QRCodeGenerator.ECCLevel.M);
            using var png = new QRCoder.PngByteQRCode(qr);
            File.WriteAllBytes(Path.Combine(output, "pairing.png"), png.GetGraphic(8));
            nextTicket = DateTime.UtcNow.AddMinutes(2);
            if (File.Exists(refreshPath)) File.Delete(refreshPath);
        }
        File.WriteAllText(Path.Combine(output, "state.json"), SyncProtocol.Encode(new {
            connected = service.IsConnected, paired = service.Peer != null,
            favorites = phoneTestDb.GetFavoriteLibraryBookCount(), recent = phoneTestDb.GetRecentLibraryBooks().Count,
            conflicts = phoneTestDb.GetSyncSnapshot().Records.Count(r => r.HasPositionConflict),
            progress = phoneTestDb.GetLibraryBook(book.BookKey)?.Progress,
            port = service.Port }));
        await Task.Delay(500);
    }
}
