using System.Windows;

namespace ReadAI;

public partial class MainWindow
{
    private bool _homeSearchMode;
    private bool _searchOperationActive;
    private readonly ReaderNavigation _viewNavigation = new();

    private async void StatusPreviousClick(object sender, RoutedEventArgs e)
    {
        if (_viewNavigation.Current == ReaderView.SearchResults) await NavigateSearchPageAsync(nextPage: false);
        else if (_viewNavigation.Current == ReaderView.Reader) await NavigateChapterAsync(nextChapter: false);
    }

    private async void StatusNextClick(object sender, RoutedEventArgs e)
    {
        if (_viewNavigation.Current == ReaderView.SearchResults) await NavigateSearchPageAsync(nextPage: true);
        else if (_viewNavigation.Current == ReaderView.Reader) await NavigateChapterAsync(nextChapter: true);
    }

    private void UpdateStatusNavigationButtons()
    {
        bool results = _viewNavigation.Current == ReaderView.SearchResults;
        bool reader = _viewNavigation.Current == ReaderView.Reader && ReaderBox.Visibility == Visibility.Visible;
        PreviousChapterMenuItem.IsEnabled = reader && CanNavigateChapter(nextChapter: false);
        NextChapterMenuItem.IsEnabled = reader && CanNavigateChapter(nextChapter: true);
        PreviousChapterButton.IsEnabled = !_isLoading && !SearchOverlay.IsOpen && (results ? CurrentSearchPager.HasPrevious : PreviousChapterMenuItem.IsEnabled);
        NextChapterButton.IsEnabled = !_isLoading && !SearchOverlay.IsOpen && (results ? CurrentSearchPager.HasNext : NextChapterMenuItem.IsEnabled);
        PreviousChapterButton.ToolTip = results ? $"上一页（当前第 {CurrentSearchPager.PageNumber} 页）" : "上一章";
        NextChapterButton.ToolTip = results ? $"下一页（当前第 {CurrentSearchPager.PageNumber} 页）" : "下一章";
        System.Windows.Automation.AutomationProperties.SetName(PreviousChapterButton, results ? "上一页" : "上一章");
        System.Windows.Automation.AutomationProperties.SetName(NextChapterButton, results ? "下一页" : "下一章");
    }

    private void HomeButtonClick(object sender, RoutedEventArgs e) => ReturnHome();

    private void CaptureViewPosition()
    {
        if (ReaderBox.Visibility == Visibility.Visible && HasReadingSession())
        {
            _readingReturnProgress = GetCurrentReaderProgress();
            SaveActiveProgress();
        }
        else if (_viewNavigation.Current == ReaderView.SearchResults && SearchResultsList.Visibility == Visibility.Visible)
        {
            SaveSearchResultsScroll();
        }
    }

    private void StopSearchForNavigation()
    {
        if (!_searchOperationActive) return;
        _searchScopeVersion++;
        CancelActiveSearchForScopeSwitch();
        _searchOperationActive = false;
        _isLoading = false;
        ParseButton.IsEnabled = true;
        SetModeSelectorsEnabled(true);
        UpdateLoadingIndicator();
    }

    private void ReturnHome()
    {
        if (_isLoading && !_searchOperationActive) return;
        SearchOverlay.Close(restoreFocus: false);
        StopSearchForNavigation();
        CaptureViewPosition();
        SetSearchMode(_homeSearchMode, clearInput: false, clearSearchResults: false);
        ShowInputPanel();
    }

    private void SearchButtonClick(object sender, RoutedEventArgs e)
    {
        if (_isLoading) return;
        SearchOverlay.Open(IsBookSourceInput ? $"输入书籍 id 或{SelectedInputSource.Name}链接" : IsAggregatedSearch
            ? $"聚合搜索 {BookSourceCatalog.Aggregated.Count} 个书源"
            : "18mh 小说网单独搜索");
    }

    private void SearchOverlayOpenStateChanged(object? sender, EventArgs e)
    {
        UpdateDesktopReading();
        _hotKeyService.ChapterShortcutsEnabled = !SearchOverlay.IsOpen;
        UpdateReturnToReadingButton();
    }

    private async void SearchOverlaySearchRequested(object? sender, string keyword)
    {
        if (_isLoading) return;
        if (IsBookSourceInput)
        {
            if (!BookSourceInput.TryParse(SelectedInputSource, keyword, out _, out _, out _))
            {
                SearchOverlay.ShowError($"请输入书籍 id 或{SelectedInputSource.Name}的链接。");
                return;
            }
            SearchOverlay.Close(restoreFocus: false);
            UrlBox.Text = keyword;
            await OpenBookSourceInputAsync();
            return;
        }
        bool parseUrl = SearchInputClassifier.TryGetHttpUrl(keyword, out string url);
        if ((parseUrl || IsLegacy18Mh) && !_webViewReady)
        {
            SearchOverlay.ShowError("网页解析/搜索组件尚未准备好，请稍后重试");
            return;
        }
        SearchOverlay.Close(restoreFocus: false);
        if (parseUrl)
        {
            // 沿用手动解析入口，清除旧书源和目录；网址不写入搜索记录，也不切换搜索模式。
            UrlBox.Text = url;
            await ParseFromInputAsync();
        }
        else
        {
            await StartNovelSearchAsync(keyword);
        }
    }

    private void ShowSearchResultsView()
    {
        CaptureViewPosition();
        _viewNavigation.Navigate(ReaderView.SearchResults);
        CloseLibraryPanelShell();
        CloseParseRecordsPanelShell();
        SetSearchMode(true, clearInput: false, clearSearchResults: false);
        SearchInputLayout.VerticalAlignment = VerticalAlignment.Stretch;
        InputPanel.Visibility = Visibility.Collapsed;
        ReaderBox.Visibility = Visibility.Collapsed;
        EmptyText.Visibility = Visibility.Collapsed;
        SearchResultsPanel.Visibility = Visibility.Visible;
        SearchResultsList.Visibility = Visibility.Visible;
        RefreshBookSourceSelector();
        UpdateSearchPagination();
        UpdateStatusNavigationButtons();
        UpdateReturnToReadingButton();
        UpdateLibraryActions();
    }

    private void RestoreReaderView()
    {
        if (!HasReadingSession()) return;
        CloseLibraryPanelShell();
        CloseParseRecordsPanelShell();
        SetSearchMode(false, clearInput: false, clearSearchResults: false);
        InputPanel.Visibility = Visibility.Collapsed;
        SearchResultsPanel.Visibility = Visibility.Collapsed;
        BookSourceSelectorPanel.Visibility = Visibility.Collapsed;
        SearchResultsList.Visibility = Visibility.Collapsed;
        EmptyText.Visibility = Visibility.Collapsed;
        ReaderBox.Visibility = Visibility.Visible;
        UpdateStatusNavigationButtons();
        UpdateReturnToReadingButton();
        UpdateCurrentChapterHighlight();
        UpdateLibraryActions();
        RunViewTransition();
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded,
            new Action(() => RestoreProgress(_readingReturnProgress)));
        SetStatus($"已返回阅读：{_currentEntry!.Title}");
    }

    private void NavigateBack()
    {
        if (_isLoading && !_searchOperationActive) return;
        StopSearchForNavigation();
        CaptureViewPosition();
        if (!_viewNavigation.TryGoBack(out ReaderView target)) return;
        switch (target)
        {
            case ReaderView.Reader when HasReadingSession():
                RestoreReaderView();
                break;
            case ReaderView.SearchResults when SearchResultsList.ItemsSource is not null:
                ShowSearchResultsView();
                RestoreSearchResultsScroll();
                break;
            case ReaderView.Library:
                ShowLibraryPanel();
                break;
            case ReaderView.ParseRecords:
                ShowParseRecordsPanel();
                break;
            default:
                ReturnHome();
                break;
        }
        UpdateReturnToReadingButton();
    }
}
