using System.Windows;

namespace ReadAI;

public partial class MainWindow
{
    private readonly Dictionary<string, SearchResultPager> _searchResultPagers = new(StringComparer.OrdinalIgnoreCase);
    private readonly SearchResultPager _legacyResultsPager = new();

    private SearchResultPager CurrentSearchPager => _aggregatedSearchMode
        ? GetSearchPager(_selectedAggregatedSourceId)
        : _legacyResultsPager;

    private SearchResultPager GetSearchPager(string sourceId)
    {
        if (!_searchResultPagers.TryGetValue(sourceId, out SearchResultPager? pager))
        {
            pager = new SearchResultPager();
            _searchResultPagers[sourceId] = pager;
        }
        return pager;
    }

    private void DisplayCurrentSearchPage()
    {
        SearchResultPager pager = CurrentSearchPager;
        _searchPageNumber = pager.PageNumber;
        SearchResultsList.ItemsSource = pager.VisibleResults;
        SearchResultsList.Visibility = _viewNavigation.Current == ReaderView.SearchResults
            ? Visibility.Visible : Visibility.Collapsed;
        UpdateSearchPagination();
        ScrollSearchResultsToTop();
    }

    private async Task NavigateSearchPageAsync(bool nextPage)
    {
        if (_isLoading || _viewNavigation.Current != ReaderView.SearchResults) return;
        SearchResultPager pager = CurrentSearchPager;
        if (nextPage ? pager.MoveNextCached() : pager.MovePrevious())
        {
            DisplayCurrentSearchPage();
            SetStatus($"「{_searchKeyword}」搜索结果：第 {pager.PageNumber} 页，本页 {pager.VisibleResults.Count} 条。");
            return;
        }
        if (!nextPage || !pager.HasNext) return;
        if (_aggregatedSearchMode)
        {
            await LoadAggregatedSourcePageAsync(pager.NextServerPageNumber);
        }
        else
        {
            await LoadSearchPageAsync(pager.NextServerPageNumber);
        }
    }
}
