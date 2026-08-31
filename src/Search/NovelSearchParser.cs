using System.Text.Json;
using Microsoft.Web.WebView2.Wpf;

namespace ReadAI;

public sealed class NovelSearchParser
{
    private const string SearchUrlPrefix = "https://18mh.net/novel/search/";

    // The site renders book cards as links to /novel/detail/{id}.  Reading only
    // those links keeps authors, categories, navigation and image-only links
    // out of the compact result list.
    private const string ResultExtractionScript = """
        (() => {
          const normalize = value => (value || '')
            .replace(/\s+/g, ' ')
            .trim();
          const results = [];
          const seen = new Set();
          document.querySelectorAll('a[href*="/novel/detail/"]').forEach(anchor => {
            let url;
            try {
              url = new URL(anchor.href, location.href);
            } catch {
              return;
            }
            if (url.hostname !== location.hostname || !/^\/novel\/detail\/[^/?#]+\/?$/.test(url.pathname)) return;
            if (seen.has(url.href)) return;

            const title = normalize(
              anchor.querySelector('img[alt]')?.getAttribute('alt') ||
              anchor.querySelector('h1, h2, h3, h4')?.textContent ||
              anchor.getAttribute('title') ||
              anchor.textContent
            );
            if (!title) return;

            seen.add(url.href);
            results.push({ title, url: url.href });
          });
          const hasNext = Array.from(document.querySelectorAll('a.pager-item, a[rel="next"]'))
            .some(anchor => /^(下一页|next|›|»)$/i.test(normalize(anchor.innerText || anchor.textContent)));
          return JSON.stringify({ results: results.slice(0, 100), hasNext });
        })()
        """;

    // Detail pages can contain many chapter and recommendation links.  Prefer
    // the actual reading entry by its visible action text, then require that it
    // points to a same-site novel chapter rather than a book detail page.
    private const string ReadingEntryExtractionScript = """
        (() => {
          const normalize = value => (value || '').replace(/\s+/g, ' ').trim();
          const current = new URL(location.href);
          let best = null;

          document.querySelectorAll('a[href]').forEach(anchor => {
            let url;
            try {
              url = new URL(anchor.href, current);
            } catch {
              return;
            }
            if (url.hostname !== current.hostname || !/^\/novel_chapter\/[^/?#]+\/[^/?#]+\.html$/.test(url.pathname)) return;

            const text = normalize(anchor.innerText || anchor.textContent);
            const classInfo = `${anchor.id || ''} ${typeof anchor.className === 'string' ? anchor.className : ''}`.toLowerCase();
            let score = 0;
            if (/^开始阅读$/.test(text)) score += 1000;
            else if (/(开始|立即).{0,4}(阅读|阅览)|阅读全文|read now|start reading/i.test(text)) score += 800;
            if (/(start|read|chapter)/i.test(classInfo)) score += 60;
            if (/\/1\.html$/.test(url.pathname)) score += 20;
            if (!best || score > best.score) best = { url: url.href, score };
          });

          return JSON.stringify(best?.url || '');
        })()
        """;

    // Catalog entries are present in the detail page DOM even when the site's
    // "view all" section is visually collapsed. Restrict extraction to
    // same-origin novel chapter links and preserve their document order.
    private const string ChapterCatalogExtractionScript = """
        (() => {
          const normalize = value => (value || '').replace(/\s+/g, ' ').trim();
          const current = new URL(location.href);
          const chapters = [];
          const seen = new Set();

          const catalogAnchors = Array.from(document.querySelectorAll('a.detail-page__catalog-item[href]'));
          const anchors = catalogAnchors.length > 0
            ? catalogAnchors
            : Array.from(document.querySelectorAll('a[href*="/novel_chapter/"]'));

          anchors.forEach(anchor => {
            let url;
            try {
              url = new URL(anchor.href, current);
              url.hash = '';
            } catch {
              return;
            }
            if (url.hostname !== current.hostname ||
                !/^\/novel_chapter\/[^/?#]+\/[^/?#]+\.html$/.test(url.pathname) ||
                seen.has(url.href)) return;

            const badge = normalize(anchor.querySelector('.detail-page__chapter-badge')?.textContent);
            const chapterTitle = normalize(anchor.querySelector('.detail-page__chapter-title')?.textContent);
            const fallback = normalize(anchor.getAttribute('title') || anchor.textContent);
            let title = chapterTitle || badge || fallback;
            if (badge && chapterTitle && chapterTitle !== badge && !chapterTitle.startsWith(badge)) {
              title = `${badge} ${chapterTitle}`;
            }
            if (!title) return;

            seen.add(url.href);
            chapters.push({ title, url: url.href });
          });

          return JSON.stringify(chapters.slice(0, 5000));
        })()
        """;

    public static string CreateSearchUrl(string keyword, int page = 1)
    {
        string url = SearchUrlPrefix + Uri.EscapeDataString(keyword.Trim());
        return page > 1 ? $"{url}/page/{page}" : url;
    }

    public async Task<NovelSearchPage> ExtractPageAsync(WebView2 webView)
    {
        string raw = await webView.ExecuteScriptAsync(ResultExtractionScript);
        string json = JsonSerializer.Deserialize<string>(raw) ?? "{}";
        NovelSearchPage page = JsonSerializer.Deserialize<NovelSearchPage>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        }) ?? new NovelSearchPage();
        foreach (NovelSearchResult result in page.Results)
        {
            result.SourceId = BookSourceCatalog.Legacy18MhId;
            result.SourceName = BookSourceCatalog.GetRequired(BookSourceCatalog.Legacy18MhId).Name;
        }
        return page;
    }

    public async Task<string> ExtractReadingUrlAsync(WebView2 webView)
    {
        string raw = await webView.ExecuteScriptAsync(ReadingEntryExtractionScript);
        string json = JsonSerializer.Deserialize<string>(raw) ?? "\"\"";
        return JsonSerializer.Deserialize<string>(json) ?? string.Empty;
    }

    public async Task<List<NovelChapterItem>> ExtractChapterCatalogAsync(WebView2 webView)
    {
        string raw = await webView.ExecuteScriptAsync(ChapterCatalogExtractionScript);
        string json = JsonSerializer.Deserialize<string>(raw) ?? "[]";
        return JsonSerializer.Deserialize<List<NovelChapterItem>>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        }) ?? [];
    }
}
