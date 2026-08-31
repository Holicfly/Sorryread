using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Web.WebView2.Wpf;

namespace ReadAI;

public sealed class PageParser
{
    private const int MinimumUsefulTextLength = 80;
    private const int LazyLoadStepDelayMilliseconds = 700;
    private const int LazyLoadStabilityRounds = 3;
    private const int LazyLoadMaximumDurationMilliseconds = 45000;
    private const int LazyLoadHeightChangeThreshold = 48;

    // The browser-side routine favours the densest semantic content container,
    // then serializes its real paragraph and line-break structure.
    private static readonly string ExtractionScript = """
        (() => {
          const ignored = [
            'script', 'style', 'noscript', 'template', 'svg', 'canvas', 'iframe',
            'img', 'picture', 'video', 'audio', 'nav', 'header', 'footer', 'aside',
            'form', 'button', 'input', 'select', 'textarea',
            '[class*="advert"]', '[class*="banner"]', '[class*="recommend"]',
            '[class*="related"]', '[class*="share"]', '[class*="rank"]',
            '[class*="search"]', '[class*="catalog"]', '[class*="navigation"]',
            '[class*="chapter_bottom"]', '[class~="iconfont"]', '[class~="fa"]',
            '[class^="fa-"]', '[onclick*="togglePostComment"]',
            '[onclick*="toggleComment"]', '[id*="advert"]', '[id*="recommend"]'
          ].join(',');
          const contentName = /(chapter|article|entry|post|read|reader|book|novel|content|text|body)/i;
          const strongContentName = /(article[-_]?body|entry[-_]?content|post[-_]?content|chapter[-_]?content|read[-_]?content|reader[-_]?content|book[-_]?content|novel[-_]?content|articlebody|entrycontent|postcontent|chaptercontent|readcontent|readercontent|bookcontent|novelcontent)/i;
          const noisyName = /(header|footer|nav|menu|sidebar|crumb|toolbar|control|pagination|catalog|advert|banner|notice|modal|search|login|register|recommend|rank|hot|related)/i;
          const normalize = value => (value || '')
            .replace(/[\uE000-\uF8FF\uFFF0-\uFFFF\uFFFD]/g, '')
            .replace(/\u00a0/g, ' ')
            .replace(/\r/g, '\n')
            .replace(/[ \t]+\n/g, '\n')
            .replace(/\n[ \t]+/g, '\n')
            .replace(/[ \t]{2,}/g, ' ')
            .replace(/\n{3,}/g, '\n\n')
            .split('\n')
            .map(line => line.trim())
            .filter(line => !/^\d{1,4}$/.test(line))
            .join('\n')
            .replace(/\n{3,}/g, '\n\n')
            .trim();
          const visible = element => {
            if (!element) return false;
            for (let current = element; current && current.nodeType === Node.ELEMENT_NODE; current = current.parentElement) {
              const style = window.getComputedStyle(current);
              if (current.hidden || current.getAttribute('aria-hidden') === 'true' ||
                  style.display === 'none' || style.visibility === 'hidden' ||
                  style.visibility === 'collapse' || Number.parseFloat(style.opacity || '1') === 0) {
                return false;
              }
            }
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };
          const classInfo = element => `${element.id || ''} ${typeof element.className === 'string' ? element.className : ''}`.toLowerCase();
          // Editors sometimes place empty semantic paragraphs inside <pre> or
          // other text containers. innerText does not reliably preserve those
          // empty elements, so convert them to explicit paragraph separators
          // before serializing the cloned content.
          const preserveEmptyParagraphSeparators = clone => {
            clone.querySelectorAll('p').forEach(paragraph => {
              const text = (paragraph.textContent || '').replace(/[\s\u00a0\u200b\ufeff]/g, '');
              const hasMeaningfulChild = paragraph.querySelector('img, picture, video, audio, iframe, svg, canvas, table, hr');
              if (!text && !hasMeaningfulChild) {
                paragraph.replaceWith(document.createTextNode('\n\n'));
              }
            });
          };
          const cloneText = element => {
            if (!element) return '';
            const clone = element.cloneNode(true);
            clone.querySelectorAll(ignored).forEach(node => node.remove());
            preserveEmptyParagraphSeparators(clone);
            return normalize(clone.innerText || clone.textContent || '');
          };
          const ownBlockText = element => {
            if (!element) return '';
            const clone = element.cloneNode(true);
            clone.querySelectorAll(ignored).forEach(node => node.remove());
            preserveEmptyParagraphSeparators(clone);
            clone.querySelectorAll('br').forEach(node => node.replaceWith('\n'));
            return normalize(clone.innerText || clone.textContent || '');
          };
          const renderedBlockSelector = 'p, pre, blockquote, div, section, li, dd, dt, td';
          // Some forums use anonymous-looking div/table cells as paragraphs.
          // Select the innermost visible flow blocks with meaningful text, so a
          // nested page layout never becomes one giant paragraph.
          const visualElementBlocks = element => {
            if (!element) return [];
            const candidates = Array.from(element.querySelectorAll(renderedBlockSelector))
              .filter(visible)
              .filter(node => !hasNoisyAncestor(node, element))
              .map(node => ({ node, text: ownBlockText(node) }))
              .filter(candidate => candidate.text.length >= 16)
              .filter(candidate => {
                const style = getComputedStyle(candidate.node);
                return style.display !== 'inline' && style.display !== 'contents';
              });
            const leafCandidates = candidates.filter(candidate => !candidates.some(other =>
              other.node !== candidate.node && candidate.node.contains(other.node) && other.text.length >= 16));
            return leafCandidates.map(candidate => candidate.text);
          };
          // A final fallback for content stored in one element but separated by
          // rendered blank space rather than child block elements.
          const visualTextBlocks = element => {
            if (!element) return [];
            const blocks = [];
            let block = '';
            let previous = null;
            const append = value => {
              if (!block) {
                block = value;
                return;
              }
              if (/[A-Za-z0-9]$/.test(block) && /^[A-Za-z0-9]/.test(value)) {
                block += ' ';
              }
              block += value;
            };
            const finishBlock = () => {
              const value = normalize(block);
              if (value) blocks.push(value);
              block = '';
            };
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
            let textNode;
            while ((textNode = walker.nextNode())) {
              const parent = textNode.parentElement;
              if (!parent || !visible(parent) || parent.closest(ignored) || hasNoisyAncestor(parent, element)) continue;
              const value = (textNode.nodeValue || '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
              if (!value) continue;
              const range = document.createRange();
              range.selectNodeContents(textNode);
              const rects = Array.from(range.getClientRects()).filter(rect => rect.width > 0 && rect.height > 0);
              if (!rects.length) continue;
              const first = rects[0];
              const last = rects[rects.length - 1];
              const visualGap = previous
                ? first.top - previous.bottom > Math.max(8, Math.min(first.height, previous.height) * 0.65)
                : false;
              if (visualGap) finishBlock();
              append(value);
              previous = { bottom: last.bottom, height: last.height };
            }
            finishBlock();
            return blocks;
          };
          const depthOf = element => {
            let depth = 0;
            for (let current = element; current && current !== document.body; current = current.parentElement) depth++;
            return depth;
          };
          const hasNoisyAncestor = (element, boundary) => {
            for (let current = element.parentElement; current && current !== boundary.parentElement; current = current.parentElement) {
              if (noisyName.test(classInfo(current))) return true;
            }
            return false;
          };
          const candidates = [];
          const seen = new Set();
          const addCandidate = element => {
            if (!element || seen.has(element) || !visible(element)) return;
            const name = classInfo(element);
            if (noisyName.test(name) && !strongContentName.test(name)) return;
            const text = cloneText(element);
            if (text.length < 60) return;
            seen.add(element);
            candidates.push({ element, text, name });
          };
          [
            '[itemprop="articleBody"]', '[role="main"]', 'article', 'main',
            '[class*="article-body"]', '[class*="articleBody"]',
            '[class*="article-content"]', '[class*="articleContent"]',
            '[class*="entry-content"]', '[class*="entryContent"]',
            '[class*="post-content"]', '[class*="postContent"]',
            '[class*="chapter-content"]', '[class*="chapterContent"]',
            '[class*="read-content"]', '[class*="readContent"]',
            '[class*="reader-content"]', '[class*="readerContent"]',
            '[class*="book-content"]', '[class*="bookContent"]',
            '[class*="novel-content"]', '[class*="novelContent"]',
            '[class*="text-wrap"]', '[class*="textWrap"]',
            '#content', '#chapter-content', '#chapterContent', '#read-content',
            '#readContent', '#BookText', '#booktext', '#content-body', '#contentBody'
          ].forEach(selector => {
            try { document.querySelectorAll(selector).forEach(addCandidate); } catch (_) { }
          });
          document.querySelectorAll('div, section, main, article').forEach(element => {
            if (candidates.length < 1200) addCandidate(element);
          });
          const scoreCandidate = candidate => {
            const { element, text, name } = candidate;
            const paragraphs = Array.from(element.querySelectorAll('p, pre, blockquote'))
              .filter(visible)
              .filter(node => !hasNoisyAncestor(node, element));
            const paragraphLength = paragraphs.reduce((sum, node) => sum + ownBlockText(node).length, 0);
            const breaks = element.querySelectorAll('br').length;
            const linkLength = Array.from(element.querySelectorAll('a'))
              .reduce((sum, node) => sum + cloneText(node).length, 0);
            const headings = element.querySelectorAll('h1, h2, h3, [role="heading"]').length;
            let score = Math.min(text.length, 160000) + Math.min(paragraphLength, 160000) * 0.8;
            score += Math.min(paragraphs.length, 1000) * 260 + Math.min(breaks, 4000) * 25;
            score += depthOf(element) * 110;
            if (strongContentName.test(name)) score += 50000;
            else if (contentName.test(name)) score += 9000;
            if (noisyName.test(name)) score -= 18000;
            score -= Math.min(text.length * 0.72, linkLength * 1.7);
            score -= headings * 180;
            return score;
          };
          const best = candidates
            .map(candidate => ({ ...candidate, score: scoreCandidate(candidate) }))
            .sort((left, right) => right.score - left.score)[0]?.element || document.body;
          const isExplicitContentRoot = strongContentName.test(classInfo(best));
          const semanticBlocks = Array.from(best.querySelectorAll('p, pre, blockquote'))
            .filter(visible)
            .filter(node => !hasNoisyAncestor(node, best))
            .map(node => ownBlockText(node))
            .filter(Boolean);
          const semanticBlockLength = semanticBlocks.reduce((sum, block) => sum + block.length, 0);
          const rootLength = cloneText(best).length;
          const useSemanticBlocks = semanticBlocks.length >= 2 && semanticBlockLength >= 60 &&
            (rootLength === 0 || semanticBlockLength >= rootLength * 0.35);
          const elementBlocks = useSemanticBlocks ? [] : visualElementBlocks(best);
          const elementBlockLength = elementBlocks.reduce((sum, block) => sum + block.length, 0);
          const useElementBlocks = elementBlocks.length >= 2 && elementBlockLength >= Math.min(rootLength * 0.25, 120);
          const visualBlocks = useSemanticBlocks || useElementBlocks ? [] : visualTextBlocks(best);
          const blocks = useSemanticBlocks ? semanticBlocks : useElementBlocks ? elementBlocks : visualBlocks;
          const blockLength = blocks.reduce((sum, block) => sum + block.length, 0);
          const longBlockCount = blocks.filter(block => block.length >= 180).length;
          const useParagraphBlocks = blocks.length >= 2 && blockLength >= 60;
          const bodyText = useParagraphBlocks
            ? blocks
                .filter(block => isExplicitContentRoot || longBlockCount < 2 || block.length >= 12 || blockLength >= rootLength * 0.78)
                .join('\n\n')
            : cloneText(best);
          const bodyLineCount = bodyText.split('\n').filter(line => line.trim()).length;
          const bodyBreakCount = best.querySelectorAll('br').length;
          const candidateIsMain = best.matches('article, main, [role="main"], [itemprop="articleBody"]');
          const hasStructuredBody = blocks.length >= 2 || bodyBreakCount >= 4 || bodyLineCount >= 6;
          const hasParagraphCoverage = rootLength > 0 && blockLength >= rootLength * 0.45;
          const hasSemanticBodyName = contentName.test(classInfo(best));
          // A navigation shell often has a long privacy/footer section before its
          // asynchronous article data arrives. Length alone must never mark it ready.
          const isContentReady = bodyText.length >= 80 && (
            isExplicitContentRoot ||
            (hasStructuredBody && (hasSemanticBodyName || candidateIsMain || (bodyText.length >= 900 && hasParagraphCoverage))) ||
            (hasSemanticBodyName && bodyText.length >= 320 && bodyBreakCount >= 2)
          );
          const headingText = element => {
            const value = normalize(element?.innerText || element?.textContent || '').replace(/\n+/g, ' ').trim();
            return value.length >= 2 && value.length <= 160 ? value : '';
          };
          const headingSelector = 'h1, h2, h3, [role="heading"], [class~="h1"], [class~="h2"], [class~="h3"], [class*="chapter-name"], [class*="chapterName"], [class*="chapter-title"], [class*="chapterTitle"], [class*="entry-title"], [class*="entryTitle"]';
          const findContentHeading = element => {
            const inside = Array.from(element.querySelectorAll(headingSelector))
              .filter(visible)
              .map(headingText)
              .find(Boolean);
            if (inside) return inside;
            for (let current = element.parentElement, depth = 0; current && current !== document.body && depth < 5; current = current.parentElement, depth++) {
              const preceding = Array.from(current.querySelectorAll(headingSelector))
                .filter(visible)
                .filter(node => !node.contains(element) && (node.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0)
                .map(headingText)
                .filter(Boolean);
              if (preceding.length) return preceding[preceding.length - 1];
            }
            return '';
          };
          const contentTitle = findContentHeading(best);
          const pageTitle = contentTitle || headingText(document.querySelector('h1, h2, h3')) || normalize(document.title || '未命名章节').split('\n')[0];
          const text = contentTitle && !bodyText.startsWith(contentTitle)
            ? `${contentTitle}\n\n${bodyText}`
            : bodyText;
          const currentUrl = new URL(location.href);
          currentUrl.hash = '';
          const currentUrlKey = currentUrl.href;
          const links = Array.from(document.querySelectorAll('a[href]')).map((element, index) => {
            let target;
            try {
              target = new URL(element.href, location.href);
              target.hash = '';
            } catch (_) {
              return null;
            }
            const text = normalize(element.innerText || element.textContent);
            const label = normalize([
              text,
              element.getAttribute('aria-label'),
              element.getAttribute('title'),
              element.id,
              typeof element.className === 'string' ? element.className : '',
              element.getAttribute('rel')
            ].filter(Boolean).join(' ')).toLowerCase();
            return { element, index, text: text.toLowerCase(), label, href: target.href };
          }).filter(Boolean);
          const findLink = (words, direction) => {
            const directionPattern = direction === 'next'
              ? /(下一章|下章|下一页|next|chapter[-_]?next|next[-_]?chapter)/i
              : /(上一章|上章|上一页|前一章|previous|prev|chapter[-_]?prev|prev[-_]?chapter)/i;
            const match = links
              .map(link => {
                const wordIndex = words.findIndex(word => link.text === word || link.text.includes(word) || link.label === word || link.label.includes(word));
                if (wordIndex < 0 || !visible(link.element) || link.href === currentUrlKey) return null;
                if (!/^https?:$/i.test(new URL(link.href).protocol)) return null;

                let score = 10000 - wordIndex * 240;
                if (link.text === words[wordIndex]) score += 2400;
                if (link.label === words[wordIndex]) score += 1200;
                if (directionPattern.test(link.label)) score += 900;
                if (link.element.matches(`[rel~="${direction}"]`)) score += 1200;
                return { ...link, score };
              })
              .filter(Boolean)
              .sort((left, right) => right.score - left.score || right.index - left.index)[0];
            return match ? match.href : '';
          };
          return JSON.stringify({
            title: pageTitle,
            text: text.slice(0, 200000),
            isContentReady,
            previousUrl: findLink(['上一章', '上章', '上一页', '前一章', 'previous', 'prev', 'pre chapter'], 'prev'),
            nextUrl: findLink(['下一章', '下章', '下一页', '后续', 'next', 'next chapter', '继续阅读'], 'next'),
            sourceUrl: location.href
          });
        })()
        """;

    // Scroll only the page's primary reading surface. This drives ordinary
    // infinite/lazy loaders without relying on a particular site's markup.
    private static readonly string LazyLoadStepScript = """
        (() => {
          const pageRoot = document.scrollingElement || document.documentElement;
          const isVisible = element => {
            if (!element) return false;
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== 'none' && style.visibility !== 'hidden' &&
              rect.width > 0 && rect.height > 0;
          };
          const getMetrics = element => {
            const isPage = element === pageRoot || element === document.documentElement || element === document.body;
            const scrollHeight = isPage
              ? Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0, window.innerHeight)
              : element.scrollHeight;
            const viewportHeight = isPage ? window.innerHeight : element.clientHeight;
            const scrollTop = isPage ? window.scrollY : element.scrollTop;
            return {
              element,
              isPage,
              scrollHeight,
              viewportHeight,
              scrollTop,
              range: Math.max(0, scrollHeight - viewportHeight)
            };
          };
          const contentHint = /(article|chapter|reader|read|story|book|novel|content|text|entry|post)/i;
          const scrollable = element => {
            if (!isVisible(element)) return false;
            const style = getComputedStyle(element);
            return /(auto|scroll|overlay)/i.test(style.overflowY || '') &&
              element.scrollHeight > element.clientHeight + 48;
          };
          const candidates = [getMetrics(pageRoot)];
          const seen = new Set([pageRoot]);
          document.querySelectorAll('main, article, [role="main"], [class*="article"], [class*="chapter"], [class*="reader"], [class*="read"], [class*="story"], [class*="book"], [class*="novel"], [class*="content"], [class*="text"], [class*="entry"], [class*="post"]').forEach(element => {
            if (seen.has(element) || !scrollable(element)) return;
            seen.add(element);
            const metrics = getMetrics(element);
            metrics.score = metrics.range + (contentHint.test(`${element.id || ''} ${typeof element.className === 'string' ? element.className : ''}`) ? 2400 : 0);
            candidates.push(metrics);
          });
          candidates[0].score = candidates[0].range + 1200;
          const target = candidates.sort((left, right) => right.score - left.score)[0];
          const wasAtBottom = target.range - target.scrollTop <= 8;
          if (target.isPage) {
            window.scrollTo(window.scrollX, target.range);
          } else {
            target.element.scrollTop = target.range;
          }
          return JSON.stringify({
            scrollHeight: Math.round(target.scrollHeight),
            viewportHeight: Math.round(target.viewportHeight),
            scrollTop: Math.round(target.isPage ? window.scrollY : target.element.scrollTop),
            wasAtBottom,
            target: target.isPage ? 'page' : 'content'
          });
        })()
        """;

    public async Task<PageParseResult> ExtractAsync(WebView2 webView, CancellationToken cancellationToken = default)
    {
        string raw = await webView.ExecuteScriptAsync(ExtractionScript);
        cancellationToken.ThrowIfCancellationRequested();
        string scriptValue = JsonSerializer.Deserialize<string>(raw) ?? "{}";
        PageParseResult? result = JsonSerializer.Deserialize<PageParseResult>(scriptValue, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
        if (result is null)
        {
            throw new InvalidOperationException("\u7f51\u9875\u89e3\u6790\u7ed3\u679c\u4e3a\u7a7a\u3002");
        }

        result.Title = string.IsNullOrWhiteSpace(result.Title) ? "\u672a\u547d\u540d\u7ae0\u8282" : result.Title.Trim();
        result.Text = NormalizeText(result.Text);
        if (result.Text.Length < MinimumUsefulTextLength)
        {
            throw new InvalidOperationException("\u672a\u627e\u5230\u8db3\u591f\u7684\u6b63\u6587\u5185\u5bb9\uff0c\u53ef\u80fd\u662f\u767b\u5f55\u3001\u9a8c\u8bc1\u6216\u7f51\u7ad9\u7ed3\u6784\u6682\u4e0d\u517c\u5bb9\u3002");
        }
        return result;
    }

    public async Task<PageParseResult> LoadLazyContentAsync(
        WebView2 webView,
        PageParseResult initialResult,
        CancellationToken cancellationToken = default)
    {
        PageParseResult accumulated = initialResult;
        int stableRounds = 0;
        int previousHeight = -1;
        string previousFingerprint = GetContentFingerprint(initialResult.Text);
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(LazyLoadMaximumDurationMilliseconds);

        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            LazyLoadState state = await AdvanceLazyContentAsync(webView, cancellationToken);
            await Task.Delay(LazyLoadStepDelayMilliseconds, cancellationToken);

            PageParseResult current;
            try
            {
                current = await ExtractAsync(webView, cancellationToken);
            }
            catch (InvalidOperationException)
            {
                stableRounds = 0;
                continue;
            }

            string currentFingerprint = GetContentFingerprint(current.Text);
            bool pageExpanded = previousHeight >= 0 && state.ScrollHeight > previousHeight + LazyLoadHeightChangeThreshold;
            bool contentChanged = !string.Equals(previousFingerprint, currentFingerprint, StringComparison.Ordinal);
            accumulated = MergeLazyContent(accumulated, current);

            if (state.WasAtBottom && !pageExpanded && !contentChanged)
            {
                stableRounds++;
                if (stableRounds >= LazyLoadStabilityRounds)
                {
                    break;
                }
            }
            else
            {
                stableRounds = 0;
            }

            previousHeight = state.ScrollHeight;
            previousFingerprint = currentFingerprint;
        }

        return accumulated;
    }

    public static bool IsUseful(PageParseResult result)
        => result.IsContentReady && result.Text.Trim().Length >= MinimumUsefulTextLength;

    private async Task<LazyLoadState> AdvanceLazyContentAsync(WebView2 webView, CancellationToken cancellationToken)
    {
        string raw = await webView.ExecuteScriptAsync(LazyLoadStepScript);
        cancellationToken.ThrowIfCancellationRequested();
        string scriptValue = JsonSerializer.Deserialize<string>(raw) ?? "{}";
        LazyLoadState? state = JsonSerializer.Deserialize<LazyLoadState>(scriptValue, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
        return state ?? new LazyLoadState();
    }

    private static PageParseResult MergeLazyContent(PageParseResult accumulated, PageParseResult current)
    {
        string mergedText = MergeText(accumulated.Text, current.Text);
        return new PageParseResult
        {
            Title = string.IsNullOrWhiteSpace(current.Title) ? accumulated.Title : current.Title,
            Text = mergedText,
            IsContentReady = accumulated.IsContentReady || current.IsContentReady,
            PreviousUrl = string.IsNullOrWhiteSpace(current.PreviousUrl) ? accumulated.PreviousUrl : current.PreviousUrl,
            NextUrl = string.IsNullOrWhiteSpace(current.NextUrl) ? accumulated.NextUrl : current.NextUrl,
            SourceUrl = string.IsNullOrWhiteSpace(current.SourceUrl) ? accumulated.SourceUrl : current.SourceUrl
        };
    }

    private static string MergeText(string existing, string current)
    {
        if (string.IsNullOrWhiteSpace(existing)) return current;
        if (string.IsNullOrWhiteSpace(current)) return existing;
        if (current.Contains(existing, StringComparison.Ordinal)) return current;
        if (existing.Contains(current, StringComparison.Ordinal)) return existing;

        string[] existingBlocks = SplitTextBlocks(existing);
        string[] currentBlocks = SplitTextBlocks(current);
        if (existingBlocks.Length == 0 || currentBlocks.Length == 0) return existing.Length >= current.Length ? existing : current;

        int overlap = FindSuffixPrefixOverlap(existingBlocks, currentBlocks);
        IEnumerable<string> additions = currentBlocks.Skip(overlap);
        if (overlap == 0 && string.Equals(existingBlocks[0], currentBlocks[0], StringComparison.Ordinal))
        {
            additions = currentBlocks.Skip(1).Where(block => !existingBlocks.Contains(block, StringComparer.Ordinal));
        }

        string appended = string.Join(Environment.NewLine + Environment.NewLine, additions);
        return string.IsNullOrWhiteSpace(appended)
            ? existing
            : existing + Environment.NewLine + Environment.NewLine + appended;
    }

    private static string[] SplitTextBlocks(string value)
        => value.Split(["\r\n\r\n", "\n\n"], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static int FindSuffixPrefixOverlap(string[] existing, string[] current)
    {
        int maximum = Math.Min(existing.Length, current.Length);
        for (int size = maximum; size > 0; size--)
        {
            bool matches = true;
            for (int index = 0; index < size; index++)
            {
                if (!string.Equals(existing[existing.Length - size + index], current[index], StringComparison.Ordinal))
                {
                    matches = false;
                    break;
                }
            }
            if (matches) return size;
        }
        return 0;
    }

    private static string GetContentFingerprint(string text)
    {
        const int FingerprintPartLength = 512;
        string normalized = text.Trim();
        return normalized.Length <= FingerprintPartLength * 2
            ? normalized
            : normalized[..FingerprintPartLength] + normalized[^FingerprintPartLength..];
    }

    private sealed class LazyLoadState
    {
        public int ScrollHeight { get; set; }
        public int ViewportHeight { get; set; }
        public int ScrollTop { get; set; }
        public bool WasAtBottom { get; set; }
        public string Target { get; set; } = string.Empty;
    }

    private static string NormalizeText(string value)
    {
        string normalized = Regex.Replace(value ?? string.Empty, "[\uE000-\uF8FF\uFFF0-\uFFFF\uFFFD]", string.Empty)
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Replace('\u00A0', ' ');

        List<string> lines = new();
        bool previousWasBlank = false;
        foreach (string rawLine in normalized.Split('\n'))
        {
            string line = Regex.Replace(rawLine, "[ \\t]{2,}", " ").Trim();
            if (line.Length == 0)
            {
                if (!previousWasBlank && lines.Count > 0)
                {
                    lines.Add(string.Empty);
                }
                previousWasBlank = true;
                continue;
            }

            if (Regex.IsMatch(line, "^\\d{1,4}$"))
            {
                continue;
            }

            lines.Add(line);
            previousWasBlank = false;
        }

        return string.Join(Environment.NewLine, lines).Trim();
    }
}
