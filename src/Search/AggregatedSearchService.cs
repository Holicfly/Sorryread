using System.Net.Http;

namespace ReadAI;

public delegate Task<NovelSearchPage> LegacyBookSourceSearch(
    BookSourceDefinition source,
    string keyword,
    int pageNumber,
    string? pageUrl,
    CancellationToken cancellationToken);

public sealed class AggregatedSearchService : IDisposable
{
    private readonly BookSourceParser _httpParser;
    private readonly LegacyBookSourceSearch _legacySearch;

    public AggregatedSearchService(BookSourceParser httpParser, LegacyBookSourceSearch legacySearch)
    {
        _httpParser = httpParser ?? throw new ArgumentNullException(nameof(httpParser));
        _legacySearch = legacySearch ?? throw new ArgumentNullException(nameof(legacySearch));
    }

    public async Task<IReadOnlyList<BookSourceSearchState>> SearchAllAsync(
        string keyword,
        IProgress<BookSourceSearchState>? progress = null,
        CancellationToken cancellationToken = default)
    {
        string normalizedKeyword = keyword.Trim();
        if (normalizedKeyword.Length == 0) return [];

        List<BookSourceSearchState> states = BookSourceCatalog.Aggregated
            .Select(source => new BookSourceSearchState { Source = source })
            .ToList();
        Task[] searches = states
            .Select(state => SearchOneAsync(state, normalizedKeyword, null, progress, cancellationToken))
            .ToArray();

        await Task.WhenAll(searches);
        return states;
    }

    public async Task<BookSourceSearchState> SearchSourcePageAsync(
        BookSourceDefinition source,
        string keyword,
        int pageNumber,
        string pageUrl,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (pageNumber < 1) throw new ArgumentOutOfRangeException(nameof(pageNumber));
        if (string.IsNullOrWhiteSpace(pageUrl)) throw new ArgumentException("分页网址不能为空。", nameof(pageUrl));

        BookSourceSearchState state = new() { Source = source, PageNumber = pageNumber };
        await SearchOneAsync(state, keyword.Trim(), pageUrl, progress: null, cancellationToken);
        return state;
    }

    private async Task SearchOneAsync(
        BookSourceSearchState state,
        string keyword,
        string? pageUrl,
        IProgress<BookSourceSearchState>? progress,
        CancellationToken cancellationToken)
    {
        state.Status = BookSourceSearchStatus.Searching;
        progress?.Report(state.Snapshot());

        try
        {
            NovelSearchPage page = state.Source.ParserKind switch
            {
                BookSourceParserKind.HttpRules =>
                    await _httpParser.SearchAsync(state.Source, keyword, pageUrl, cancellationToken),
                BookSourceParserKind.Legacy18MhWebView =>
                    await _legacySearch(state.Source, keyword, state.PageNumber, pageUrl, cancellationToken)
                        .WaitAsync(state.Source.Search.Timeout, cancellationToken),
                _ => throw new NotSupportedException($"不支持书源解析器：{state.Source.ParserKind}")
            };

            state.Results = page.Results;
            state.NextPageUrl = page.NextPageUrl;
            state.Status = page.Results.Count == 0
                ? BookSourceSearchStatus.Empty
                : BookSourceSearchStatus.Succeeded;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            state.Status = BookSourceSearchStatus.Failed;
            state.ErrorMessage = ToFriendlyMessage(exception);
        }
        finally
        {
            progress?.Report(state.Snapshot());
        }
    }

    private static string ToFriendlyMessage(Exception exception)
        => exception switch
        {
            TimeoutException => "搜索超时",
            HttpRequestException => "网络请求失败",
            _ => string.IsNullOrWhiteSpace(exception.Message) ? "搜索失败" : exception.Message
        };

    public void Dispose() => _httpParser.Dispose();
}
