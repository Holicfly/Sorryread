using System.IO;

namespace ReadAI.Sync;

public sealed record LocalBookPosition(int Index, double Progress);

public sealed record LocalBookState(string Sha256, string Format, long Size, string Title,
    int ParserVersion, string CatalogHash, int UnitCount, bool Comic,
    LocalBookPosition? Position = null, DateTimeOffset? FavoriteChangedUtc = null,
    bool Favorite = false, DateTimeOffset? RecentChangedUtc = null, bool Recent = false)
{
    internal void Validate(string sha)
    {
        if (!LocalBook.IsHash(sha) || sha != Sha256 || !LocalBook.IsFormat(Format) ||
            Size is <= 0 or > LocalBook.MaximumFileSize || string.IsNullOrWhiteSpace(Title) || Title.Length > 512 ||
            ParserVersion != LocalBook.ParserVersion || !LocalBook.IsHash(CatalogHash) ||
            UnitCount is <= 0 or > LocalBook.MaximumUnits || (Comic && Format != "epub") ||
            (Favorite && FavoriteChangedUtc is null) || (Recent && RecentChangedUtc is null) ||
            (Position is { } position && (position.Index < 0 || position.Index >= UnitCount ||
                !double.IsFinite(position.Progress) || position.Progress is < 0 or > 1 ||
                (Comic && position.Progress != 0))))
            throw new InvalidDataException("本地书书目或阅读位置无效。");
    }

    internal bool SameCatalog(LocalBookState other) => Format == other.Format && Size == other.Size &&
        ParserVersion == other.ParserVersion && CatalogHash == other.CatalogHash &&
        UnitCount == other.UnitCount && Comic == other.Comic;

    internal LocalBookState Merge(LocalBookState incoming)
    {
        bool favorite = IsNewer(incoming.FavoriteChangedUtc, incoming.Favorite, FavoriteChangedUtc, Favorite);
        return this with
        {
            Position = IsFarther(incoming.Position, Position) ? incoming.Position : Position,
            Favorite = favorite ? incoming.Favorite : Favorite,
            FavoriteChangedUtc = favorite ? incoming.FavoriteChangedUtc : FavoriteChangedUtc,
            Recent = false,
            RecentChangedUtc = null
        };
    }

    private static bool IsNewer(DateTimeOffset? a, bool activeA, DateTimeOffset? b, bool activeB) =>
        a.HasValue && (!b.HasValue || a > b || (a == b && !activeA && activeB));

    internal static bool IsFarther(LocalBookPosition? a, LocalBookPosition? b) =>
        a is not null && (b is null || a.Index > b.Index || (a.Index == b.Index && a.Progress > b.Progress));
}

public sealed record LocalBookRecord(string Revision, LocalBookState State, bool HasFile);

internal sealed class LocalBookCatalogMismatchException() : IOException("同一本书的章节或页序不同，请确认两端的解析版本。");
