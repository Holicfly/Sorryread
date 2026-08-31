namespace ReadAI;

public static class BookSourceCatalog
{
    public const string Legacy18MhId = "18mh";

    // The source list is code-owned by design. Selectors were independently
    // adapted from the public site DOMs referenced by freeok/so-novel at
    // commit 76150dbd2827b4de97cde83cffb3ee367bc9be3a (2026-08-26 audit).
    public static IReadOnlyList<BookSourceDefinition> All { get; } =
    [
        new()
        {
            Id = "xbiqugu",
            Name = "香书小说",
            BaseUri = new Uri("http://www.xbiqugu.la/"),
            Search = new()
            {
                UriTemplate = "http://www.xbiqugu.la/modules/article/waps.php",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("searchkey", "{keyword}")),
                ResultSelector = "#checkform > table > tbody > tr",
                TitleLinkSelector = "td.even > a",
                AuthorSelector = "td:nth-of-type(3)",
                LatestChapterSelector = "td.odd > a",
                LastUpdateTimeSelector = "td:nth-of-type(4)"
            },
            Detail = new()
            {
                LatestChapterSelector = "#info > p:nth-child(5) > a",
                LatestChapterUrlSelector = "#info > p:nth-child(5) > a"
            },
            Catalog = new() { ItemSelector = "#list > dl > dd > a" },
            Chapter = new()
            {
                TitleSelector = ".bookname > h1",
                ContentSelector = "#content",
                BreakPattern = "<br>+",
                RemoveSelectors = "div, p, script",
                FilterTextPattern = "一秒记住【文学巴士&nbsp;】，精彩无弹窗免费阅读！|(www.xbiquge.la 新笔趣阁)，高速全文字在线阅读！|天才一秒记住本站地址：.+。手机版阅读网址：m.|手机用户请浏览阅读，更优质的阅读体验。|天才壹秒記住.+，為您提供精彩小說閱讀。|\\(本章完\\)"
            }
        },
        new()
        {
            Id = "shuhaige",
            Name = "书海阁小说网",
            BaseUri = new Uri("https://www.shuhaige.net/"),
            Search = new()
            {
                UriTemplate = "https://www.shuhaige.net/search.html",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("searchkey", "{keyword}"), ("searchtype", "all")),
                CookieHeader = "waf_sc=''; HMACCOUNT=''",
                ResultSelector = "#sitembox > dl",
                TitleLinkSelector = "dd > h3 > a",
                AuthorSelector = "dd:nth-child(3) > span:nth-child(1)",
                CategorySelector = "dd:nth-child(3) > span:nth-child(3)",
                LatestChapterSelector = "dd:nth-child(5) > a",
                LastUpdateTimeSelector = "dd:nth-child(5) > span",
                WordCountSelector = "dd:nth-child(3) > span:nth-child(4)",
                StatusSelector = "dd:nth-child(3) > span:nth-child(2)",
                NextPageSelector = "#pagelink > a:not(.pgroup):not(.ngroup)"
            },
            Detail = new() { IntroSelector = "#intro > p:nth-child(1)" },
            Catalog = new() { ItemSelector = "dl > dt:nth-of-type(2) ~ dd > a" },
            Chapter = new()
            {
                TitleSelector = ".bookname > h1",
                ContentSelector = "#content",
                ContentUsesBlockElements = true,
                RemoveSelectors = ".bottem2, hr, script, table",
                FilterTextPattern = "本小章还未完，请点击下一页继续阅读后面精彩内容！|小主，这个章节后面还有哦，请点击下一页继续阅读，后面更精彩！|这章没有结束，请点击下一页继续阅读！|喜欢(.+?)请大家收藏：\\(([^)]+)\\)\\1书海阁小说网更新速度全网最快。|\\(本章完\\)",
                NextPageSelector = "#pager_next"
            }
        },
        new()
        {
            Id = "mcxs",
            Name = "梦书中文",
            BaseUri = new Uri("http://www.mcxs.la/"),
            Search = new()
            {
                UriTemplate = "http://www.mcxs.la/search.html",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("name", "{keyword}")),
                ResultSelector = ".novelslist2 > ul > li",
                TitleLinkSelector = "span.s2.wid > a",
                AuthorSelector = "span.s4.wid > a",
                LatestChapterSelector = "span.s3.wid3 > a",
                LastUpdateTimeSelector = "span.s6.wid6"
            },
            Catalog = new() { ItemSelector = "dl > dt:nth-of-type(2) ~ dd > a" },
            Chapter = new()
            {
                TitleSelector = ".bookname > h1",
                ContentSelector = "#content",
                BreakPattern = "<br>+",
                RemoveSelectors = "div, p, script",
                FilterTextPattern = "天才一秒记住本站地址：[.+] .+最快更新！无广告！|(.+)，高速全文字在线阅读！|一秒记住【.+】，精彩无弹窗免费阅读！|《.+》.+全文字更新，牢记网址：([a-zA-Z0-9-]+(\\.[a-zA-Z0-9-]+)*\\.[a-zA-Z]{2,})|\\(本章完\\)"
            }
        },
        new()
        {
            Id = "99wx",
            Name = "鸟书网",
            BaseUri = new Uri("http://www.99wx.info/"),
            Search = new()
            {
                UriTemplate = "http://www.99wx.info/read/search/",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("searchkey", "{keyword}")),
                ResultSelector = "div.wrap > div > div > div",
                TitleLinkSelector = "div.bookinfo > h4 > a",
                AuthorSelector = "div.bookinfo > div.author",
                LatestChapterSelector = "div.bookinfo > div.update > a"
            },
            Catalog = new() { ItemSelector = "dl > dt:nth-of-type(2) ~ dd > a" },
            Chapter = new()
            {
                TitleSelector = ".content > h1",
                ContentSelector = "#content",
                BreakPattern = "<br>+",
                FilterTextPattern = "请记住本书首发域名：.+。鸟书网手机版阅读网址：.+|7017k|\\(本章完\\)"
            }
        },
        new()
        {
            Id = "22biqu",
            Name = "笔趣阁22",
            BaseUri = new Uri("https://www.22biqu.com/"),
            Search = new()
            {
                UriTemplate = "https://www.22biqu.com/ss/",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("searchkey", "{keyword}"), ("Submit", "搜索")),
                ResultSelector = "body > div.container > div > div > ul > li",
                TitleLinkSelector = "span.s2 > a",
                AuthorSelector = "span.s4",
                CategorySelector = "span.s1",
                LatestChapterSelector = "span.s3",
                LastUpdateTimeSelector = "span.s5"
            },
            Detail = new()
            {
                LatestChapterSelector = "meta[property=\"og:novel:lastest_chapter_name\"]",
                LatestChapterUrlSelector = "meta[property=\"og:novel:lastest_chapter_url\"]"
            },
            Catalog = new()
            {
                ItemSelector = "div:nth-child(4) > ul > li > a",
                NextPageSelector = "#indexselect > option"
            },
            Chapter = new()
            {
                TitleSelector = ".title",
                ContentSelector = "#content",
                ContentUsesBlockElements = true,
                FilterTextPattern = "\\(本章完\\)",
                NextPageSelector = "#next_url"
            }
        },
        new()
        {
            Id = "xbiquwk",
            Name = "笔尖中文",
            BaseUri = new Uri("http://www.xbiquwk.com/"),
            Search = new()
            {
                UriTemplate = "http://www.xbiquwk.com/modules/article/search.php",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("searchkey", "{keyword}")),
                ResultSelector = "#wrapper > table > tbody > tr",
                TitleLinkSelector = "td:nth-child(1) > a",
                AuthorSelector = "td:nth-child(3)",
                LatestChapterSelector = "td:nth-child(2)",
                LastUpdateTimeSelector = "td:nth-child(5)"
            },
            Detail = new() { BookUrlPattern = @"^http://www\.xbiquwk\.com/([^/]+)/?$" },
            Catalog = new()
            {
                UriTemplate = "http://www.xbiquwk.com/{bookId}/",
                ItemSelector = "#list > dl > dd > a"
            },
            Chapter = new()
            {
                TitleSelector = ".bookname > h1",
                ContentSelector = "#content",
                BreakPattern = "<br>+",
                FilterTextPattern = "<!--.*?-->|喜欢.+请大家收藏：.+|\\(本章完\\)"
            }
        },
        new()
        {
            Id = "ujxsw",
            Name = "悠久小说网",
            BaseUri = new Uri("http://www.ujxsw.org/"),
            Search = new()
            {
                UriTemplate = "http://www.ujxsw.org/searchbooks.php",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("searchkey", "{keyword}")),
                ResultSelector = "#main > div.shuku_list > div.shulist > ul",
                TitleLinkSelector = "li.three > a",
                AuthorSelector = "li.four > a",
                CategorySelector = "li.two",
                StatusSelector = "li.six",
                LatestChapterSelector = "li.three > span > a",
                LastUpdateTimeSelector = "li.five"
            },
            Detail = new()
            {
                BookUrlPattern = @"^http://www\.ujxsw\.org/book/([^/]+)/?$",
                TitleSelector = "#maininfo > div.coverecom.w_770.left > div.tabstit > a:nth-child(4)",
                AuthorSelector = "#bookinfo > div.bookright > div.d_title > h1 > em > a",
                IntroSelector = "#bookintro",
                CategorySelector = "#count > span:nth-child(1)",
                CoverSelector = "#bookimg > a > img",
                LatestChapterSelector = "#bookinfo > div.bookright > div.new > span.new_t > a",
                LatestChapterUrlSelector = "#bookinfo > div.bookright > div.new > span.new_t > a",
                LastUpdateTimeSelector = "#bookinfo > div.bookright > div.new > span.new_p"
            },
            Catalog = new()
            {
                UriTemplate = "http://www.ujxsw.org/read/{bookId}/",
                ItemSelector = "#readerlist > ul > li > a"
            },
            Chapter = new()
            {
                TitleSelector = "#mlfy_main_text > h3",
                ContentSelector = "#mlfy_main_text > div.read-content > p",
                BreakPattern = "<br>+",
                FilterTextPattern = "【悠久小説網ωωω.ＵＪХＳw.ｎｅｔ】，免费小说无弹窗免费阅读！|佰度搜索 【悠久小說網 ＷＷＷ.ＵＪХＳw．ＮＥＴ】 全集TXT电子书免费下载！|《.*》悠久小说网全文字更新,牢记网址:www.ujxsw.org|1秒记住网："
            }
        },
        new()
        {
            Id = "yeudusk",
            Name = "阅读库",
            BaseUri = new Uri("http://www.yeudusk.com/"),
            Search = new()
            {
                UriTemplate = "http://www.yeudusk.com/modules/article/search.php?q={keyword}",
                ResultSelector = "#jieqi_page_contents > div > div:nth-child(2)",
                TitleLinkSelector = "div:nth-child(1) > span > a",
                AuthorSelector = "div:nth-child(2) > span:nth-child(2)",
                CategorySelector = "div:nth-child(2) > span:nth-child(4)",
                StatusSelector = "span:nth-child(8)",
                LatestChapterSelector = "div:nth-child(4) > span:nth-child(2) > a",
                LastUpdateTimeSelector = "div:nth-child(4) > span:nth-child(4)"
            },
            Detail = new()
            {
                BookUrlPattern = @"^http://www\.yeudusk\.com/book/([^/]+)/?$",
                IntroSelector = "#content > div.divbox.cf > div:nth-child(2) > div:nth-child(3) > div.tabcontent > div:nth-child(1) > div",
                LatestChapterSelector = "#content > div:nth-child(4) > h3",
                LatestChapterUrlSelector = "#content > div:nth-child(4) > h3 > a",
                LastUpdateTimeSelector = "#content > div.divbox.cf > div:nth-child(2) > div:nth-child(3) > div.tabcontent > div:nth-child(2) > table > tbody > tr:nth-child(1) > td:nth-child(3)"
            },
            Catalog = new()
            {
                UriTemplate = "http://www.yeudusk.com/html/0/{bookId}/",
                ItemSelector = "ul > li > a"
            },
            Chapter = new()
            {
                TitleSelector = "#cont > h1",
                ContentSelector = "#clickeye_content",
                BreakPattern = "<br>+",
                FilterTextPattern = "\\(阅读库\\s?www\\.yeudusk\\.com\\)|阅读库 www.yeudusk.comyeudusk www.yeudusk.com|《.+》阅读库全文字更新,牢记网址:www\\.yeudusk\\.com"
            }
        },
        new()
        {
            Id = "wxsy",
            Name = "顶点小说",
            BaseUri = new Uri("https://www.wxsy.net/"),
            Search = new()
            {
                UriTemplate = "https://www.wxsy.net/search.html",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("s", "{keyword}")),
                ResultSelector = "body > div.container > div:nth-child(1) > div > ul > li",
                TitleLinkSelector = "span.s2 > a",
                AuthorSelector = "span.s3 > a",
                CategorySelector = "span.s1",
                LatestChapterSelector = "span.s4 > a",
                LastUpdateTimeSelector = "span.s5"
            },
            Detail = new()
            {
                BookUrlPattern = @"^https://www\.wxsy\.net/novel/([^/]+)/?$",
                CoverSelector = ".imgbox > img"
            },
            Catalog = new()
            {
                UriTemplate = "https://www.wxsy.net/novel/{bookId}/chapter_1.html",
                ItemSelector = ".biqunaicc > div:nth-child(2) > div > ul > li > a",
                NextPageSelector = ".biqunaicc > div:nth-child(2) > div > div:nth-child(2) > select > option",
                HtmlTransform = CatalogHtmlTransform.WxsyVisibleItems
            },
            Chapter = new()
            {
                TitleSelector = "h3",
                ContentSelector = ".row-detail > div > div",
                ContentUsesBlockElements = true,
                RemoveSelectors = "h3, div, p[style=font-size:12px;]",
                FilterTextPattern = "请勿开启浏览器阅读模式，否则将导致章节内容缺失及无法阅读下一章。|\\(本章完\\)",
                NextPageSelector = ".row.row-detail > div > div > div:nth-child(2) > a:nth-child(4)",
                ContentTransform = ChapterContentTransform.DecodeBase64Payload
            }
        },
        new()
        {
            Id = "biquge365",
            Name = "笔趣阁365",
            BaseUri = new Uri("https://www.biquge365.net/"),
            Search = new()
            {
                UriTemplate = "https://www.biquge365.net/s.php",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("type", "articlename"), ("s", "{keyword}")),
                ResultSelector = "body > div.menu > div > ul > li",
                TitleLinkSelector = "span.name > a",
                AuthorSelector = "span.zuo > a",
                CategorySelector = "span.lei > a",
                LatestChapterSelector = "span.jie > a",
                LastUpdateTimeSelector = "span.time"
            },
            Detail = new()
            {
                BookUrlPattern = @"^https://www\.biquge365\.net/book/([^/]+)/?$",
                LatestChapterUrlSelector = "body > div.menu > div.right > div:nth-child(1) > div > div.xinxi > span:nth-child(8) > a",
                LastUpdateTimeSelector = "body > div.menu > div.right > div:nth-child(1) > div > div.xinxi > span:nth-child(7)"
            },
            Catalog = new()
            {
                UriTemplate = "https://www.biquge365.net/newbook/{bookId}/",
                ItemSelector = "body > div.menu > div.border > ul > li > a"
            },
            Chapter = new()
            {
                TitleSelector = "#neirong > h1",
                ContentSelector = "#txt",
                BreakPattern = "<br>+",
                RemoveSelectors = "p"
            }
        },
        new()
        {
            Id = "ranwen8",
            Name = "燃文小说网",
            BaseUri = new Uri("https://www.ranwen8.cc/"),
            Search = new()
            {
                UriTemplate = "https://www.ranwen8.cc/search.html",
                Method = BookSourceHttpMethod.Post,
                FormFields = Form(("submit", "搜索"), ("s", "{keyword}")),
                ResultSelector = "body > div.padding > div > table > tbody > tr",
                TitleLinkSelector = "td:nth-child(1) > a",
                AuthorSelector = "td:nth-child(3)",
                LatestChapterSelector = "td:nth-child(2) > a",
                LastUpdateTimeSelector = "td:nth-child(4)"
            },
            Detail = new()
            {
                BookUrlPattern = @"^https://www\.ranwen8\.cc/book/([^/]+)/?$",
                TitleSelector = "meta[property=\"og:title\"]",
                AuthorSelector = "#info > h1 > small > a",
                CoverSelector = "meta[property=\"og:image\"]"
            },
            Catalog = new()
            {
                UriTemplate = "https://www.ranwen8.cc/book/{bookId}/index_1.html",
                ItemSelector = "body > div:nth-child(4) > div > ul > li > a",
                NextPageSelector = "body > div:nth-child(4) > div > div > select > option"
            },
            Chapter = new()
            {
                TitleSelector = "#jsnc_l > div > h1",
                ContentSelector = "#htmlContent",
                BreakPattern = "<br>+",
                FilterTextPattern = "首发：~小÷说◎网】，♂小÷说◎网】，",
                NextPageSelector = "#link-next",
                ContentTransform = ChapterContentTransform.DecodeEmbeddedBase64Scripts
            }
        },
        new()
        {
            Id = Legacy18MhId,
            Name = "18mh小说网",
            BaseUri = new Uri("https://18mh.net/"),
            ParserKind = BookSourceParserKind.Legacy18MhWebView,
            Search = new()
            {
                UriTemplate = "https://18mh.net/novel/search/{keyword}",
                ResultSelector = "a[href*=\"/novel/detail/\"]",
                TitleLinkSelector = "a[href*=\"/novel/detail/\"]",
                Timeout = TimeSpan.FromSeconds(30)
            },
            Detail = new() { BookUrlPattern = @"^https://18mh\.net/novel/detail/([^/?#]+)" },
            Catalog = new() { ItemSelector = "a.detail-page__catalog-item[href]" },
            Chapter = new()
        }
    ];

    public static IReadOnlyList<BookSourceDefinition> Aggregated { get; } = All
        .Where(source => !string.Equals(source.Id, Legacy18MhId, StringComparison.OrdinalIgnoreCase))
        .ToArray();

    public static BookSourceDefinition GetRequired(string id)
        => All.FirstOrDefault(source => string.Equals(source.Id, id, StringComparison.OrdinalIgnoreCase))
           ?? throw new KeyNotFoundException($"未知书源：{id}");

    public static BookSourceDefinition? FindByBookUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out Uri? uri)) return null;

        return All.FirstOrDefault(source =>
            string.Equals(source.BaseUri.Host, uri.Host, StringComparison.OrdinalIgnoreCase));
    }

    private static IReadOnlyDictionary<string, string> Form(params (string Key, string Value)[] fields)
        => fields.ToDictionary(field => field.Key, field => field.Value, StringComparer.Ordinal);
}
