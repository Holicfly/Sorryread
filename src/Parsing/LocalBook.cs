using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace ReadAI;

public sealed record LocalBookBlock(string Text, string? ImagePath = null);
public sealed record LocalBookUnit(string Title, string Address, IReadOnlyList<LocalBookBlock> Blocks);
public sealed record ParsedLocalBook(string Title, bool Comic, IReadOnlyList<LocalBookUnit> Units)
{
    public string CatalogHash => LocalBook.Hash(Encoding.UTF8.GetBytes(
        string.Join('\n', Units.Select(unit => unit.Address))));
}

public static class LocalBook
{
    public const string SourceId = "local";
    public const string UrlPrefix = "https://local.sorryread.invalid/";
    public const int ParserVersion = 1;
    public const long MaximumFileSize = 200L * 1024 * 1024;
    public const int MaximumUnits = 25_000;
    public const int ChunkSize = 1024 * 1024;

    public static bool IsHash(string? value) => value is { Length: 64 } &&
        value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    public static bool IsFormat(string? value) => value is "txt" or "epub" or "mobi";
    public static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    public static string BookKey(string sha) => LibraryBookEntry.CreateBookKey(SourceId, UrlPrefix + sha);
    public static string UnitUrl(string sha, int index) =>
        UrlPrefix + sha + "/" + index.ToString(System.Globalization.CultureInfo.InvariantCulture);

    public static int? UnitIndex(string url, string sha)
    {
        string prefix = UrlPrefix + sha + "/";
        return url.StartsWith(prefix, StringComparison.Ordinal) &&
            int.TryParse(url.AsSpan(prefix.Length), System.Globalization.NumberStyles.None,
                System.Globalization.CultureInfo.InvariantCulture, out int index) ? index : null;
    }

    public static ParsedLocalBook Parse(string path, string format, string fallbackTitle)
    {
        if (new FileInfo(path).Length is <= 0 or > MaximumFileSize)
            throw new InvalidDataException("文件为空或超过 200 MB。");
        var book = format switch
        {
            "txt" => new ParsedLocalBook(fallbackTitle, false, LocalBookText.Split(
                LocalBookText.Decode(File.ReadAllBytes(path)), "txt")),
            "epub" => LocalBookEpub.Parse(path, fallbackTitle),
            "mobi" => LocalBookMobi.Parse(path, fallbackTitle),
            _ => throw new InvalidDataException("仅支持 TXT、EPUB、MOBI。")
        };
        if (book.Units.Count is 0 or > MaximumUnits)
            throw new InvalidDataException("图书没有可读内容，或目录条目过多。");
        return book with { Title = LimitTitle(book.Title, fallbackTitle) };
    }

    internal static string LimitTitle(string value, string fallback)
    {
        string title = string.IsNullOrWhiteSpace(value) ? fallback.Trim() : value.Trim();
        return title.Length <= 512 ? title : title[..(char.IsHighSurrogate(title[511]) ? 511 : 512)];
    }
}
