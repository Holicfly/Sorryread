using ReadAI;

internal static partial class Program
{
    private static void TestNavigationAndPaging()
    {
        ReaderNavigation navigation = new();
        Check(!navigation.CanGoBack && navigation.Current == ReaderView.Home, "home has no return target");
        navigation.Navigate(ReaderView.SearchResults);
        navigation.Navigate(ReaderView.Reader);
        Check(navigation.TryGoBack(out var back) && back == ReaderView.SearchResults, "reading returns to originating results");
        Check(navigation.TryGoBack(out back) && back == ReaderView.Home && !navigation.CanGoBack, "results return to home without loops");
        navigation.Navigate(ReaderView.Reader);
        navigation.Navigate(ReaderView.SearchResults);
        Check(navigation.TryGoBack(out back) && back == ReaderView.Reader, "search from reading retains a reader return target");
        navigation.Navigate(ReaderView.Library);
        Check(navigation.TryGoBack(out back) && back == ReaderView.Reader, "library returns to its origin");
        navigation.Navigate(ReaderView.SearchResults);
        navigation.Navigate(ReaderView.Reader);
        Check(navigation.TryGoBack(out back) && back == ReaderView.SearchResults && navigation.TryGoBack(out back) && back == ReaderView.Home,
            "opening a different book does not leave a stale older-book target");
        navigation.Navigate(ReaderView.Library);
        navigation.GoHome();
        Check(!navigation.CanGoBack, "explicit home resets return navigation");

        foreach (int count in new[] { 0, 1, 20, 21, 45 })
        {
            SearchResultPager pager = new();
            var results = Enumerable.Range(0, count).Select(i => new NovelSearchResult { Title = i.ToString() }).ToArray();
            pager.Store(1, results, false);
            Check(pager.LoadedPageCount == Math.Max(1, (count + 19) / 20) && !pager.HasPrevious,
                $"{count} results: correct slice count and first-page boundary");
            List<NovelSearchResult> seen = [];
            do
            {
                Check(pager.VisibleResults.Count <= 20, $"{count} results: page {pager.PageNumber} never exceeds 20");
                seen.AddRange(pager.VisibleResults);
            } while (pager.MoveNextCached());
            Check(seen.SequenceEqual(results) && !pager.HasNext, $"{count} results: pagination has no missing or duplicate rows");
        }

        SearchResultPager remote = new();
        remote.Store(1, Enumerable.Range(0, 45).Select(i => new NovelSearchResult { Title = $"a{i}" }).ToArray(), true);
        remote.MoveNextCached();
        remote.MoveNextCached();
        Check(remote.HasNext && !remote.MoveNextCached() && remote.NextServerPageNumber == 2, "network next-page waits until local slices are exhausted");
        remote.Store(2, [new NovelSearchResult { Title = "second server page" }], false);
        remote.SelectServerPage(2);
        Check(remote.PageNumber == 4 && remote.CurrentServerPageNumber == 2 && !remote.HasNext, "remote page appends after all local slices");
        remote.MovePrevious();
        Check(remote.PageNumber == 3 && remote.VisibleResults.Count == 5 && remote.CurrentServerPageNumber == 1, "back uses cached prior server page");
        Check(remote.MoveNextCached() && remote.VisibleResults[0].Title == "second server page", "cached next page needs no refetch");
        remote.Clear();
        Check(remote.VisibleResults.Count == 0 && !remote.HasNext && !remote.HasPrevious, "new search clears all old pagination state");
    }
}
