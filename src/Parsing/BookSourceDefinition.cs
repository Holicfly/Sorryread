namespace ReadAI;

public enum BookSourceParserKind
{
    HttpRules,
    Legacy18MhWebView
}

public enum BookSourceHttpMethod
{
    Get,
    Post
}

public enum CatalogHtmlTransform
{
    None,
    WxsyVisibleItems
}

public enum ChapterContentTransform
{
    None,
    DecodeBase64Payload,
    DecodeEmbeddedBase64Scripts
}

public sealed class BookSourceDefinition
{
    public string Id { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public Uri BaseUri { get; init; } = new("https://localhost/");
    public string LegacyHost { get; init; } = string.Empty;
    public BookSourceParserKind ParserKind { get; init; } = BookSourceParserKind.HttpRules;
    /// <summary>Whether the source supports keyword search.</summary>
    public bool IsSearchable { get; init; } = true;
    /// <summary>A nonempty template explicitly enables entry by book id or link.</summary>
    public string BookIdUriTemplate { get; init; } = string.Empty;
    /// <summary>Optional chapter path pattern; group 'path' captures the first-page path without .html.</summary>
    public string InputChapterPathPattern { get; init; } = string.Empty;
    public BookSourceSearchRule Search { get; init; } = new();
    public BookSourceDetailRule Detail { get; init; } = new();
    public BookSourceCatalogRule Catalog { get; init; } = new();
    public BookSourceChapterRule Chapter { get; init; } = new();
}

public sealed class BookSourceSearchRule
{
    public string UriTemplate { get; init; } = string.Empty;
    public BookSourceHttpMethod Method { get; init; } = BookSourceHttpMethod.Get;
    public IReadOnlyDictionary<string, string> FormFields { get; init; }
        = new Dictionary<string, string>();
    public string CookieHeader { get; init; } = string.Empty;
    public string UnavailableMessage { get; init; } = string.Empty;
    public string ResultSelector { get; init; } = string.Empty;
    public string TitleLinkSelector { get; init; } = string.Empty;
    public string ResultOnClickUrlPattern { get; init; } = string.Empty;
    public string AuthorSelector { get; init; } = string.Empty;
    public string CategorySelector { get; init; } = string.Empty;
    public string LatestChapterSelector { get; init; } = string.Empty;
    public string LastUpdateTimeSelector { get; init; } = string.Empty;
    public string StatusSelector { get; init; } = string.Empty;
    public string WordCountSelector { get; init; } = string.Empty;
    public string NextPageSelector { get; init; } = string.Empty;
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(15);
}

public sealed class BookSourceDetailRule
{
    public string BookUrlPattern { get; init; } = string.Empty;
    public string TitleSelector { get; init; } = string.Empty;
    public string AuthorSelector { get; init; } = string.Empty;
    public string IntroSelector { get; init; } = string.Empty;
    public string CategorySelector { get; init; } = string.Empty;
    public string CoverSelector { get; init; } = string.Empty;
    public string LatestChapterSelector { get; init; } = string.Empty;
    public string LatestChapterUrlSelector { get; init; } = string.Empty;
    public string LastUpdateTimeSelector { get; init; } = string.Empty;
    public string StatusSelector { get; init; } = string.Empty;
}

public sealed class BookSourceCatalogRule
{
    public string UriTemplate { get; init; } = string.Empty;
    public string EntryLinkSelector { get; init; } = string.Empty;
    public string ItemSelector { get; init; } = string.Empty;
    public string NextPageSelector { get; init; } = string.Empty;
    public bool IsDescending { get; init; }
    public CatalogHtmlTransform HtmlTransform { get; init; }
}

public sealed class BookSourceChapterRule
{
    public string TitleSelector { get; init; } = string.Empty;
    public string ContentSelector { get; init; } = string.Empty;
    public bool ContentUsesBlockElements { get; init; }
    public string BreakPattern { get; init; } = string.Empty;
    public string RemoveSelectors { get; init; } = string.Empty;
    public string FilterTextPattern { get; init; } = string.Empty;
    public string NextPageSelector { get; init; } = string.Empty;
    public ChapterContentTransform ContentTransform { get; init; }
}
