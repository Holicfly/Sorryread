using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;

namespace ReadAI;

public sealed class BookSourceParser : IDisposable
{
    private const int MaximumRequestAttempts = 2;
    private const int RetryDelayMilliseconds = 300;
    private const int MaximumCatalogPages = 100;
    private const int MaximumChapterContentPages = 20;
    private const string UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/136.0 Safari/537.36 ReadAI/1.0";
    private static readonly Regex CharsetRegex = new(
        "charset\\s*=\\s*[\\\"']?\\s*(?<charset>[a-zA-Z0-9._-]+)",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex EncodedChapterScriptRegex = new(
        "<script[^>]*>\\s*document\\.write(?:ln)?\\s*\\(\\s*qsbs\\.bb\\(\\s*['\\\"](?<payload>[^'\\\"]+)['\\\"]\\s*\\)\\s*\\)\\s*;?\\s*</script>",
        RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.Compiled);
    private static readonly Regex WxsyLeadingHiddenRegex = new(
        @"\.section-list\.ycxsid>li:nth-child\(\d+\)\{display:none\}",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex WxsyTrailingHiddenRegex = new(
        @"\.section-list\.ycxsid>li:nth-last-child\(\d+\)\{display:none\}",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;

    public BookSourceParser(HttpClient? httpClient = null)
    {
        _ownsHttpClient = httpClient is null;
        _httpClient = httpClient ?? CreateHttpClient();
    }

    public async Task<NovelSearchPage> SearchAsync(
        BookSourceDefinition source,
        string keyword,
        string? pageUrl = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (source.ParserKind != BookSourceParserKind.HttpRules)
        {
            throw new InvalidOperationException($"书源 {source.Name} 需要使用 WebView2 搜索器。");
        }

        string normalizedKeyword = keyword.Trim();
        if (normalizedKeyword.Length == 0) return new NovelSearchPage();

        Uri requestUri = string.IsNullOrWhiteSpace(pageUrl)
            ? BuildSearchUri(source.Search.UriTemplate, normalizedKeyword)
            : new Uri(pageUrl, UriKind.Absolute);

        FetchedPage page = await FetchAsync(
            () => BuildSearchRequest(source, requestUri, normalizedKeyword, pageUrl is not null),
            source.Search.Timeout,
            source.Name,
            cancellationToken);
        return ParseSearchPage(source, normalizedKeyword, page.Html, page.FinalUri);
    }

    public async Task<BookSourceBookPage> ResolveBookAsync(
        BookSourceDefinition source,
        string detailUrl,
        CancellationToken cancellationToken = default)
    {
        ValidateHttpSource(source);
        if (!Uri.TryCreate(detailUrl, UriKind.Absolute, out Uri? detailUri))
        {
            throw new InvalidOperationException("书籍详情网址无效。");
        }

        FetchedPage detailPage = await FetchGetAsync(source, detailUri, cancellationToken);
        HtmlParser parser = new();
        IDocument detailDocument = parser.ParseDocument(detailPage.Html);
        string title = ExtractText(Select(detailDocument.DocumentElement, source.Detail.TitleSelector));
        Uri catalogUri = BuildCatalogUri(source, detailPage.FinalUri, detailUri);

        FetchedPage catalogPage = SameRequestUrl(catalogUri, detailPage.FinalUri)
            ? detailPage
            : await FetchGetAsync(source, catalogUri, cancellationToken);
        (List<NovelChapterItem> chapters, string catalogWarning) = await ExtractCatalogAsync(
            source,
            catalogPage,
            cancellationToken);
        if (chapters.Count == 0)
        {
            throw new InvalidOperationException($"{source.Name} 的书籍页面未提取到章节目录。");
        }

        return new BookSourceBookPage
        {
            SourceId = source.Id,
            Title = title,
            DetailUrl = detailPage.FinalUri.AbsoluteUri,
            Chapters = chapters,
            CatalogWarning = catalogWarning
        };
    }

    public async Task<PageParseResult> ParseChapterAsync(
        BookSourceDefinition source,
        string chapterUrl,
        IReadOnlyList<NovelChapterItem> catalog,
        CancellationToken cancellationToken = default)
    {
        ValidateHttpSource(source);
        if (!Uri.TryCreate(chapterUrl, UriKind.Absolute, out Uri? startUri))
        {
            throw new InvalidOperationException("章节网址无效。");
        }

        int catalogIndex = FindChapterIndex(catalog, startUri.AbsoluteUri);
        string previousUrl = catalogIndex > 0 ? catalog[catalogIndex - 1].Url : string.Empty;
        string nextUrl = catalogIndex >= 0 && catalogIndex + 1 < catalog.Count
            ? catalog[catalogIndex + 1].Url
            : string.Empty;
        string fallbackTitle = catalogIndex >= 0 ? catalog[catalogIndex].Title : string.Empty;
        List<string> contentParts = [];
        HashSet<string> visited = new(StringComparer.OrdinalIgnoreCase);
        Uri pageUri = startUri;
        string title = string.Empty;

        for (int pageNumber = 1; pageNumber <= MaximumChapterContentPages; pageNumber++)
        {
            if (!visited.Add(NormalizeUrl(pageUri.AbsoluteUri)))
            {
                throw new InvalidOperationException($"{source.Name} 的正文分页出现循环链接。");
            }

            FetchedPage page = await FetchGetAsync(source, pageUri, cancellationToken);
            HtmlParser parser = new();
            IDocument document = parser.ParseDocument(page.Html);
            title = title.Length > 0
                ? title
                : ExtractText(Select(document.DocumentElement, source.Chapter.TitleSelector));
            string part = ExtractChapterText(document, source);
            if (part.Length > 0) contentParts.Add(part);

            Uri? continuation = ExtractChapterContinuation(document, source, page.FinalUri);
            if (continuation is null || IsNextChapterLink(
                    continuation.AbsoluteUri,
                    document,
                    source.Chapter.NextPageSelector,
                    catalog,
                    startUri.AbsoluteUri))
            {
                break;
            }
            if (pageNumber == MaximumChapterContentPages)
            {
                throw new InvalidOperationException($"{source.Name} 的正文分页超过安全上限。");
            }
            pageUri = continuation;
        }

        title = title.Length > 0 ? title : fallbackTitle;
        string text = NormalizeChapterText(string.Join("\n\n", contentParts), title, source.Chapter.FilterTextPattern);
        if (text.Length == 0)
        {
            throw new InvalidOperationException($"{source.Name} 的章节正文为空或解析规则已失效。");
        }

        return new PageParseResult
        {
            Title = title.Length > 0 ? title : "未命名章节",
            Text = text,
            PreviousUrl = previousUrl,
            NextUrl = nextUrl,
            SourceUrl = startUri.AbsoluteUri,
            IsContentReady = true
        };
    }

    internal static NovelSearchPage ParseSearchPage(
        BookSourceDefinition source,
        string keyword,
        string html,
        Uri pageUri)
    {
        HtmlParser parser = new();
        var document = parser.ParseDocument(html);
        List<NovelSearchResult> results = [];
        HashSet<string> seen = new(StringComparer.OrdinalIgnoreCase);

        foreach (IElement row in document.QuerySelectorAll(source.Search.ResultSelector))
        {
            IElement? titleElement = Select(row, source.Search.TitleLinkSelector);
            string title = ExtractText(titleElement);
            string url = ResolveElementUrl(titleElement, pageUri);
            if (title.Length == 0 || url.Length == 0 || !seen.Add(url)) continue;

            results.Add(new NovelSearchResult
            {
                SourceId = source.Id,
                SourceName = source.Name,
                Title = title,
                Url = url,
                Author = ExtractText(Select(row, source.Search.AuthorSelector)),
                Category = ExtractText(Select(row, source.Search.CategorySelector)),
                LatestChapter = ExtractText(Select(row, source.Search.LatestChapterSelector)),
                LastUpdateTime = ExtractText(Select(row, source.Search.LastUpdateTimeSelector)),
                Status = ExtractText(Select(row, source.Search.StatusSelector)),
                WordCount = ExtractText(Select(row, source.Search.WordCountSelector))
            });
        }

        string nextPageUrl = ExtractNextPageUrl(document, source.Search.NextPageSelector, pageUri);
        return new NovelSearchPage
        {
            Results = results,
            HasNext = nextPageUrl.Length > 0,
            NextPageUrl = nextPageUrl
        };
    }

    private async Task<(List<NovelChapterItem> Chapters, string Warning)> ExtractCatalogAsync(
        BookSourceDefinition source,
        FetchedPage firstPage,
        CancellationToken cancellationToken)
    {
        HtmlParser parser = new();
        IDocument firstDocument = parser.ParseDocument(firstPage.Html);
        List<Uri> pageUris = [firstPage.FinalUri];
        CatalogPageLinks firstLinks = ExtractCatalogPageLinks(
            firstDocument,
            source.Catalog.NextPageSelector,
            firstPage.FinalUri);
        if (firstLinks.IsOptionList)
        {
            foreach (Uri candidate in firstLinks.Urls)
            {
                RemoveUri(pageUris, candidate);
                pageUris.Add(candidate);
            }
        }

        Dictionary<string, (IDocument Document, Uri Uri)> cachedPages = new(StringComparer.OrdinalIgnoreCase)
        {
            [NormalizeUrl(firstPage.FinalUri.AbsoluteUri)] = (firstDocument, firstPage.FinalUri)
        };
        List<NovelChapterItem> chapters = [];
        HashSet<string> chapterUrls = new(StringComparer.OrdinalIgnoreCase);
        string catalogWarning = string.Empty;

        for (int pageIndex = 0; pageIndex < pageUris.Count; pageIndex++)
        {
            if (pageIndex >= MaximumCatalogPages)
            {
                throw new InvalidOperationException($"{source.Name} 的目录分页超过安全上限。");
            }

            Uri pageUri = pageUris[pageIndex];
            string pageKey = NormalizeUrl(pageUri.AbsoluteUri);
            if (!cachedPages.TryGetValue(pageKey, out (IDocument Document, Uri Uri) page))
            {
                FetchedPage fetched;
                try
                {
                    fetched = await FetchGetAsync(source, pageUri, cancellationToken);
                }
                catch (Exception exception) when (pageIndex > 0 &&
                    exception is HttpRequestException or TimeoutException)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    catalogWarning = $"第 {pageIndex + 1} 页目录加载失败，后续章节可能缺失。";
                    break;
                }
                page = (parser.ParseDocument(fetched.Html), fetched.FinalUri);
                cachedPages[pageKey] = page;
            }

            List<IElement> elements = ExtractCatalogElements(page.Document, source);
            IEnumerable<IElement> orderedElements = source.Catalog.IsDescending
                ? elements.AsEnumerable().Reverse()
                : elements;
            foreach (IElement element in orderedElements)
            {
                string url = ResolveElementUrl(element, page.Uri);
                string chapterTitle = ExtractText(element);
                if (url.Length == 0 || chapterTitle.Length == 0 || !chapterUrls.Add(NormalizeUrl(url))) continue;
                chapters.Add(new NovelChapterItem { Title = chapterTitle, Url = url });
            }

            if (!firstLinks.IsOptionList)
            {
                CatalogPageLinks links = ExtractCatalogPageLinks(
                    page.Document,
                    source.Catalog.NextPageSelector,
                    page.Uri);
                Uri? nextPage = links.Urls.FirstOrDefault(candidate =>
                    pageUris.All(existing => !SameRequestUrl(existing, candidate)));
                if (nextPage is not null) pageUris.Add(nextPage);
            }
        }

        return (chapters, catalogWarning);
    }

    private async Task<FetchedPage> FetchGetAsync(
        BookSourceDefinition source,
        Uri uri,
        CancellationToken cancellationToken)
        => await FetchAsync(
            () => BuildGetRequest(source, uri),
            source.Search.Timeout,
            source.Name,
            cancellationToken);

    private async Task<FetchedPage> FetchAsync(
        Func<HttpRequestMessage> requestFactory,
        TimeSpan timeoutValue,
        string sourceName,
        CancellationToken cancellationToken)
    {
        Exception? lastError = null;
        for (int attempt = 1; attempt <= MaximumRequestAttempts; attempt++)
        {
            using HttpRequestMessage request = requestFactory();
            using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(timeoutValue);
            try
            {
                using HttpResponseMessage response = await _httpClient.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    timeout.Token);
                response.EnsureSuccessStatusCode();
                byte[] bytes = await response.Content.ReadAsByteArrayAsync(timeout.Token);
                string html = DecodeHtml(bytes, response.Content.Headers);
                Uri finalUri = response.RequestMessage?.RequestUri ?? request.RequestUri
                    ?? throw new InvalidOperationException("网络响应缺少最终网址。");
                return new FetchedPage(html, finalUri);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (OperationCanceledException)
            {
                lastError = new TimeoutException($"书源 {sourceName} 请求超时（{timeoutValue.TotalSeconds:0} 秒）。");
            }
            catch (HttpRequestException exception)
            {
                lastError = exception;
            }

            if (attempt < MaximumRequestAttempts)
            {
                await Task.Delay(RetryDelayMilliseconds * attempt, cancellationToken);
            }
        }

        throw lastError ?? new HttpRequestException($"书源 {sourceName} 请求失败。");
    }

    private static HttpClient CreateHttpClient()
    {
        SocketsHttpHandler handler = new()
        {
            AutomaticDecompression = DecompressionMethods.All,
            AllowAutoRedirect = true,
            ConnectTimeout = TimeSpan.FromSeconds(10),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5)
        };
        HttpClient client = new(handler) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("text/html"));
        client.DefaultRequestHeaders.AcceptLanguage.ParseAdd("zh-CN,zh;q=0.9,en;q=0.6");
        return client;
    }

    private static HttpRequestMessage BuildSearchRequest(
        BookSourceDefinition source,
        Uri requestUri,
        string keyword,
        bool isPaginationRequest)
    {
        BookSourceSearchRule rule = source.Search;
        HttpMethod method = isPaginationRequest || rule.Method == BookSourceHttpMethod.Get
            ? HttpMethod.Get
            : HttpMethod.Post;
        HttpRequestMessage request = new(method, requestUri)
        {
            Headers = { Referrer = source.BaseUri }
        };

        if (method == HttpMethod.Post)
        {
            request.Content = new FormUrlEncodedContent(rule.FormFields.Select(field =>
                new KeyValuePair<string, string>(field.Key, ReplaceKeyword(field.Value, keyword))));
        }
        if (!string.IsNullOrWhiteSpace(rule.CookieHeader))
        {
            request.Headers.TryAddWithoutValidation("Cookie", rule.CookieHeader);
        }

        return request;
    }

    private static HttpRequestMessage BuildGetRequest(BookSourceDefinition source, Uri uri)
    {
        HttpRequestMessage request = new(HttpMethod.Get, uri)
        {
            Headers = { Referrer = source.BaseUri }
        };
        if (!string.IsNullOrWhiteSpace(source.Search.CookieHeader))
        {
            request.Headers.TryAddWithoutValidation("Cookie", source.Search.CookieHeader);
        }
        return request;
    }

    private static Uri BuildSearchUri(string template, string keyword)
    {
        string encodedKeyword = Uri.EscapeDataString(keyword);
        return new Uri(ReplaceKeyword(template, encodedKeyword), UriKind.Absolute);
    }

    private static string ReplaceKeyword(string value, string keyword)
        => value.Replace("{keyword}", keyword, StringComparison.Ordinal);

    private static IElement? Select(IElement parent, string selector)
    {
        if (string.IsNullOrWhiteSpace(selector)) return null;
        return parent.Matches(selector) ? parent : parent.QuerySelector(selector);
    }

    private static Uri BuildCatalogUri(BookSourceDefinition source, Uri detailUri, Uri originalDetailUri)
    {
        if (string.IsNullOrWhiteSpace(source.Catalog.UriTemplate)) return detailUri;
        if (string.IsNullOrWhiteSpace(source.Detail.BookUrlPattern))
        {
            throw new InvalidOperationException($"{source.Name} 缺少书籍编号提取规则。");
        }

        Match match = Regex.Match(detailUri.AbsoluteUri, source.Detail.BookUrlPattern, RegexOptions.IgnoreCase);
        if (!match.Success)
        {
            match = Regex.Match(originalDetailUri.AbsoluteUri, source.Detail.BookUrlPattern, RegexOptions.IgnoreCase);
        }
        if (!match.Success || match.Groups.Count < 2 || match.Groups[1].Value.Length == 0)
        {
            throw new InvalidOperationException($"{source.Name} 无法从详情网址识别书籍编号。");
        }
        return new Uri(source.Catalog.UriTemplate.Replace("{bookId}", match.Groups[1].Value, StringComparison.Ordinal));
    }

    private static CatalogPageLinks ExtractCatalogPageLinks(
        IParentNode document,
        string selector,
        Uri pageUri)
    {
        if (string.IsNullOrWhiteSpace(selector)) return new CatalogPageLinks(false, []);
        List<IElement> elements = document.QuerySelectorAll(selector).ToList();
        bool isOptionList = elements.Any(element =>
            string.Equals(element.LocalName, "option", StringComparison.OrdinalIgnoreCase));
        List<Uri> urls = elements
            .Select(element => ResolveElementUri(element, pageUri))
            .Where(uri => uri is not null)
            .Cast<Uri>()
            .DistinctBy(uri => NormalizeUrl(uri.AbsoluteUri), StringComparer.OrdinalIgnoreCase)
            .ToList();
        return new CatalogPageLinks(isOptionList, urls);
    }

    private static List<IElement> ExtractCatalogElements(IDocument document, BookSourceDefinition source)
    {
        List<IElement> elements = document.QuerySelectorAll(source.Catalog.ItemSelector).ToList();
        if (source.Catalog.HtmlTransform != CatalogHtmlTransform.WxsyVisibleItems || elements.Count == 0)
        {
            return elements;
        }

        string html = document.DocumentElement?.OuterHtml ?? string.Empty;
        int leadingHiddenCount = WxsyLeadingHiddenRegex.Matches(html).Count;
        int trailingHiddenCount = WxsyTrailingHiddenRegex.Matches(html).Count;
        int visibleCount = elements.Count - leadingHiddenCount - trailingHiddenCount;
        return visibleCount > 0
            ? elements.Skip(leadingHiddenCount).Take(visibleCount).ToList()
            : [];
    }

    private static string ExtractChapterText(IDocument document, BookSourceDefinition source)
    {
        List<IElement> contentElements = document.QuerySelectorAll(source.Chapter.ContentSelector).ToList();
        if (contentElements.Count == 0)
        {
            throw new InvalidOperationException($"{source.Name} 未找到正文节点。");
        }

        string html = contentElements.Count == 1
            ? contentElements[0].InnerHtml
            : string.Join("\n", contentElements.Select(element => $"<p>{element.InnerHtml}</p>"));
        html = source.Chapter.ContentTransform switch
        {
            ChapterContentTransform.DecodeBase64Payload => DecodeBase64Payloads(html, requirePayload: true),
            ChapterContentTransform.DecodeEmbeddedBase64Scripts => DecodeEmbeddedBase64Scripts(html),
            _ => html
        };

        HtmlParser parser = new();
        IDocument fragment = parser.ParseDocument($"<body>{html}</body>");
        if (!string.IsNullOrWhiteSpace(source.Chapter.RemoveSelectors))
        {
            foreach (IElement element in fragment.QuerySelectorAll(source.Chapter.RemoveSelectors).ToArray())
            {
                element.Remove();
            }
        }

        string cleanedHtml = fragment.Body?.InnerHtml ?? html;
        cleanedHtml = Regex.Replace(cleanedHtml, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
        cleanedHtml = Regex.Replace(
            cleanedHtml,
            @"</(?:p|div|section|article|li|dd|dt|h[1-6]|blockquote|pre)\s*>",
            "\n",
            RegexOptions.IgnoreCase);
        cleanedHtml = Regex.Replace(cleanedHtml, @"<[^>]+>", string.Empty, RegexOptions.Singleline);
        return NormalizePlainText(WebUtility.HtmlDecode(cleanedHtml));
    }

    private static Uri? ExtractChapterContinuation(
        IParentNode document,
        BookSourceDefinition source,
        Uri pageUri)
    {
        if (string.IsNullOrWhiteSpace(source.Chapter.NextPageSelector)) return null;
        IElement? element = document.QuerySelector(source.Chapter.NextPageSelector);
        return ResolveElementUri(element, pageUri);
    }

    private static bool IsNextChapterLink(
        string candidateUrl,
        IParentNode document,
        string selector,
        IReadOnlyList<NovelChapterItem> catalog,
        string currentChapterUrl)
    {
        string candidate = NormalizeUrl(candidateUrl);
        if (catalog.Any(chapter =>
                !string.Equals(NormalizeUrl(chapter.Url), NormalizeUrl(currentChapterUrl), StringComparison.OrdinalIgnoreCase) &&
                string.Equals(NormalizeUrl(chapter.Url), candidate, StringComparison.OrdinalIgnoreCase)))
        {
            return true;
        }

        string text = string.IsNullOrWhiteSpace(selector)
            ? string.Empty
            : Normalize(document.QuerySelector(selector)?.TextContent ?? string.Empty);
        bool saysNextChapter = Regex.IsMatch(text, "下一章|没有了|书末页|>>", RegexOptions.IgnoreCase);
        bool looksLikeContentPage = Regex.IsMatch(candidateUrl, @".*[-_]\d\.html(?:[?#].*)?$", RegexOptions.IgnoreCase);
        return saysNextChapter && !looksLikeContentPage;
    }

    private static string DecodeBase64Payloads(string html, bool requirePayload)
    {
        MatchCollection matches = EncodedChapterScriptRegex.Matches(html);
        if (matches.Count == 0)
        {
            if (requirePayload) throw new InvalidOperationException("正文 Base64 数据缺失。");
            return html;
        }
        return string.Concat(matches.Select(match => DecodeBase64(match.Groups["payload"].Value)));
    }

    private static string DecodeEmbeddedBase64Scripts(string html)
        => EncodedChapterScriptRegex.Replace(html, match => DecodeBase64(match.Groups["payload"].Value));

    private static string DecodeBase64(string value)
    {
        string normalized = Regex.Replace(value, @"[^A-Za-z0-9+/=]", string.Empty);
        int remainder = normalized.Length % 4;
        if (remainder > 0) normalized = normalized.PadRight(normalized.Length + 4 - remainder, '=');
        try
        {
            return Encoding.UTF8.GetString(Convert.FromBase64String(normalized));
        }
        catch (FormatException exception)
        {
            throw new InvalidOperationException("正文 Base64 数据格式无效。", exception);
        }
    }

    private static string NormalizeChapterText(string text, string title, string filterPattern)
    {
        string result = text;
        if (!string.IsNullOrWhiteSpace(filterPattern))
        {
            result = Regex.Replace(result, filterPattern, string.Empty,
                RegexOptions.IgnoreCase | RegexOptions.Singleline);
        }
        result = NormalizePlainText(result);
        string normalizedTitle = Normalize(title);
        if (normalizedTitle.Length > 0 && result.StartsWith(normalizedTitle, StringComparison.OrdinalIgnoreCase))
        {
            result = result[normalizedTitle.Length..].TrimStart();
        }
        return result;
    }

    private static string NormalizePlainText(string value)
    {
        string cleaned = Regex.Replace(value, "[\\uE000-\\uF8FF\\uFFF0-\\uFFFF\\uFFFD]", string.Empty)
            .Replace('\u00A0', ' ')
            .Replace("\r", "\n", StringComparison.Ordinal);
        List<string> lines = cleaned.Split('\n')
            .Select(line => Regex.Replace(line, @"[ \t]+", " ").Trim())
            .ToList();
        List<string> normalized = [];
        bool previousBlank = false;
        foreach (string line in lines)
        {
            bool blank = line.Length == 0;
            if (!blank || !previousBlank) normalized.Add(line);
            previousBlank = blank;
        }
        return string.Join('\n', normalized).Trim();
    }

    private static int FindChapterIndex(IReadOnlyList<NovelChapterItem> catalog, string url)
    {
        string normalized = NormalizeUrl(url);
        for (int index = 0; index < catalog.Count; index++)
        {
            if (string.Equals(NormalizeUrl(catalog[index].Url), normalized, StringComparison.OrdinalIgnoreCase))
            {
                return index;
            }
        }
        return -1;
    }

    private static string DecodeHtml(byte[] bytes, HttpContentHeaders headers)
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        string? charset = headers.ContentType?.CharSet?.Trim().Trim('"', '\'');
        if (string.IsNullOrWhiteSpace(charset))
        {
            string head = Encoding.ASCII.GetString(bytes, 0, Math.Min(bytes.Length, 4096));
            charset = CharsetRegex.Match(head).Groups["charset"].Value;
        }
        if (string.Equals(charset, "gb2312", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(charset, "gbk", StringComparison.OrdinalIgnoreCase))
        {
            charset = "gb18030";
        }

        try
        {
            Encoding encoding = string.IsNullOrWhiteSpace(charset)
                ? new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: false)
                : Encoding.GetEncoding(charset);
            return encoding.GetString(bytes).TrimStart('\uFEFF');
        }
        catch (ArgumentException)
        {
            return Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF');
        }
    }

    private static void ValidateHttpSource(BookSourceDefinition source)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (source.ParserKind != BookSourceParserKind.HttpRules)
        {
            throw new InvalidOperationException($"书源 {source.Name} 需要使用 WebView2 解析器。");
        }
    }

    private static Uri? ResolveElementUri(IElement? element, Uri baseUri)
    {
        string url = ResolveElementUrl(element, baseUri);
        return Uri.TryCreate(url, UriKind.Absolute, out Uri? result) ? result : null;
    }

    private static bool SameRequestUrl(Uri left, Uri right)
        => string.Equals(NormalizeUrl(left.AbsoluteUri), NormalizeUrl(right.AbsoluteUri), StringComparison.OrdinalIgnoreCase);

    private static string NormalizeUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out Uri? uri)) return value.Trim();
        return uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
    }

    private static void RemoveUri(List<Uri> urls, Uri candidate)
        => urls.RemoveAll(uri => SameRequestUrl(uri, candidate));

    private static string ExtractText(IElement? element)
    {
        if (element is null) return string.Empty;
        string value = string.Equals(element.LocalName, "meta", StringComparison.OrdinalIgnoreCase)
            ? element.GetAttribute("content") ?? string.Empty
            : element.TextContent;
        return Normalize(value);
    }

    private static string ResolveElementUrl(IElement? element, Uri baseUri)
    {
        if (element is null) return string.Empty;
        string? value = element.GetAttribute("href") ?? element.GetAttribute("value");
        if (string.IsNullOrWhiteSpace(value) || value.StartsWith("javascript:", StringComparison.OrdinalIgnoreCase))
        {
            return string.Empty;
        }

        return Uri.TryCreate(baseUri, WebUtility.HtmlDecode(value.Trim()), out Uri? result)
            ? result.GetComponents(UriComponents.HttpRequestUrl, UriFormat.UriEscaped)
            : string.Empty;
    }

    private static string ExtractNextPageUrl(IParentNode document, string selector, Uri pageUri)
    {
        if (string.IsNullOrWhiteSpace(selector)) return string.Empty;
        List<(IElement Element, string Url)> candidates = document.QuerySelectorAll(selector)
            .Select(element => (Element: element, Url: ResolveElementUrl(element, pageUri)))
            .Where(candidate => candidate.Url.Length > 0 &&
                                !string.Equals(candidate.Url, pageUri.AbsoluteUri, StringComparison.OrdinalIgnoreCase))
            .ToList();
        if (candidates.Count == 0) return string.Empty;

        (IElement Element, string Url) preferred = candidates.FirstOrDefault(candidate =>
            Normalize(candidate.Element.TextContent) is "下一页" or "下页" or "Next" or "next" or "›" or "»");
        return string.IsNullOrWhiteSpace(preferred.Url) ? candidates[0].Url : preferred.Url;
    }

    private static string Normalize(string value)
        => string.Join(' ', value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim();

    private sealed record FetchedPage(string Html, Uri FinalUri);

    private sealed record CatalogPageLinks(bool IsOptionList, List<Uri> Urls);

    public void Dispose()
    {
        if (_ownsHttpClient) _httpClient.Dispose();
    }
}
