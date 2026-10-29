using System.Globalization;
using System.IO;
using System.Text.Json;

namespace ReadAI.Sync;

public sealed record SyncPayload
{
    public string Kind { get; init; } = "book";
    public string Title { get; init; } = "";
    public string SourceId { get; init; } = "";
    public string SourceName { get; init; } = "";
    public string DetailUrl { get; init; } = "";
    public string ChapterUrl { get; init; } = "";
    public string ChapterTitle { get; init; } = "";
    public double Progress { get; init; }
    public bool Active { get; init; } = true;
    public string UpdatedUtc { get; init; } = "";
    // Semantic coordinates shared with the mobile reader.
    public int? ParagraphIndex { get; init; }
    public int? CharacterOffset { get; init; }
    public string? ContentHash { get; init; }
    public int? ChapterIndex { get; init; }
    public int? ChapterCount { get; init; }
    public string? BookProgressChapterUrl { get; init; }
    [System.Text.Json.Serialization.JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; init; }
}

public sealed record SyncChange(string EntityId, string Group, string Origin, string Seq,
    Dictionary<string, string> Clock, SyncPayload Payload);
public sealed record SyncRecord(string EntityId, string Group, List<SyncChange> Versions,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    List<SyncChange>? PositionFrontier = null)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public List<SyncChange> Positions => PositionFrontier ?? Versions;
    [System.Text.Json.Serialization.JsonIgnore]
    public bool HasPositionConflict => Group == "position" && Positions.Count > 1;
}
public sealed record SyncBatch(List<SyncChange> Changes, string ServerSeq);
public sealed record SyncSnapshot(string Id, string ServerSeq, int Pages);
public sealed record SyncSnapshotPage(List<SyncRecord> Records);
public sealed record SyncLogEntry(string TimeUtc, bool Success, string Message);

public static class SyncProtocol
{
    public const int Version = 1;
    public const int BatchSize = 128;
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { MaxDepth = 24 };
    public static string Encode<T>(T value) => JsonSerializer.Serialize(value, Json);
    public static T Decode<T>(string value) => JsonSerializer.Deserialize<T>(value, Json)
        ?? throw new InvalidDataException("同步数据为空。");
    public static long Number(string value) => value != null && value.Length is > 0 and <= 19 &&
        value.All(c => c is >= '0' and <= '9') &&
        long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out long n) && n >= 0 &&
        n.ToString(CultureInfo.InvariantCulture) == value ? n : throw new InvalidDataException("同步序号无效。");
    public static string BookId(string key) => "book:" + key;
    public static string UrlId(string url) => "url:" + url;

    public static void Validate(SyncChange change)
    {
        if (change == null || change.Payload == null || change.Clock == null ||
            new[] { change.EntityId, change.Group, change.Origin, change.Seq, change.Payload.Kind,
                change.Payload.Title, change.Payload.SourceId, change.Payload.SourceName, change.Payload.DetailUrl,
                change.Payload.ChapterUrl, change.Payload.ChapterTitle, change.Payload.UpdatedUtc }.Any(s => s == null))
            throw new InvalidDataException("同步记录字段为空。");
        if (change.Group is not ("favorite" or "recent" or "position") ||
            change.Payload.Kind is not ("book" or "url") ||
            !Guid.TryParseExact(change.Origin, "N", out _) || Number(change.Seq) < 1 ||
            change.Clock.Count is < 1 or > 64 ||
            !change.Clock.TryGetValue(change.Origin, out string? own) || own != change.Seq ||
            change.EntityId != (change.Payload.Kind == "book"
                ? BookId(LibraryBookEntry.CreateBookKey(change.Payload.SourceId, change.Payload.DetailUrl))
                : UrlId(change.Payload.DetailUrl)) ||
            (change.Payload.Kind == "url" && change.Group != "position") ||
            !double.IsFinite(change.Payload.Progress) || change.Payload.Progress is < 0 or > 1 ||
            change.Payload.Title.Length > 512 || change.Payload.SourceId.Length > 128 ||
            change.Payload.SourceName.Length > 128 || change.Payload.ChapterTitle.Length > 512 ||
            change.Payload.DetailUrl.Length > 4096 || change.Payload.ChapterUrl.Length > 4096 ||
            !IsWebUrl(change.Payload.DetailUrl) ||
            (change.Payload.ChapterUrl.Length != 0 && !IsWebUrl(change.Payload.ChapterUrl)) ||
            !DateTimeOffset.TryParse(change.Payload.UpdatedUtc, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out _) ||
            change.Payload.ParagraphIndex < 0 || change.Payload.CharacterOffset < 0 ||
            change.Payload.ContentHash?.Length > 128)
            throw new InvalidDataException("不支持的同步记录或字段格式。");
        foreach (var (id, value) in change.Clock)
            if (!Guid.TryParseExact(id, "N", out _) || Number(value) < 1)
                throw new InvalidDataException("同步因果版本无效。");
    }

    private static bool IsWebUrl(string url) => Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
        uri.Scheme is "https" or "http" && string.IsNullOrEmpty(uri.UserInfo);

    public static Dictionary<string, string> Join(IEnumerable<SyncChange> versions)
    {
        Dictionary<string, string> result = [];
        foreach (var version in versions)
            foreach (var (id, seq) in version.Clock)
                if (!result.TryGetValue(id, out var existing) || Number(seq) > Number(existing)) result[id] = seq;
        return result;
    }

    private static bool Covers(SyncChange newer, SyncChange older) => older.Clock.All(
        p => newer.Clock.TryGetValue(p.Key, out var value) && Number(value) >= Number(p.Value));

    // Compare chapter order, then position inside that chapter. Chapter counts
    // are validation only: appending new chapters must not lower an old rank.
    public static int? CompareBookPositions(SyncPayload a, SyncPayload b)
    {
        if (a.ChapterUrl.Length == 0 || b.ChapterUrl.Length == 0)
            return a.ChapterUrl.Length == 0 ? (b.ChapterUrl.Length == 0 ? 0 : -1) : 1;
        static int? Index(SyncPayload p) => p.ChapterIndex is >= 0 && p.ChapterCount > p.ChapterIndex &&
            p.BookProgressChapterUrl == p.ChapterUrl ? p.ChapterIndex : null;
        if (a.ChapterUrl != b.ChapterUrl)
        {
            var ai = Index(a); var bi = Index(b);
            if (ai == null || bi == null) return null;
            int chapter = ai.Value.CompareTo(bi.Value);
            if (chapter != 0) return chapter;
        }
        if (a.ContentHash != null && a.ContentHash == b.ContentHash &&
            a.ParagraphIndex != null && b.ParagraphIndex != null)
        {
            int paragraph = a.ParagraphIndex.Value.CompareTo(b.ParagraphIndex.Value);
            return paragraph != 0 ? paragraph : (a.CharacterOffset ?? 0).CompareTo(b.CharacterOffset ?? 0);
        }
        return a.Progress.CompareTo(b.Progress);
    }

    private static int CompareIdentity(SyncChange a, SyncChange b)
    {
        int origin = string.CompareOrdinal(a.Origin, b.Origin);
        return origin != 0 ? origin : Number(a.Seq).CompareTo(Number(b.Seq));
    }

    private static int ComparePositionMetadata(SyncChange a, SyncChange b)
    {
        static int Quality(SyncPayload p) => p.ChapterIndex != null && p.BookProgressChapterUrl == p.ChapterUrl ? 1 : 0;
        int quality = Quality(a.Payload).CompareTo(Quality(b.Payload));
        if (quality != 0) return quality;
        bool ab = Covers(a, b), ba = Covers(b, a);
        return ab != ba ? (ab ? 1 : -1) : CompareIdentity(a, b);
    }

    private static List<SyncChange> PositionFrontier(IEnumerable<SyncChange> values)
    {
        var all = values.GroupBy(v => (v.Origin, v.Seq)).Select(g => g.First()).ToList();
        var result = all.Where(v => !all.Any(other => !ReferenceEquals(v, other) &&
            (CompareBookPositions(other.Payload, v.Payload) is int c
                ? (c > 0 || (c == 0 && ComparePositionMetadata(other, v) > 0)) : Covers(other, v))))
            .OrderBy(v => v.Origin, StringComparer.Ordinal).ThenBy(v => Number(v.Seq)).ToList();
        if (result.Count > 64) throw new InvalidDataException("缺少章节顺序，请先更新书籍目录。");
        return result;
    }

    public static SyncRecord Merge(SyncRecord? record, SyncChange incoming)
    {
        Validate(incoming);
        if (record != null && (record.EntityId != incoming.EntityId || record.Group != incoming.Group))
            throw new InvalidDataException("记录分组不一致。");
        var versions = record?.Versions ?? [];
        var duplicate = versions.Concat(record?.PositionFrontier ?? [])
            .FirstOrDefault(v => v.Origin == incoming.Origin && v.Seq == incoming.Seq);
        if (duplicate != null && (Encode(duplicate.Payload) != Encode(incoming.Payload) ||
            duplicate.Clock.Count != incoming.Clock.Count || duplicate.Clock.Any(p =>
                !incoming.Clock.TryGetValue(p.Key, out var value) || value != p.Value)))
            throw new InvalidDataException("同一变更身份包含不同内容。");
        var frontier = incoming.Group == "position" && incoming.Payload.Kind == "book"
            ? PositionFrontier((record?.Positions ?? []).Append(incoming)) : null;
        var merged = versions.Any(v => Covers(v, incoming)) ? versions :
            versions.Where(v => !Covers(incoming, v)).Append(incoming)
                .OrderBy(v => v.Origin, StringComparer.Ordinal).ThenBy(v => Number(v.Seq)).ToList();
        if (merged.Count > 64) throw new InvalidDataException("进度冲突候选过多，请先处理冲突。");
        return new(incoming.EntityId, incoming.Group, merged, frontier);
    }

    public static SyncChange Effective(SyncRecord record) => record.Group == "position"
        ? record.Positions[0]
        : record.Versions.OrderBy(v => v.Payload.Active).ThenBy(v => v.Origin, StringComparer.Ordinal)
            .ThenBy(v => Number(v.Seq)).First();
}
