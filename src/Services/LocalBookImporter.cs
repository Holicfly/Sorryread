using System.IO;
using System.Security.Cryptography;
using ReadAI.Sync;

namespace ReadAI;

public sealed record LocalBookImportResult(LocalBookRecord Book, bool AlreadyInstalled);

public static class LocalBookImporter
{
    public static async Task<LocalBookImportResult> ImportAsync(ReaderDatabase database, string path,
        CancellationToken cancellationToken = default)
    {
        string format = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (!LocalBook.IsFormat(format)) throw new InvalidDataException("仅支持 TXT、EPUB、MOBI。");
        string fallback = LocalBook.LimitTitle(Path.GetFileNameWithoutExtension(path), "未命名图书");
        string staging = StagingDirectory(database);
        string temp = Path.Combine(staging, $"{Guid.NewGuid():N}.import");
        try
        {
            long size;
            string sha;
            await using (var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                size = source.Length;
                if (size is <= 0 or > LocalBook.MaximumFileSize) throw new InvalidDataException("文件为空或超过 200 MB。");
                await using var destination = new FileStream(temp, FileMode.CreateNew, FileAccess.Write,
                    FileShare.None, 64 * 1024, FileOptions.Asynchronous);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                byte[] buffer = new byte[64 * 1024];
                long copied = 0;
                int count;
                while ((count = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) != 0)
                {
                    copied += count;
                    if (copied > size) throw new InvalidDataException("原文件在导入时发生变化。");
                    hash.AppendData(buffer, 0, count);
                    await destination.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                }
                if (copied != size) throw new InvalidDataException("原文件在导入时发生变化。");
                sha = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
            }
            if (database.GetLocalBook(sha) is { HasFile: true } ready) return new(ready, true);
            var parsed = await Task.Run(() => LocalBook.Parse(temp, format, fallback), cancellationToken)
                .ConfigureAwait(false);
            var state = CreateState(sha, format, size, parsed);
            await database.LocalBookFileGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (database.GetLocalBook(sha) is { HasFile: true } existing) return new(existing, true);
                return new(database.InstallLocalBook(state, parsed, temp), false);
            }
            finally { database.LocalBookFileGate.Release(); }
        }
        finally { File.Delete(temp); }
    }

    internal static LocalBookState CreateState(string sha, string format, long size, ParsedLocalBook parsed) =>
        new(sha, format, size, parsed.Title, LocalBook.ParserVersion, parsed.CatalogHash, parsed.Units.Count, parsed.Comic);

    internal static string StagingDirectory(ReaderDatabase database)
    {
        string directory = Path.Combine(database.LocalBookDirectory, ".incoming");
        Directory.CreateDirectory(directory);
        return directory;
    }
}
