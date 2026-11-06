using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Xml;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;

namespace ReadAI.Sync;

public sealed partial class DeviceLinkService
{
    private readonly Dictionary<HttpContext, string> _localBookDownloads = [];

    internal void CancelLocalBookDownloads(string sha)
    {
        HttpContext[] downloads;
        lock (_gate) downloads = _localBookDownloads.Where(item => item.Value == sha).Select(item => item.Key).ToArray();
        foreach (var context in downloads) context.Abort();
    }

    internal (int Sending, int Receiving, long Received) GetLocalBookTransfers()
    {
        lock (_gate)
        {
            if (_peer is null) return default;
            var directory = new DirectoryInfo(Path.Combine(_database.LocalBookDirectory, ".incoming"));
            if (!directory.Exists) return (_localBookDownloads.Count, 0, 0);
            try
            {
                var partials = directory.EnumerateFiles(_peer.DeviceId + "-*.part").ToList();
                return (_localBookDownloads.Count, partials.Count, partials.Sum(file => file.Length));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return (_localBookDownloads.Count, 0, 0);
            }
        }
    }

    private void MapLocalBookRoutes(WebApplication app)
    {
        app.MapGet("/v1/local-books", (HttpContext context, string after, bool? lifecycle) =>
        {
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                long cursor = SyncProtocol.Number(after);
                long watermark = _database.GetLocalBooksRevision();
                string peer = _peer!.DeviceId;
                var rows = _database.GetLocalBooks(cursor);
                var policies = lifecycle == true ? _database.GetLocalBookPolicies(cursor, peer) : [];
                var page = rows.Select(book => SyncProtocol.Number(book.Revision))
                    .Concat(policies.Select(policy => SyncProtocol.Number(policy.Revision)))
                    .Where(revision => revision <= watermark).Order().Take(128).ToArray();
                long last = page.LastOrDefault(lifecycle == true ? Math.Max(watermark, cursor) : cursor);
                var books = rows.Where(book => SyncProtocol.Number(book.Revision) <= last &&
                    CanShareBook(book.State.Sha256, null, checkEpoch: false)).ToArray();
                return Results.Json(new { books, policies = policies.Where(policy => SyncProtocol.Number(policy.Revision) <= last),
                    nextRevision = last.ToString(System.Globalization.CultureInfo.InvariantCulture), more = page.Length == 128 }, SyncProtocol.Json);
            }
        });
        app.MapGet("/v1/local-books/{sha}/state", (HttpContext context, string sha, int? epoch) =>
        {
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                if (!CanShareBook(sha, epoch)) return BookUnavailable(sha);
                return LocalBook.IsHash(sha) && _database.GetLocalBook(sha) is { } book
                    ? Results.Json(book, SyncProtocol.Json) : Results.NotFound();
            }
        });
        app.MapPut("/v1/local-books/{sha}/state", async (HttpContext context, string sha, int? epoch) =>
        {
            if (context.Request.ContentLength is null or > 16384) return Results.StatusCode(413);
            var state = await context.Request.ReadFromJsonAsync<LocalBookState>(SyncProtocol.Json, context.RequestAborted);
            if (state is null) return Results.BadRequest();
            await _database.LocalBookFileGate.WaitAsync(context.RequestAborted);
            try
            {
                lock (_gate)
                {
                    if (!StillAuthorized(context)) return Results.Unauthorized();
                    if (!CanShareBook(sha, epoch)) return BookUnavailable(sha);
                    try { return Results.Json(_database.ApplyLocalBookState(sha, state), SyncProtocol.Json); }
                    catch (LocalBookCatalogMismatchException error) { return CatalogConflict(error); }
                }
            }
            finally { _database.LocalBookFileGate.Release(); }
        });
        app.MapGet("/v1/local-books/{sha}/file", DownloadLocalBookAsync);
        app.MapGet("/v1/local-books/{sha}/upload", (HttpContext context, string sha, int? epoch) =>
        {
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                if (!CanShareBook(sha, epoch)) return BookUnavailable(sha);
                if (!LocalBook.IsHash(sha) || _database.GetLocalBook(sha) is not { } book) return Results.NotFound();
                long offset = book.HasFile ? book.State.Size : UploadOffset(UploadPath(_peer!.DeviceId, sha));
                return Results.Json(new { offset, book.HasFile });
            }
        });
        app.MapPut("/v1/local-books/{sha}/upload", AppendLocalBookChunkAsync);
        app.MapPost("/v1/local-books/{sha}/finish", FinishLocalBookUploadAsync);
        app.MapPost("/v1/local-books/{sha}/policy", UpdateLocalBookPolicyAsync);
        app.MapGet("/v1/local-books/{sha}/catalog", async (HttpContext context, string sha, int after, int epoch) =>
        {
            await _database.LocalBookFileGate.WaitAsync(context.RequestAborted);
            try
            {
                lock (_gate)
                {
                    if (!StillAuthorized(context)) return Results.Unauthorized();
                    if (!CanShareBook(sha, epoch)) return BookUnavailable(sha);
                    if (after < -1 || _database.GetLocalBook(sha) is not { HasFile: true } book) return Results.NotFound();
                    try { return Results.Json(new { units = _database.GetLocalBookCatalog(book.State, after) }, SyncProtocol.Json); }
                    catch (LocalBookCatalogMismatchException error) { return CatalogConflict(error); }
                }
            }
            finally { _database.LocalBookFileGate.Release(); }
        });
    }

    private async Task<IResult> UpdateLocalBookPolicyAsync(HttpContext context, string sha)
    {
        if (context.Request.ContentLength is null or > 4096) return Results.BadRequest();
        var request = await context.Request.ReadFromJsonAsync<LocalBookPolicyRequest>(SyncProtocol.Json, context.RequestAborted);
        if (request is null) return Results.BadRequest();
        await _database.LocalBookFileGate.WaitAsync(context.RequestAborted);
        try
        {
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                var (applied, policy) = _database.ChangeLocalBookPolicy(sha, _peer!.DeviceId, request);
                if (applied && request.Action != "resume") CancelLocalBookDownloads(sha);
                return Results.Json(new { applied, policy }, SyncProtocol.Json);
            }
        }
        finally { _database.LocalBookFileGate.Release(); }
    }

    private bool CanShareBook(string sha, int? epoch, bool checkEpoch = true)
    {
        if (!LocalBook.IsHash(sha)) return false;
        var policy = _database.GetLocalBookPolicy(sha, _peer!.DeviceId);
        return !policy.Removed && !policy.DesktopExcluded && !policy.PhoneExcluded &&
            (!checkEpoch || (epoch ?? 0) == policy.Epoch);
    }

    private IResult BookUnavailable(string sha) => LocalBook.IsHash(sha)
        ? Results.Conflict(new { code = "book_excluded", policy = _database.GetLocalBookPolicy(sha, _peer!.DeviceId) })
        : Results.NotFound();

    private async Task<IResult> DownloadLocalBookAsync(HttpContext context, string sha, int? epoch)
    {
        FileStream file;
        lock (_gate)
        {
            if (!StillAuthorized(context)) return Results.Unauthorized();
            if (!CanShareBook(sha, epoch)) return BookUnavailable(sha);
            if (!LocalBook.IsHash(sha) || _database.GetLocalBook(sha) is not { HasFile: true } book)
                return Results.NotFound();
            try
            {
                file = new FileStream(_database.LocalBookFilePath(book.State), FileMode.Open, FileAccess.Read,
                    FileShare.Read | FileShare.Delete, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            }
            catch (FileNotFoundException) { return Results.NotFound(); }
            if (file.Length != book.State.Size)
            {
                file.Dispose();
                return Results.NotFound();
            }
            _localBookDownloads.Add(context, sha);
        }
        try
        {
            await Results.File(file, "application/octet-stream", enableRangeProcessing: true).ExecuteAsync(context);
            return Results.Empty;
        }
        finally
        {
            lock (_gate) _localBookDownloads.Remove(context);
        }
    }

    private async Task<IResult> AppendLocalBookChunkAsync(HttpContext context, string sha, long offset, int? epoch)
    {
        if (!LocalBook.IsHash(sha)) return Results.NotFound();
        if (context.Request.ContentLength is not long size || size is <= 0 or > LocalBook.ChunkSize)
            return Results.StatusCode(413);
        if (offset < 0 || offset > LocalBook.MaximumFileSize - size) return Results.BadRequest();
        var cancellation = context.RequestAborted;
        // Buffer a single bounded chunk so an interrupted request does not advance the durable offset.
        byte[] bytes = new byte[(int)size];
        await context.Request.Body.ReadExactlyAsync(bytes, cancellation);
        await _database.LocalBookFileGate.WaitAsync(cancellation);
        try
        {
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                if (!CanShareBook(sha, epoch)) return BookUnavailable(sha);
                var book = _database.GetLocalBook(sha);
                if (book is null) return Results.NotFound();
                if (book.HasFile) return Results.Json(new { offset = book.State.Size, hasFile = true });
                string path = UploadPath(_peer!.DeviceId, sha);
                long current = UploadOffset(path);
                if (offset != current)
                    return Results.Conflict(new { offset = current, hasFile = false });
                if (size > book.State.Size - current) return Results.BadRequest();
                if (!HasStagingCapacity(path, size, current == 0))
                    return Results.Problem("本地书暂存区空间不足。", statusCode: 507);
                using var file = new FileStream(path, FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read);
                file.Position = current;
                try
                {
                    file.Write(bytes);
                    file.Flush(flushToDisk: true);
                }
                catch (IOException)
                {
                    file.SetLength(current);
                    return Results.Problem("无法保存本地书传输数据。", statusCode: 507);
                }
                return Results.Json(new { offset = current + size, hasFile = false });
            }
        }
        finally { _database.LocalBookFileGate.Release(); }
    }

    private async Task<IResult> FinishLocalBookUploadAsync(HttpContext context, string sha, int? epoch)
    {
        if (!LocalBook.IsHash(sha)) return Results.NotFound();
        var cancellation = context.RequestAborted;
        await _database.LocalBookFileGate.WaitAsync(cancellation);
        try
        {
            LocalBookRecord book;
            string path;
            lock (_gate)
            {
                if (!StillAuthorized(context)) return Results.Unauthorized();
                if (!CanShareBook(sha, epoch)) return BookUnavailable(sha);
                if (_database.GetLocalBook(sha) is not { } found) return Results.NotFound();
                book = found;
                path = UploadPath(_peer!.DeviceId, sha);
                if (book.HasFile)
                {
                    File.Delete(path);
                    return Results.Json(book, SyncProtocol.Json);
                }
            }
            long offset = UploadOffset(path);
            if (offset != book.State.Size) return Results.Conflict(new { offset, hasFile = false });
            try
            {
                string computed;
                await using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                    64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
                    computed = Convert.ToHexString(await SHA256.HashDataAsync(input, cancellation)).ToLowerInvariant();
                if (computed != sha) throw new InvalidDataException("原文件 SHA-256 校验失败。");
                var parsed = await Task.Run(() => LocalBook.Parse(path, book.State.Format, book.State.Title), cancellation);
                var candidate = LocalBookImporter.CreateState(sha, book.State.Format, offset, parsed);
                lock (_gate)
                {
                    if (!StillAuthorized(context)) return Results.Unauthorized();
                    if (!CanShareBook(sha, epoch)) return BookUnavailable(sha);
                    cancellation.ThrowIfCancellationRequested();
                    var ready = _database.InstallLocalBook(candidate, parsed, path, receivedFromPeer: true);
                    return Results.Json(ready, SyncProtocol.Json);
                }
            }
            catch (LocalBookCatalogMismatchException error)
            {
                File.Delete(path);
                return CatalogConflict(error);
            }
            catch (Exception error) when (error is InvalidDataException or XmlException or DecoderFallbackException)
            {
                File.Delete(path);
                return Results.UnprocessableEntity(new { error = error.Message, offset = 0 });
            }
        }
        finally { _database.LocalBookFileGate.Release(); }
    }

    private string UploadPath(string peer, string sha) =>
        Path.Combine(LocalBookImporter.StagingDirectory(_database), $"{peer}-{sha}.part");

    private static long UploadOffset(string path) => File.Exists(path) ? new FileInfo(path).Length : 0;

    private static bool HasStagingCapacity(string path, long size, bool newFile)
    {
        long bytes = 0;
        int count = 0;
        foreach (var file in new DirectoryInfo(Path.GetDirectoryName(path)!).EnumerateFiles("*.part"))
        {
            if (newFile && file.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-7)) file.Delete();
            else { bytes += file.Length; count++; }
        }
        return bytes + size <= 4 * LocalBook.MaximumFileSize && (!newFile || count < 1024);
    }

    private static IResult CatalogConflict(LocalBookCatalogMismatchException error) =>
        Results.Conflict(new { code = "catalog_mismatch", error = error.Message });
}
