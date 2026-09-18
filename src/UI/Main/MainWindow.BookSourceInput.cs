using System.Net;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Data.Sqlite;

namespace ReadAI;

public partial class MainWindow
{
    private string _selectedInputSourceId = BookSourceCatalog.WodushuId;
    private DispatcherTimer? _searchScopeMenuTimer;
    private bool _sanitizingUrlBox;
    private DateTime _lastInputNoticeUtc;
    private string _normalizedInputBookId = string.Empty;
    private string _pendingInputChapterUrl = string.Empty;
    private BookSourceDefinition SelectedInputSource => BookSourceCatalog.GetRequired(_selectedInputSourceId);
    private bool RestrictBookSourceInput => _searchModeActive && IsBookSourceInput;

    private void InitializeBookSourceInput()
    {
        AddSearchScopeMenuItem("聚合搜索", SearchHistoryModes.Aggregated);
        foreach (BookSourceDefinition source in BookSourceCatalog.InputSources)
            AddSearchScopeMenuItem(source.Name, source.Id);
        SearchModeSelector.ContextMenuOpening += SearchScopeContextMenuOpening;
        UrlBox.PreviewTextInput += BookSourcePreviewTextInput;
        UrlBox.TextChanged += BookSourceInputTextChanged;
        System.Windows.DataObject.AddPastingHandler(UrlBox, BookSourceInputPasting);
        Closed += (_, _) => CancelSearchScopeMenuTimer();
    }

    private void AddSearchScopeMenuItem(string header, string id)
    {
        MenuItem item = new() { Header = header, Tag = id, IsCheckable = true };
        item.Click += SearchScopeMenuItemClick;
        SearchScopeMenu.Items.Add(item);
    }

    private void UpdateSearchScopeMenuChecks()
    {
        foreach (MenuItem item in SearchScopeMenu.Items)
            item.IsChecked = IsAggregatedSearch ? (string)item.Tag == SearchHistoryModes.Aggregated
                : IsBookSourceInput && (string)item.Tag == _selectedInputSourceId;
    }

    private void SetSearchInputScope(SearchInputScope scope)
    {
        _searchInputScope = scope;
        _pendingInputChapterUrl = _normalizedInputBookId = string.Empty;
        SearchModeSelector.ToolTip = IsLegacy18Mh
            ? "小说搜索：当前为 18mh 小说网单独搜索；双击切回聚合搜索"
            : $"小说搜索：当前为{(IsBookSourceInput ? SelectedInputSource.Name : "聚合搜索")}；单击选择子模式，双击切换为 18mh 小说网";
        ApplySearchScopeAccent();
        ApplyTrayMenuTheme();
        if (!IsAggregatedSearch)
        {
            _aggregatedSearchStates = [];
            _aggregatedSearchPageCache.Clear();
            _selectedAggregatedSourceId = string.Empty;
        }
        UpdateBookSourceInputRestrictions();
        UpdateSearchScopeMenuChecks();
        RefreshBookSourceSelector();
    }

    private void SwitchSearchInputScope(SearchInputScope target, string? sourceId = null)
    {
        if (_viewNavigation.Current != ReaderView.Home || (_isLoading && !_searchOperationActive)) return;
        CancelSearchScopeMenuTimer();
        SearchScopeMenu.IsOpen = false;
        if (target == _searchInputScope && (sourceId is null || sourceId == _selectedInputSourceId))
        {
            UpdateSearchScopeMenuChecks();
            return;
        }
        _homeSearchMode = true;
        _searchScopeVersion++;
        CancelActiveSearchForScopeSwitch();
        _searchOperationActive = false;
        _isLoading = false;
        UpdateLoadingIndicator();
        ParseButton.IsEnabled = true;
        SetModeSelectorsEnabled(true);
        if (sourceId is not null) _selectedInputSourceId = sourceId;
        SetSearchInputScope(target);
        ClearSearchResults();
        SetSearchMode(true, clearInput: false, clearSearchResults: false);
        ShowInputPanel();
        SetStatus(IsBookSourceInput ? $"已切换为{SelectedInputSource.Name}：输入书籍 id 或链接即可解析。"
            : IsAggregatedSearch ? $"已切换为聚合搜索：将同时搜索 {BookSourceCatalog.Aggregated.Count} 个书源。"
            : "已切换为 18mh 小说网单独搜索。");
    }

    private void SearchScopeMenuItemClick(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuItem { Tag: string id }) return;
        if (id == SearchHistoryModes.Aggregated) SwitchSearchInputScope(SearchInputScope.Aggregated);
        else if (BookSourceCatalog.InputSources.Any(source => source.Id == id))
            SwitchSearchInputScope(SearchInputScope.BookSourceInput, id);
    }

    private void SearchScopeContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        // Suppress automatic right-click opening; the delayed left click owns this menu.
        e.Handled = true;
    }

    private void SearchModeSelectorPreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (_viewNavigation.Current != ReaderView.Home || (_isLoading && !_searchOperationActive)) return;
        if (e.ClickCount == 2)
        {
            CancelSearchScopeMenuTimer();
            e.Handled = true;
            SwitchSearchInputScope(IsLegacy18Mh ? SearchInputScope.Aggregated : SearchInputScope.Legacy18Mh);
            return;
        }
        if (IsLegacy18Mh || !_searchModeActive) return;
        CancelSearchScopeMenuTimer();
        _searchScopeMenuTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(System.Windows.Forms.SystemInformation.DoubleClickTime)
        };
        _searchScopeMenuTimer.Tick += (_, _) =>
        {
            CancelSearchScopeMenuTimer();
            if (_viewNavigation.Current != ReaderView.Home || !_searchModeActive || IsLegacy18Mh ||
                (_isLoading && !_searchOperationActive)) return;
            UpdateSearchScopeMenuChecks();
            SearchScopeMenu.PlacementTarget = SearchModeSelector;
            SearchScopeMenu.IsOpen = true;
        };
        _searchScopeMenuTimer.Start();
    }

    private void CancelSearchScopeMenuTimer()
    {
        _searchScopeMenuTimer?.Stop();
        _searchScopeMenuTimer = null;
    }

    private void UpdateBookSourceInputRestrictions()
    {
        InputMethod.SetIsInputMethodEnabled(UrlBox, !RestrictBookSourceInput);
        if (RestrictBookSourceInput) SanitizeBookSourceInput();
        else
        {
            CancelSearchScopeMenuTimer();
            SearchScopeMenu.IsOpen = false;
        }
    }

    private void ShowBookSourceInputNotice()
    {
        if ((DateTime.UtcNow - _lastInputNoticeUtc).TotalSeconds < 2) return;
        _lastInputNoticeUtc = DateTime.UtcNow;
        ShowTransientNotice("该模式只支持书籍 id 或链接，不能输入中文或其他非 ASCII 字符。", isWarning: true);
    }

    private void BookSourcePreviewTextInput(object sender, TextCompositionEventArgs e)
    {
        if (!RestrictBookSourceInput || !e.Text.Any(c => c > 0x7f)) return;
        e.Handled = true;
        ShowBookSourceInputNotice();
    }

    private void BookSourceInputPasting(object sender, DataObjectPastingEventArgs e)
    {
        if (!RestrictBookSourceInput) return;
        string? text = e.DataObject.GetData(System.Windows.DataFormats.UnicodeText) as string
            ?? e.DataObject.GetData(System.Windows.DataFormats.Text) as string;
        if (text is null) return;
        if (text.Any(c => c > 0x7f))
        {
            e.CancelCommand();
            ShowBookSourceInputNotice();
            return;
        }
        // Capture the complete proposed value before rewriting the visible text to an id.
        string proposed = UrlBox.Text.Remove(UrlBox.SelectionStart, UrlBox.SelectionLength)
            .Insert(UrlBox.SelectionStart, text);
        if (!BookSourceInput.TryParse(SelectedInputSource, proposed, out string id, out _, out string chapter)) return;
        e.CancelCommand();
        SetNormalizedBookSourceInput(id, chapter);
    }

    private void BookSourceInputTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_sanitizingUrlBox) return;
        _pendingInputChapterUrl = _normalizedInputBookId = string.Empty;
        if (RestrictBookSourceInput) SanitizeBookSourceInput();
    }

    private void SanitizeBookSourceInput()
    {
        if (_sanitizingUrlBox || !UrlBox.Text.Any(c => c > 0x7f || char.IsControl(c))) return;
        _sanitizingUrlBox = true;
        try
        {
            int caret = UrlBox.CaretIndex;
            UrlBox.Text = new string(UrlBox.Text.Where(c => c >= 0x20 && c <= 0x7e).ToArray());
            UrlBox.CaretIndex = Math.Min(caret, UrlBox.Text.Length);
            _pendingInputChapterUrl = _normalizedInputBookId = string.Empty;
        }
        finally { _sanitizingUrlBox = false; }
        ShowBookSourceInputNotice();
    }

    private void SetNormalizedBookSourceInput(string bookId, string chapterUrl)
    {
        UrlBox.Text = bookId;
        UrlBox.CaretIndex = bookId.Length;
        _normalizedInputBookId = bookId;
        _pendingInputChapterUrl = chapterUrl;
    }

    private async Task OpenBookSourceInputAsync()
    {
        if (_isLoading) return;
        BookSourceDefinition source = SelectedInputSource;
        string input = UrlBox.Text.Trim();
        if (!BookSourceInput.TryParse(source, input, out string bookId, out string detailUrl, out string targetChapterUrl))
        {
            SetStatus($"请输入书籍 id 或{source.Name}的链接。", isError: true);
            UrlBox.Focus();
            UrlBox.SelectAll();
            return;
        }
        if (targetChapterUrl.Length == 0 && input == _normalizedInputBookId)
            targetChapterUrl = _pendingInputChapterUrl;
        SetNormalizedBookSourceInput(bookId, targetChapterUrl);
        CaptureViewPosition();
        // Preserve the previous reading session if opening a different book fails.
        string previousSource = _activeBookSourceId;
        string previousTitle = _currentBookTitle;
        string previousCatalogTitle = _chapterCatalogBookTitle;
        string previousCatalogSource = _chapterCatalogSourceId;
        string previousNotice = ChapterCatalogCountText.ToolTip as string ?? string.Empty;
        List<NovelChapterItem> previousCatalog = _chapterCatalog;
        PageParseResult? previousPage = _currentPage;
        HistoryEntry? previousEntry = _currentEntry;
        LibraryBookEntry? previousLibraryBook = _currentLibraryBook;
        string previousUrl = _currentUrl;
        bool previousEntryWritesHistory = _currentEntryWritesHistory;
        double previousReadingProgress = _readingReturnProgress;
        _homeSearchMode = true;
        ClearSearchResults();
        try
        {
            _currentBookTitle = $"书籍 {bookId}";
            _activeBookSourceId = source.Id;
            string readingUrl = await ResolveBookSourceReadingUrlAsync(source, new NovelSearchResult
            {
                SourceId = source.Id, SourceName = source.Name, Url = detailUrl
            });
            if (targetChapterUrl.Length > 0)
            {
                string normalizedTarget = BookSourceInput.NormalizeChapterUrl(source, targetChapterUrl);
                NovelChapterItem? chapter = _chapterCatalog.FirstOrDefault(candidate =>
                    string.Equals(BookSourceInput.NormalizeChapterUrl(source, candidate.Url), normalizedTarget,
                        StringComparison.OrdinalIgnoreCase));
                if (chapter is not null) readingUrl = chapter.Url;
                else ShowTransientNotice("未在目录中找到该章节，已从第一章开始。", isWarning: true);
            }
            LibraryBookEntry libraryBook = new()
            {
                BookKey = LibraryBookEntry.CreateBookKey(source.Id, detailUrl),
                Title = _currentBookTitle, SourceId = source.Id, SourceName = source.Name,
                DetailUrl = detailUrl, ChapterUrl = readingUrl, LastReadUtc = DateTime.UtcNow
            };
            if (await ParseUrlAsync(readingUrl, libraryBookContext: libraryBook,
                replaceLibraryContext: true, propagateFailure: true))
                RecordBookSourceHistory(source.Id, detailUrl, libraryBook.Title);
        }
        catch (Exception exception)
        {
            RestoreReadingSessionAfterLibraryFailure(previousSource, previousTitle, previousCatalogTitle,
                previousCatalog, previousPage, previousEntry, previousLibraryBook, previousUrl,
                previousEntryWritesHistory, previousReadingProgress);
            SetChapterCatalog(previousCatalogTitle, previousCatalog,
                "目录加载失败，请重新输入书籍 id 或链接。", previousNotice);
            _chapterCatalogSourceId = previousCatalogSource;
            ShowInputPanel();
            SetNormalizedBookSourceInput(bookId, targetChapterUrl);
            SetStatus(exception is HttpRequestException { StatusCode: HttpStatusCode.NotFound }
                ? "没有找到这本书，请检查 id 是否正确。" : $"书籍解析失败：{exception.Message}", isError: true);
        }
    }

    private void RecordBookSourceHistory(string sourceId, string detailUrl, string bookTitle)
    {
        if (!_settings.SearchHistoryEnabled) return;
        try
        {
            _database.AddSearchHistory(sourceId, detailUrl, bookTitle);
            SearchHistoryPanel.IsManaging = false;
            RefreshSearchHistory();
        }
        catch (SqliteException)
        {
            ShowTransientNotice("本次记录未能保存，不影响继续阅读。", isWarning: true);
        }
    }
}
