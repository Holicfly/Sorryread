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
    // Reserved semantic anchor fields are preserved until the mobile reader consumes them.
    public int? ParagraphIndex { get; init; }
    public int? CharacterOffset { get; init; }
    public string? ContentHash { get; init; }
    [System.Text.Json.Serialization.JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; init; }
}

public sealed record SyncChange(string EntityId, string Group, string Origin, string Seq,
    Dictionary<string, string> Clock, SyncPayload Payload);
public sealed record SyncRecord(string EntityId, string Group, List<SyncChange> Versions);
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

    public static SyncRecord Merge(SyncRecord? record, SyncChange incoming)
    {
        Validate(incoming);
        if (record != null && (record.EntityId != incoming.EntityId || record.Group != incoming.Group))
            throw new InvalidDataException("记录分组不一致。");
        var versions = record?.Versions ?? [];
        var duplicate = versions.Find(v => v.Origin == incoming.Origin && v.Seq == incoming.Seq);
        if (duplicate != null)
        {
            if (Encode(duplicate.Payload) != Encode(incoming.Payload) ||
                duplicate.Clock.Count != incoming.Clock.Count || duplicate.Clock.Any(p =>
                    !incoming.Clock.TryGetValue(p.Key, out var value) || value != p.Value))
                throw new InvalidDataException("同一变更身份包含不同内容。");
            return record!;
        }
        if (versions.Any(v => Covers(v, incoming))) return record!;
        var merged = versions.Where(v => !Covers(incoming, v)).Append(incoming)
            .OrderBy(v => v.Origin, StringComparer.Ordinal).ThenBy(v => Number(v.Seq)).ToList();
        if (merged.Count > 64) throw new InvalidDataException("进度冲突候选过多，请先处理冲突。");
        return new(incoming.EntityId, incoming.Group, merged);
    }

    public static SyncChange Effective(SyncRecord record) => record.Group == "position"
        ? record.Versions[0]
        : record.Versions.OrderBy(v => v.Payload.Active).ThenBy(v => v.Origin, StringComparer.Ordinal)
            .ThenBy(v => Number(v.Seq)).First();
}
