using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace ReadAI;

public partial class MainWindow : Window
{
    private enum LibraryReturnView
    {
        Input,
        SearchResults,
        Reader
    }

    private const int NavigationTimeoutMilliseconds = 25000;
    private const int DynamicContentPollMilliseconds = 500;
    private const int DynamicContentTimeoutMilliseconds = 12000;
    private const int ProgressSaveDelayMilliseconds = 500;
    private const int RestoreForegroundDelayMilliseconds = 150;
    private const int SwShow = 5;
    private const int SwRestore = 9;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private const uint SwpNoOwnerZOrder = 0x0200;
    private static readonly IntPtr HwndTopmost = new(-1);
    private static readonly IntPtr HwndNotTopmost = new(-2);
    private const double ChapterCatalogHiddenOffset = 286;
    private const int ChapterCatalogAnimationMilliseconds = 260;
    private const int ChapterCatalogFadeMilliseconds = 150;
    private const int LibraryActionsFadeMilliseconds = 160;
    private const int TransientNoticeMilliseconds = 3000;
    private const double BookSourceWheelScrollStep = 72;
    private const double SearchResultsTopMargin = 42;
    private const double SearchResultsTopMarginWithBookSources = 96;
    private static readonly (string Target, string LegacySource)[] SearchScopeAccentResources =
    [
        ("AccentBrush", "LegacySearchAccentBrush"),
        ("AccentHoverBrush", "LegacySearchAccentHoverBrush"),
        ("AccentPressedBrush", "LegacySearchAccentPressedBrush"),
        ("AccentSubtleBrush", "LegacySearchAccentSubtleBrush"),
        ("AccentSubtleHoverBrush", "LegacySearchAccentSubtleHoverBrush"),
        ("AccentForegroundBrush", "LegacySearchAccentForegroundBrush")
    ];

    private readonly ReaderDatabase _database = App.Database;
    private readonly PageParser _pageParser = new();
    private readonly NovelSearchParser _novelSearchParser = new();
    private readonly HotKeyService _hotKeyService = new();
    private readonly BookSourceParser _bookSourceParser;
    private readonly AggregatedSearchService _aggregatedSearchService;
    private readonly DispatcherTimer _progressTimer;
    private readonly System.Windows.Forms.NotifyIcon _notifyIcon;
    private System.Windows.Forms.ContextMenuStrip? _trayMenu;
    private TransparentReaderWindow? _transparentWindow;
    private ReaderSettings _settings = new();
    private PageParseResult? _currentPage;
    private HistoryEntry? _currentEntry;
    private LibraryBookEntry? _currentLibraryBook;
    private string _currentUrl = string.Empty;
    private string _currentBookTitle = string.Empty;
    private string _searchKeyword = string.Empty;
    private string _chapterCatalogBookTitle = string.Empty;
    private string _chapterCatalogSourceId = string.Empty;
    private string _selectedAggregatedSourceId = string.Empty;
    private string _activeBookSourceId = string.Empty;
    private List<NovelChapterItem> _chapterCatalog = [];
    private IReadOnlyList<BookSourceSearchState> _aggregatedSearchStates = [];
    private readonly Dictionary<string, Dictionary<int, BookSourceSearchState>> _aggregatedSearchPageCache
        = new(StringComparer.OrdinalIgnoreCase);
    private CancellationTokenSource? _aggregatedSearchCancellation;
    private int _searchPageNumber = 1;
    private int _searchScopeVersion;
    private bool _searchHasNext;
    private bool _searchResultReturnAvailable;
    private double _searchResultsScrollOffset;
    private bool _updatingInputMode;
    private TaskCompletionSource<bool>? _navigationCompletion;
    private bool _allowExit;
    private bool _webViewReady;
    private bool _isLoading;
    private bool _startupDisplayReady;
    private bool _transparentModeActive;
    private bool _searchModeActive;
    private bool _aggregatedSearchMode = true;
    private bool _syncingReaderScrollBar;
    private bool _isChapterCatalogExpanded;
    private bool _currentEntryWritesHistory;
    private bool _libraryPanelActive;
    private bool _libraryActionsAlwaysVisible;
    private int _transientNoticeVersion;
    private LibraryReturnView _libraryReturnView;
    private double _readingReturnProgress;

    public MainWindow()
    {
        InitializeComponent();
        _bookSourceParser = new BookSourceParser();
        _aggregatedSearchService = new AggregatedSearchService(
            _bookSourceParser, SearchLegacyBookSourceAsync);
        SetAggregatedSearchMode(enabled: true);
        AppThemeService.Current.ThemeChanged += AppThemeChanged;
        Closed += (_, _) => AppThemeService.Current.ThemeChanged -= AppThemeChanged;
        ChapterCatalogList.Visibility = Visibility.Collapsed;
        ParserView.NavigationCompleted += ParserViewNavigationCompleted;
        _progressTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ProgressSaveDelayMilliseconds) };
        _progressTimer.Tick += (_, _) =>
        {
            _progressTimer.Stop();
            SaveActiveProgress();
        };

        _notifyIcon = CreateNotifyIcon();
        Loaded += MainWindowLoaded;
        StateChanged += MainWindowStateChanged;
    }

    private async void MainWindowLoaded(object sender, RoutedEventArgs e)
    {
        _settings = _database.LoadSettings();
        ApplyWindowSettings();
        ApplyAppTheme(_settings.AppTheme, persist: false);
        ApplyTextColor(_settings.TextColor, persist: false);
        ApplyFontFamily(_settings.FontFamily, persist: false);
        ApplyFontSize(_settings.FontSize, persist: false);
        UrlBox.Text = _settings.LastUrl;
        _database.ClearExpiredContent(DateTime.UtcNow.AddDays(-15));
        UpdateHistoryMenu();

        try
        {
            CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(null, AppPaths.WebViewDataDirectory);
            await ParserView.EnsureCoreWebView2Async(environment);
            ParserView.CoreWebView2.Settings.AreDevToolsEnabled = false;
            ParserView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            _webViewReady = true;
            SetStatus("请输入章节网址");
        }
        catch (Exception exception)
        {
            SetStatus($"浏览器组件初始化失败：{exception.Message}", isError: true);
        }

        EnsureWindowVisible();
        UpdateCompactLayout();
        UpdateLibraryActions();
        _startupDisplayReady = true;
    }

    private void WindowSourceInitialized(object? sender, EventArgs e)
    {
        AppThemeService.Current.ApplyWindowChrome(this);
        if (!_hotKeyService.Register(this))
        {
            SetStatus("全局快捷键注册失败。", isError: true);
        }
        _hotKeyService.HotKeyPressed += (_, _) => ToggleTrayVisibility();
        _hotKeyService.NextChapterPressed += GlobalNextChapterPressed;
        _hotKeyService.PreviousChapterPressed += GlobalPreviousChapterPressed;
    }

    private async void ParseClick(object sender, RoutedEventArgs e)
    {
        await SubmitInputAsync();
    }

    private async void ReparseClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(_currentUrl))
        {
            await ParseUrlAsync(_currentUrl);
        }
    }

    private void InputUrlClick(object sender, RoutedEventArgs e)
    {
        SetSearchMode(false, clearInput: false);
        ShowInputPanel();
    }

    private void ReturnToSearchResultsClick(object sender, RoutedEventArgs e)
    {
        if (!_searchResultReturnAvailable || SearchResultsList.ItemsSource is null) return;

        SaveActiveProgress();
        SetSearchMode(true, clearInput: false, clearSearchResults: false);
        UrlBox.Text = _searchKeyword;
        ShowInputPanel();
        RestoreSearchResultsScroll();
        SetStatus($"已返回搜索结果：第 {_searchPageNumber} 页。");
    }

    private void ReturnToReadingClick(object sender, RoutedEventArgs e)
    {
        if (_isLoading || !HasReadingSession())
        {
            UpdateReturnToReadingButton();
            return;
        }

        SetSearchMode(false, clearInput: false, clearSearchResults: false);
        InputPanel.Visibility = Visibility.Collapsed;
        BookSourceSelectorPanel.Visibility = Visibility.Collapsed;
        SearchResultsList.Visibility = Visibility.Collapsed;
        SearchPaginationPanel.Visibility = Visibility.Collapsed;
        EmptyText.Visibility = Visibility.Collapsed;
        ReaderBox.Visibility = Visibility.Visible;
        UpdateReturnToSearchResultsMenu();
        UpdateReturnToReadingButton();
        UpdateChapterNavigationEnabled(readingActive: true);
        UpdateCurrentChapterHighlight();
        UpdateLibraryActions();
        RunViewTransition();
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded,
            new Action(() => RestoreProgress(_readingReturnProgress)));
        SetStatus($"已返回阅读：{_currentEntry!.Title}");
    }

    private void OpenLibraryClick(object sender, RoutedEventArgs e)
        => ShowLibraryPanel();

    private void FavoriteBookClick(object sender, RoutedEventArgs e)
    {
        LibraryBookEntry? book = _currentLibraryBook;
        if (book is null) return;

        SaveActiveProgress();
        try
        {
            if (book.IsFavorite)
            {
                _database.RemoveFavoriteLibraryBook(book.BookKey);
                book.FavoriteUtc = null;
                SetStatus($"已取消收藏：{book.Title}");
            }
            else
            {
                book.FavoriteUtc = DateTime.UtcNow;
                if (!_database.TryAddFavoriteLibraryBook(book))
                {
                    book.FavoriteUtc = null;
                    ShowTransientNotice($"收藏已达 {ReaderDatabase.MaximumFavoriteLibraryBooks} 本上限，请先移除一本收藏。", isWarning: true);
                    SetStatus("收藏数量已达上限。", isError: true);
                    UpdateLibraryActions();
                    return;
                }
                _currentLibraryBook = _database.GetLibraryBook(book.BookKey) ?? book;
                SetStatus($"已收藏：{book.Title}");
            }
            UpdateLibraryActions();
        }
        catch (Exception exception)
        {
            SetStatus($"收藏操作失败：{exception.Message}", isError: true);
        }
    }

    private void LibraryActionsTriggerMouseEnter(object sender, System.Windows.Input.MouseEventArgs e)
        => AnimateLibraryActionsVisibility(1);

    private void LibraryActionsTriggerMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!_libraryActionsAlwaysVisible)
        {
            AnimateLibraryActionsVisibility(0);
        }
    }

    private void LibraryBackClick(object sender, RoutedEventArgs e)
    {
        if (!_libraryPanelActive) return;

        LibraryReturnView returnView = _libraryReturnView;
        CloseLibraryPanelShell();
        switch (returnView)
        {
            case LibraryReturnView.Reader when HasReadingSession():
                InputPanel.Visibility = Visibility.Collapsed;
                BookSourceSelectorPanel.Visibility = Visibility.Collapsed;
                SearchResultsList.Visibility = Visibility.Collapsed;
                SearchPaginationPanel.Visibility = Visibility.Collapsed;
                EmptyText.Visibility = Visibility.Collapsed;
                ReaderBox.Visibility = Visibility.Visible;
                UpdateChapterNavigationEnabled(readingActive: true);
                UpdateCurrentChapterHighlight();
                Dispatcher.BeginInvoke(
                    DispatcherPriority.Loaded,
                    new Action(() => RestoreProgress(_readingReturnProgress)));
                break;
            case LibraryReturnView.SearchResults:
                InputPanel.Visibility = Visibility.Visible;
                ReaderBox.Visibility = Visibility.Collapsed;
                EmptyText.Visibility = Visibility.Collapsed;
                SearchResultsList.Visibility = SearchResultsList.ItemsSource is null
                    ? Visibility.Collapsed
                    : Visibility.Visible;
                RefreshBookSourceSelector();
                UpdateSearchPagination();
                RestoreSearchResultsScroll();
                UpdateChapterNavigationEnabled(readingActive: false);
                break;
            default:
                ShowInputPanel();
                break;
        }
        UpdateReturnToSearchResultsMenu();
        UpdateReturnToReadingButton();
        UpdateLibraryActions();
        RunViewTransition();
        SetStatus("已返回原界面。");
    }

    private void ShowLibraryPanel()
    {
        if (_libraryPanelActive) return;

        _libraryReturnView = ReaderBox.Visibility == Visibility.Visible
            ? LibraryReturnView.Reader
            : SearchResultsList.Visibility == Visibility.Visible
                ? LibraryReturnView.SearchResults
                : LibraryReturnView.Input;
        if (_libraryReturnView == LibraryReturnView.Reader)
        {
            SaveActiveProgress();
            _readingReturnProgress = GetCurrentReaderProgress();
        }
        else if (_libraryReturnView == LibraryReturnView.SearchResults)
        {
            SaveSearchResultsScroll();
        }

        _libraryPanelActive = true;
        RefreshLibraryPanel();
        InputPanel.Visibility = Visibility.Collapsed;
        BookSourceSelectorPanel.Visibility = Visibility.Collapsed;
        SearchResultsList.Visibility = Visibility.Collapsed;
        SearchPaginationPanel.Visibility = Visibility.Collapsed;
        ReaderBox.Visibility = Visibility.Collapsed;
        EmptyText.Visibility = Visibility.Collapsed;
        LibraryPanel.Visibility = Visibility.Visible;
        UpdateChapterNavigationEnabled(readingActive: false);
        UpdateReturnToReadingButton();
        UpdateLibraryActions();
        RunViewTransition();
        SetStatus("书库：可继续最近阅读或管理收藏。");
    }

    private void CloseLibraryPanelShell()
    {
        if (!_libraryPanelActive) return;
        _libraryPanelActive = false;
        LibraryPanel.Visibility = Visibility.Collapsed;
        UpdateLibraryActions();
    }

    private void RefreshLibraryPanel()
    {
        IReadOnlyList<LibraryBookEntry> recent = _database.GetRecentLibraryBooks();
        IReadOnlyList<LibraryBookEntry> favorites = _database.GetFavoriteLibraryBooks();
        RecentLibraryList.ItemsSource = recent;
        FavoriteLibraryList.ItemsSource = favorites;
        RecentLibraryEmptyText.Visibility = recent.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        FavoriteLibraryEmptyText.Visibility = favorites.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        FavoriteLibraryCountText.Text = $"{favorites.Count}/{ReaderDatabase.MaximumFavoriteLibraryBooks}";
    }

    private void LibraryListPreviewMouseWheel(object sender, System.Windows.Input.MouseWheelEventArgs e)
    {
        if (sender is not System.Windows.Controls.ListBox list || e.Delta == 0) return;
        ScrollViewer? scrollViewer = FindVisualChild<ScrollViewer>(list);
        if (scrollViewer is null) return;

        if (e.Delta < 0)
        {
            scrollViewer.LineDown();
        }
        else
        {
            scrollViewer.LineUp();
        }
        e.Handled = true;
    }

    private async void LibraryBookOpenRequested(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        LibraryBookCard? card = sender as LibraryBookCard ?? e.OriginalSource as LibraryBookCard;
        if (card?.Book is null) return;
        await OpenLibraryBookAsync(card.Book);
    }

    private async Task OpenLibraryBookAsync(LibraryBookEntry requestedBook)
    {
        if (!TryPrepareLibraryNavigation()) return;

        LibraryBookEntry book = _database.GetLibraryBook(requestedBook.BookKey) ?? requestedBook;
        string previousSourceId = _activeBookSourceId;
        string previousBookTitle = _currentBookTitle;
        string previousCatalogTitle = _chapterCatalogBookTitle;
        List<NovelChapterItem> previousCatalog = [.. _chapterCatalog];
        PageParseResult? previousPage = _currentPage;
        HistoryEntry? previousEntry = _currentEntry;
        LibraryBookEntry? previousLibraryBook = _currentLibraryBook;
        string previousUrl = _currentUrl;
        bool previousEntryWritesHistory = _currentEntryWritesHistory;
        double previousReadingProgress = _readingReturnProgress;

        try
        {
            if (string.IsNullOrWhiteSpace(book.SourceId) ||
                (!IsHttpUrl(book.DetailUrl) &&
                 !IsHttpUrl(book.ChapterUrl) &&
                 string.IsNullOrWhiteSpace(book.CatalogJson)))
            {
                ReportUnavailableLibraryBook();
                return;
            }

            BookSourceDefinition source = BookSourceCatalog.GetRequired(book.SourceId);
            _currentBookTitle = book.Title;
            _activeBookSourceId = source.ParserKind == BookSourceParserKind.HttpRules
                ? source.Id
                : string.Empty;

            string fallbackChapterUrl;
            if (TryRestoreCachedLibraryCatalog(book))
            {
                fallbackChapterUrl = _chapterCatalog.FirstOrDefault()?.Url ?? string.Empty;
            }
            else
            {
                SetStatus($"正在从 {source.Name} 恢复《{book.Title}》的章节目录…");
                fallbackChapterUrl = source.ParserKind == BookSourceParserKind.HttpRules
                    ? await ResolveBookSourceReadingUrlAsync(source, new NovelSearchResult
                    {
                        SourceId = source.Id,
                        SourceName = source.Name,
                        Title = book.Title,
                        Url = book.DetailUrl
                    })
                    : await ResolveReadingUrlAsync(book.DetailUrl);
            }

            string chapterUrl = IsHttpUrl(book.ChapterUrl) ? book.ChapterUrl : fallbackChapterUrl;
            if (!IsHttpUrl(chapterUrl))
            {
                throw new InvalidOperationException("书库记录中没有可用的章节地址。");
            }

            if (TryOpenLibraryBookFromCache(book, chapterUrl, previousPage, previousUrl))
            {
                RefreshLibraryPanel();
                UpdateLibraryActions();
                SetStatus($"已从本地缓存恢复阅读：{book.Title} · {(_currentPage?.Title ?? book.ChapterTitle)}");
                return;
            }

            bool opened = await ParseUrlAsync(
                chapterUrl,
                recordToHistory: false,
                libraryBookContext: book,
                replaceLibraryContext: true,
                restoreProgress: book.Progress,
                keepLibraryOpenOnFailure: true);
            if (!opened)
            {
                RestoreReadingSessionAfterLibraryFailure(
                    previousSourceId,
                    previousBookTitle,
                    previousCatalogTitle,
                    previousCatalog,
                    previousPage,
                    previousEntry,
                    previousLibraryBook,
                    previousUrl,
                    previousEntryWritesHistory,
                    previousReadingProgress);
                ReportUnavailableLibraryBook();
                return;
            }

            RefreshLibraryPanel();
            UpdateLibraryActions();
            SetStatus($"已恢复阅读：{book.Title} · {(_currentPage?.Title ?? book.ChapterTitle)}");
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"恢复书库阅读失败：{exception}");
            RestoreReadingSessionAfterLibraryFailure(
                previousSourceId,
                previousBookTitle,
                previousCatalogTitle,
                previousCatalog,
                previousPage,
                previousEntry,
                previousLibraryBook,
                previousUrl,
                previousEntryWritesHistory,
                previousReadingProgress);
            RefreshLibraryPanel();
            ReportUnavailableLibraryBook();
        }
    }

    private void ReportUnavailableLibraryBook()
        => SetStatus("该书籍的阅读数据已失效，请重新通过搜索结果进入。", isError: true);

    private bool TryOpenLibraryBookFromCache(
        LibraryBookEntry book,
        string chapterUrl,
        PageParseResult? previousPage,
        string previousUrl)
    {
        PageParseResult? page = null;
        HistoryEntry? entry = null;
        if (previousPage is { IsContentReady: true } &&
            string.Equals(
                NormalizeChapterUrl(previousUrl),
                NormalizeChapterUrl(chapterUrl),
                StringComparison.OrdinalIgnoreCase))
        {
            page = previousPage;
            entry = new HistoryEntry
            {
                Url = chapterUrl,
                Title = BuildDisplayTitle(page.Title),
                Content = page.Text,
                PreviousUrl = page.PreviousUrl,
                NextUrl = page.NextUrl,
                Progress = book.Progress,
                CreatedUtc = DateTime.UtcNow,
                LastReadUtc = DateTime.UtcNow,
                LastParsedUtc = DateTime.UtcNow,
                ParseCount = 1,
                SourceId = book.SourceId
            };
        }
        else
        {
            HistoryEntry? cached = _database.GetHistoryByUrl(chapterUrl);
            if (cached is null || string.IsNullOrWhiteSpace(cached.Content)) return false;
            page = new PageParseResult
            {
                Title = string.IsNullOrWhiteSpace(book.ChapterTitle) ? cached.Title : book.ChapterTitle,
                Text = cached.Content,
                PreviousUrl = cached.PreviousUrl,
                NextUrl = cached.NextUrl,
                SourceUrl = chapterUrl,
                IsContentReady = true
            };
            entry = new HistoryEntry
            {
                Id = cached.Id,
                Url = cached.Url,
                Title = cached.Title,
                Content = cached.Content,
                PreviousUrl = cached.PreviousUrl,
                NextUrl = cached.NextUrl,
                Progress = book.Progress,
                CreatedUtc = cached.CreatedUtc,
                LastReadUtc = DateTime.UtcNow,
                LastParsedUtc = cached.LastParsedUtc,
                ParseCount = cached.ParseCount,
                LocalPath = cached.LocalPath,
                SourceId = cached.SourceId
            };
        }

        _currentPage = page;
        _currentEntry = entry;
        _currentEntryWritesHistory = false;
        _currentLibraryBook = book;
        _currentUrl = chapterUrl;
        UrlBox.Text = chapterUrl;
        UpdateCurrentChapterHighlight();
        SaveCurrentBookToLibrary(page, book.Progress);
        RenderArticle(page, book.Progress);
        return true;
    }

    private bool TryPrepareLibraryNavigation()
    {
        if (!_isLoading) return true;
        if (!_searchModeActive)
        {
            SetStatus("当前解析尚未完成，请稍候再打开书库记录。", isError: true);
            return false;
        }

        _searchScopeVersion++;
        CancelActiveSearchForScopeSwitch();
        _isLoading = false;
        UpdateLoadingIndicator();
        ParseButton.IsEnabled = true;
        SetModeSelectorsEnabled(true);
        UpdateSearchPagination();
        return true;
    }

    private bool TryRestoreCachedLibraryCatalog(LibraryBookEntry book)
    {
        if (string.IsNullOrWhiteSpace(book.CatalogJson)) return false;
        try
        {
            List<NovelChapterItem> cached = JsonSerializer.Deserialize<List<NovelChapterItem>>(book.CatalogJson) ?? [];
            List<NovelChapterItem> chapters = cached
                .Where(chapter => !string.IsNullOrWhiteSpace(chapter.Title) && IsHttpUrl(chapter.Url))
                .GroupBy(chapter => NormalizeChapterUrl(chapter.Url), StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .ToList();
            if (chapters.Count == 0) return false;

            SetChapterCatalog(book.Title, chapters, "暂无目录");
            return true;
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"读取书库目录缓存失败：{exception}");
            return false;
        }
    }

    private void RestoreReadingSessionAfterLibraryFailure(
        string sourceId,
        string bookTitle,
        string catalogTitle,
        List<NovelChapterItem> catalog,
        PageParseResult? page,
        HistoryEntry? entry,
        LibraryBookEntry? libraryBook,
        string url,
        bool entryWritesHistory,
        double readingProgress)
    {
        _activeBookSourceId = sourceId;
        _currentBookTitle = bookTitle;
        _currentPage = page;
        _currentEntry = entry;
        _currentLibraryBook = libraryBook;
        _currentUrl = url;
        _currentEntryWritesHistory = entryWritesHistory;
        _readingReturnProgress = readingProgress;
        UrlBox.Text = string.IsNullOrWhiteSpace(url) ? UrlBox.Text : url;
        SetChapterCatalog(
            string.IsNullOrWhiteSpace(catalogTitle) ? bookTitle : catalogTitle,
            catalog,
            catalog.Count == 0 ? "暂无目录" : string.Empty);
        UpdateLibraryActions();
    }

    private void RecentLibraryDeleteRequested(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        LibraryBookCard? card = sender as LibraryBookCard ?? e.OriginalSource as LibraryBookCard;
        if (card?.Book is null) return;
        _database.DeleteRecentLibraryBook(card.Book.BookKey);
        RefreshLibraryPanel();
        SetStatus($"已从最近阅读移除：{card.Book.Title}");
    }

    private void FavoriteLibraryDeleteRequested(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        LibraryBookCard? card = sender as LibraryBookCard ?? e.OriginalSource as LibraryBookCard;
        if (card?.Book is null) return;
        bool confirmed = ThemedConfirmDialog.Show(
            this,
            "取消收藏",
            $"确定取消收藏《{card.Book.Title}》吗？",
            "确认取消");
        if (!confirmed) return;

        _database.RemoveFavoriteLibraryBook(card.Book.BookKey);
        LibraryBookEntry? currentLibraryBook = _currentLibraryBook;
        if (currentLibraryBook is not null &&
            string.Equals(currentLibraryBook.BookKey, card.Book.BookKey, StringComparison.Ordinal))
        {
            currentLibraryBook.FavoriteUtc = null;
        }
        RefreshLibraryPanel();
        UpdateLibraryActions();
        SetStatus($"已取消收藏：{card.Book.Title}");
    }

    private void UpdateLibraryActions()
    {
        if (_libraryPanelActive)
        {
            LibraryActionsOverlayHost.Visibility = Visibility.Collapsed;
            return;
        }

        LibraryActionsOverlayHost.Visibility = Visibility.Visible;
        bool readingVisible = ReaderBox.Visibility == Visibility.Visible;
        bool searchResultsVisible = SearchResultsList.Visibility == Visibility.Visible &&
            SearchResultsList.ItemsSource is not null;
        _libraryActionsAlwaysVisible = InputPanel.Visibility == Visibility.Visible &&
            !readingVisible &&
            !searchResultsVisible;

        bool canFavorite = readingVisible && _currentLibraryBook is not null;
        FavoriteBookButton.Visibility = canFavorite ? Visibility.Visible : Visibility.Collapsed;
        bool isFavorite = canFavorite && _currentLibraryBook!.IsFavorite;
        FavoriteBookIcon.Opacity = isFavorite ? 1 : 0;
        UnfavoriteBookIcon.Opacity = isFavorite ? 0 : 1;
        FavoriteBookButton.ToolTip = isFavorite ? "取消收藏当前书籍" : "收藏当前书籍";

        double targetOpacity = _libraryActionsAlwaysVisible || LibraryActionsTriggerZone.IsMouseOver ? 1 : 0;
        AnimateLibraryActionsVisibility(targetOpacity, animate: false);
    }

    private void AnimateLibraryActionsVisibility(double opacity, bool animate = true)
    {
        double targetOpacity = Math.Clamp(opacity, 0, 1);
        LibraryActionsButtons.IsHitTestVisible = targetOpacity > 0.01;
        LibraryActionsButtons.BeginAnimation(
            OpacityProperty,
            new DoubleAnimation(
                targetOpacity,
                animate
                    ? TimeSpan.FromMilliseconds(LibraryActionsFadeMilliseconds)
                    : TimeSpan.Zero)
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            },
            HandoffBehavior.SnapshotAndReplace);
    }

    private async void ShowTransientNotice(string message, bool isWarning)
    {
        int version = ++_transientNoticeVersion;
        TransientNoticeText.Text = message;
        TransientNoticeHost.BorderBrush = GetResourceBrush(isWarning ? "WarningBrush" : "AccentBrush");
        TransientNoticeHost.Visibility = Visibility.Visible;
        TransientNoticeHost.Opacity = 1;
        await Task.Delay(TransientNoticeMilliseconds);
        if (version != _transientNoticeVersion) return;

        DoubleAnimation fade = new(0, TimeSpan.FromMilliseconds(180));
        fade.Completed += (_, _) =>
        {
            if (version == _transientNoticeVersion)
            {
                TransientNoticeHost.Visibility = Visibility.Collapsed;
                TransientNoticeHost.Opacity = 1;
            }
        };
        TransientNoticeHost.BeginAnimation(OpacityProperty, fade);
    }

    private void ParseModeSelectorChecked(object sender, RoutedEventArgs e)
    {
        if (_updatingInputMode || !_searchModeActive) return;
        SetSearchMode(false, clearInput: true);
        ShowInputPanel();
    }

    private void SearchModeSelectorPreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount != 2) return;

        e.Handled = true;
        SwitchSearchScope();
    }

    private void SearchModeSelectorChecked(object sender, RoutedEventArgs e)
    {
        if (_updatingInputMode || _searchModeActive) return;
        SetSearchMode(true, clearInput: true);
        ShowInputPanel();
    }

    private async void HistoryMenuClick(object sender, RoutedEventArgs e)
    {
        HistoryWindow historyWindow = new(_database.GetRecentHistory(500), _database) { Owner = this };
        bool? shouldOpen = historyWindow.ShowDialog();
        if (shouldOpen == true && historyWindow.SelectedEntry is not null)
        {
            await OpenHistoryEntryAsync(historyWindow.SelectedEntry);
        }
        UpdateHistoryMenu();
    }

    private async void PreviousChapterClick(object sender, RoutedEventArgs e)
        => await NavigateChapterAsync(nextChapter: false);

    private async void NextChapterClick(object sender, RoutedEventArgs e)
        => await NavigateChapterAsync(nextChapter: true);

    private async void GlobalNextChapterPressed(object? sender, EventArgs e)
        => await NavigateChapterAsync(nextChapter: true);

    private async void GlobalPreviousChapterPressed(object? sender, EventArgs e)
        => await NavigateChapterAsync(nextChapter: false);

    private bool CanNavigateChapter(bool nextChapter)
        => !_isLoading &&
           HasReadingSession() &&
           _currentPage is not null &&
           !string.IsNullOrWhiteSpace(nextChapter ? _currentPage.NextUrl : _currentPage.PreviousUrl);

    private async Task NavigateChapterAsync(bool nextChapter)
    {
        if (!CanNavigateChapter(nextChapter) || _currentPage is null) return;

        if (_transparentModeActive)
        {
            SaveTransparentProgress();
        }

        string targetUrl = nextChapter ? _currentPage.NextUrl : _currentPage.PreviousUrl;
        bool opened = await ParseUrlAsync(targetUrl, recordToHistory: false);
        if (!opened) return;

        UpdateCurrentChapterHighlight();
        RefreshTransparentReaderContent();
    }

    private async void OpenLoginBrowserClick(object sender, RoutedEventArgs e)
    {
        string url = string.IsNullOrWhiteSpace(_currentUrl) ? UrlBox.Text.Trim() : _currentUrl;
        if (!IsHttpUrl(url))
        {
            SetStatus("请先输入有效的网址。", isError: true);
            ShowInputPanel();
            return;
        }

        LoginWindow loginWindow = new(url) { Owner = this };
        bool? shouldParse = loginWindow.ShowDialog();
        if (shouldParse == true)
        {
            await ParseUrlAsync(url);
        }
    }

    private void SaveTxtClick(object sender, RoutedEventArgs e)
    {
        if (_currentEntry is null) return;
        try
        {
            _currentEntry.LocalPath = TxtExporter.Export(_currentEntry);
            if (_currentEntryWritesHistory)
            {
                _database.SaveHistory(_currentEntry);
            }
            SetStatus($"已保存 TXT：{_currentEntry.LocalPath}");
        }
        catch (Exception exception)
        {
            SetStatus($"TXT 保存失败：{exception.Message}", isError: true);
        }
    }

    private void FontSizeClick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem item && double.TryParse(item.Tag?.ToString(), out double size))
        {
            SetExclusiveMenuCheck(item);
            ApplyFontSize(size, persist: true);
        }
    }

    private void FontFamilyClick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem item && item.Tag is string family)
        {
            SetExclusiveMenuCheck(item);
            ApplyFontFamily(family, persist: true);
        }
    }

    private void AppThemeClick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem item && item.Tag is string theme)
        {
            SetExclusiveMenuCheck(item);
            ApplyAppTheme(theme, persist: true);
        }
    }

    private void TextColorClick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem item)
        {
            SetExclusiveMenuCheck(item);
            ApplyTextColor(item.Tag?.ToString() ?? string.Empty, persist: true);
        }
    }

    private void CustomTextColorClick(object sender, RoutedEventArgs e)
    {
        using System.Windows.Forms.ColorDialog dialog = new()
        {
            FullOpen = true,
            Color = System.Drawing.ColorTranslator.FromHtml(string.IsNullOrWhiteSpace(_settings.TextColor) ? "#252525" : _settings.TextColor)
        };
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
        {
            ApplyTextColor(System.Drawing.ColorTranslator.ToHtml(dialog.Color), persist: true);
        }
    }

    private void AlwaysOnTopClick(object sender, RoutedEventArgs e)
    {
        Topmost = AlwaysOnTopMenuItem.IsChecked;
        if (_transparentWindow is not null)
        {
            _transparentWindow.Topmost = Topmost;
        }
    }

    private void MainWindowPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!_isChapterCatalogExpanded ||
            ChapterCatalogPanel.IsMouseOver ||
            ChapterCatalogTriggerZone.IsMouseOver)
        {
            return;
        }

        SetChapterCatalogExpanded(false, animate: true);
    }

    private async void MainWindowPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.F12)
        {
            if (!_transparentModeActive &&
                (ReaderBox.Visibility != Visibility.Visible || !HasReadingSession()))
            {
                return;
            }

            e.Handled = true;
            ToggleTransparentMode();
            return;
        }

        if (ReaderBox.Visibility != Visibility.Visible ||
            !HasReadingSession() ||
            MainMenu.IsKeyboardFocusWithin ||
            ChapterCatalogList.IsKeyboardFocusWithin)
        {
            return;
        }

        if (ReaderScrollController.HandleNavigationKey(ReaderBox, e.Key))
        {
            e.Handled = true;
            return;
        }

        if (e.Key is Key.Left or Key.Right && CanNavigateChapter(e.Key == Key.Right))
        {
            e.Handled = true;
            await NavigateChapterAsync(nextChapter: e.Key == Key.Right);
        }
    }

    private void HelpClick(object sender, RoutedEventArgs e)
        => InformationDialog.ShowDialogFor(this, InformationDialogPage.Guide);

    private void KeyboardShortcutsClick(object sender, RoutedEventArgs e)
        => InformationDialog.ShowDialogFor(this, InformationDialogPage.Shortcuts);

    private void AboutClick(object sender, RoutedEventArgs e)
        => InformationDialog.ShowDialogFor(this, InformationDialogPage.About);

    private async void UrlBoxKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            await SubmitInputAsync();
        }
    }

    private async Task SubmitInputAsync()
    {
        if (_searchModeActive)
        {
            await SearchFromInputAsync();
            return;
        }

        await ParseFromInputAsync();
    }

    private async Task ParseFromInputAsync()
    {
        string url = UrlBox.Text.Trim();
        if (!IsHttpUrl(url))
        {
            SetStatus("请输入以 http:// 或 https:// 开头的网址。", isError: true);
            UrlBox.Focus();
            return;
        }
        _currentBookTitle = string.Empty;
        _activeBookSourceId = string.Empty;
        ClearChapterCatalog("当前页面没有可用的章节目录。");
        await ParseUrlAsync(url, replaceLibraryContext: true);
    }

    private async Task SearchFromInputAsync()
    {
        string keyword = UrlBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(keyword))
        {
            SetStatus("请输入要搜索的小说名称。", isError: true);
            UrlBox.Focus();
            return;
        }
        _searchKeyword = keyword;
        if (_aggregatedSearchMode)
        {
            await LoadAggregatedSearchAsync();
        }
        else
        {
            await LoadSearchPageAsync(1);
        }
    }

    private async Task LoadAggregatedSearchAsync()
    {
        if (_isLoading || string.IsNullOrWhiteSpace(_searchKeyword)) return;

        int operationVersion = _searchScopeVersion;
        CancellationToken cancellationToken = BeginSearchOperation();
        int sourceCount = BookSourceCatalog.Aggregated.Count;
        _aggregatedSearchPageCache.Clear();
        _aggregatedSearchStates = BookSourceCatalog.Aggregated
            .Select(source => new BookSourceSearchState { Source = source })
            .ToList();
        _selectedAggregatedSourceId = _aggregatedSearchStates.FirstOrDefault()?.Source.Id ?? string.Empty;
        RefreshBookSourceSelector();
        HashSet<string> completedSources = new(StringComparer.OrdinalIgnoreCase);
        Progress<BookSourceSearchState> progress = new(state =>
        {
            if (!IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: true) ||
                cancellationToken.IsCancellationRequested)
            {
                return;
            }
            UpdateAggregatedSearchState(state);
            CacheAggregatedSearchPage(state);
            RefreshBookSourceSelector();
            if (string.Equals(_selectedAggregatedSourceId, state.Source.Id, StringComparison.OrdinalIgnoreCase) &&
                state.Status is BookSourceSearchStatus.Succeeded or BookSourceSearchStatus.Empty or BookSourceSearchStatus.Failed)
            {
                ShowSelectedAggregatedSourceResults(updateStatus: false);
            }
            if (state.Status is BookSourceSearchStatus.Succeeded or
                BookSourceSearchStatus.Empty or BookSourceSearchStatus.Failed)
            {
                completedSources.Add(state.Source.Id);
            }
            SetStatus($"正在从 {sourceCount} 个书源搜索中…已完成 {completedSources.Count}/{sourceCount}");
        });

        _isLoading = true;
        UpdateLoadingIndicator();
        ParseButton.IsEnabled = false;
        SetModeSelectorsEnabled(false);
        SearchResultsList.Visibility = Visibility.Collapsed;
        SearchPaginationPanel.Visibility = Visibility.Collapsed;
        SetStatus($"正在从 {sourceCount} 个书源搜索中…");

        try
        {
            IReadOnlyList<BookSourceSearchState> completedStates = await _aggregatedSearchService.SearchAllAsync(
                _searchKeyword, progress, cancellationToken);
            if (!IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: true)) return;
            _aggregatedSearchStates = completedStates;
            foreach (BookSourceSearchState state in _aggregatedSearchStates)
            {
                CacheAggregatedSearchPage(state);
            }
            BookSourceSearchState? selected = _aggregatedSearchStates.FirstOrDefault(state =>
                string.Equals(state.Source.Id, _selectedAggregatedSourceId, StringComparison.OrdinalIgnoreCase) &&
                state.Status is BookSourceSearchStatus.Succeeded or BookSourceSearchStatus.Empty);
            selected ??= _aggregatedSearchStates.FirstOrDefault(
                state => state.Status == BookSourceSearchStatus.Succeeded);
            selected ??= _aggregatedSearchStates.FirstOrDefault();

            _selectedAggregatedSourceId = selected?.Source.Id ?? string.Empty;
            RefreshBookSourceSelector();
            _searchResultReturnAvailable = false;
            _searchResultsScrollOffset = 0;
            ShowSelectedAggregatedSourceResults(updateStatus: false);
            RunViewTransition();

            int successCount = _aggregatedSearchStates.Count(
                state => state.Status is BookSourceSearchStatus.Succeeded or BookSourceSearchStatus.Empty);
            int failureCount = _aggregatedSearchStates.Count(
                state => state.Status == BookSourceSearchStatus.Failed);
            SetStatus($"聚合搜索完成：{successCount} 个书源返回，{failureCount} 个书源失败。请选择书源查看结果。");
        }
        catch (OperationCanceledException)
        {
            if (IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: true))
            {
                SetStatus("聚合搜索已取消。", isError: true);
            }
        }
        finally
        {
            if (IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: true))
            {
                _isLoading = false;
                UpdateLoadingIndicator();
                ParseButton.IsEnabled = true;
                SetModeSelectorsEnabled(true);
                UpdateSearchPagination();
            }
        }
    }

    private void BookSourceButtonClick(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.Button { Tag: string sourceId } || sourceId.Length == 0) return;

        bool sourceChanged = !string.Equals(
            _selectedAggregatedSourceId,
            sourceId,
            StringComparison.OrdinalIgnoreCase);
        _selectedAggregatedSourceId = sourceId;
        _searchResultsScrollOffset = 0;
        if (sourceChanged)
        {
            RestoreAggregatedSearchPage(sourceId, 1);
        }
        RefreshBookSourceSelector();
        ShowSelectedAggregatedSourceResults(updateStatus: true);
    }

    private void BookSourceSelectorPreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (sender is not ScrollViewer scrollViewer) return;

        double wheelNotches = e.Delta / 120d;
        double targetOffset = Math.Clamp(
            scrollViewer.HorizontalOffset - wheelNotches * BookSourceWheelScrollStep,
            0,
            scrollViewer.ScrollableWidth);
        scrollViewer.ScrollToHorizontalOffset(targetOffset);
        e.Handled = true;
    }

    private void BookSourceSelectorPreviewMouseButton(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Middle)
        {
            e.Handled = true;
        }
    }

    private void UpdateAggregatedSearchState(BookSourceSearchState updatedState)
    {
        List<BookSourceSearchState> states = _aggregatedSearchStates.ToList();
        int index = states.FindIndex(state =>
            string.Equals(state.Source.Id, updatedState.Source.Id, StringComparison.OrdinalIgnoreCase));
        if (index >= 0)
        {
            states[index] = updatedState;
        }
        else
        {
            states.Add(updatedState);
        }
        _aggregatedSearchStates = states;
    }

    private void CacheAggregatedSearchPage(BookSourceSearchState state)
    {
        if (state.Status is not (BookSourceSearchStatus.Succeeded or BookSourceSearchStatus.Empty)) return;
        if (!_aggregatedSearchPageCache.TryGetValue(state.Source.Id, out Dictionary<int, BookSourceSearchState>? pages))
        {
            pages = [];
            _aggregatedSearchPageCache[state.Source.Id] = pages;
        }
        pages[state.PageNumber] = state.Snapshot();
    }

    private bool RestoreAggregatedSearchPage(string sourceId, int pageNumber)
    {
        if (!_aggregatedSearchPageCache.TryGetValue(sourceId, out Dictionary<int, BookSourceSearchState>? pages) ||
            !pages.TryGetValue(pageNumber, out BookSourceSearchState? cached))
        {
            return false;
        }
        UpdateAggregatedSearchState(cached.Snapshot());
        return true;
    }

    private void RefreshBookSourceSelector()
    {
        bool show = !_libraryPanelActive &&
            _aggregatedSearchMode &&
            _searchModeActive &&
            _aggregatedSearchStates.Count > 0;
        BookSourceSelectorPanel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        SearchResultsList.Margin = show
            ? new Thickness(0, SearchResultsTopMarginWithBookSources, 0, 32)
            : new Thickness(0, SearchResultsTopMargin, 0, 32);
        BookSourceSelectorItems.ItemsSource = show
            ? _aggregatedSearchStates.Select(state => BookSourceSearchTab.FromState(
                state,
                string.Equals(state.Source.Id, _selectedAggregatedSourceId, StringComparison.OrdinalIgnoreCase))).ToList()
            : null;
    }

    private void ShowSelectedAggregatedSourceResults(bool updateStatus)
    {
        BookSourceSearchState? state = _aggregatedSearchStates.FirstOrDefault(item =>
            string.Equals(item.Source.Id, _selectedAggregatedSourceId, StringComparison.OrdinalIgnoreCase));
        if (state is null) return;

        _searchPageNumber = state.PageNumber;
        _searchHasNext = state.NextPageUrl.Length > 0;
        SearchResultsList.ItemsSource = state.Results;
        SearchResultsList.Visibility = _libraryPanelActive ? Visibility.Collapsed : Visibility.Visible;
        UpdateSearchPagination();
        ScrollSearchResultsToTop();
        if (!updateStatus) return;

        switch (state.Status)
        {
            case BookSourceSearchStatus.Pending:
            case BookSourceSearchStatus.Searching:
                SetStatus($"{state.Source.Name} 正在搜索中…");
                break;
            case BookSourceSearchStatus.Failed:
                SetStatus($"{state.Source.Name} 搜索失败：{state.ErrorMessage}", isError: true);
                break;
            default:
                SetStatus($"{state.Source.Name}：第 {state.PageNumber} 页，共 {state.ResultCount} 条结果。");
                break;
        }
    }

    private async Task<NovelSearchPage> SearchLegacyBookSourceAsync(
        BookSourceDefinition source,
        string keyword,
        int pageNumber,
        string? pageUrl,
        CancellationToken cancellationToken)
    {
        if (!_webViewReady)
        {
            throw new InvalidOperationException("WebView2 搜索组件尚未准备好。");
        }

        cancellationToken.ThrowIfCancellationRequested();
        string requestUrl = string.IsNullOrWhiteSpace(pageUrl)
            ? NovelSearchParser.CreateSearchUrl(keyword, pageNumber)
            : pageUrl;
        await NavigateToUrlAsync(requestUrl);
        await Task.Delay(DynamicContentPollMilliseconds, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        NovelSearchPage page = await _novelSearchParser.ExtractPageAsync(ParserView);
        page.NextPageUrl = page.HasNext
            ? NovelSearchParser.CreateSearchUrl(keyword, pageNumber + 1)
            : string.Empty;
        return page;
    }

    private async void PreviousSearchPageClick(object sender, RoutedEventArgs e)
    {
        if (_aggregatedSearchMode)
        {
            if (_searchPageNumber > 1 && RestoreAggregatedSearchPage(
                    _selectedAggregatedSourceId,
                    _searchPageNumber - 1))
            {
                RefreshBookSourceSelector();
                ShowSelectedAggregatedSourceResults(updateStatus: true);
            }
        }
        else if (_searchPageNumber > 1)
        {
            await LoadSearchPageAsync(_searchPageNumber - 1);
        }
    }

    private async void NextSearchPageClick(object sender, RoutedEventArgs e)
    {
        if (_aggregatedSearchMode)
        {
            if (_searchHasNext)
            {
                await LoadAggregatedSourcePageAsync(_searchPageNumber + 1);
            }
        }
        else if (_searchHasNext)
        {
            await LoadSearchPageAsync(_searchPageNumber + 1);
        }
    }

    private async Task LoadAggregatedSourcePageAsync(int pageNumber)
    {
        if (_isLoading || pageNumber < 1 || string.IsNullOrWhiteSpace(_selectedAggregatedSourceId)) return;
        if (RestoreAggregatedSearchPage(_selectedAggregatedSourceId, pageNumber))
        {
            RefreshBookSourceSelector();
            ShowSelectedAggregatedSourceResults(updateStatus: true);
            return;
        }

        BookSourceSearchState? current = _aggregatedSearchStates.FirstOrDefault(state =>
            string.Equals(state.Source.Id, _selectedAggregatedSourceId, StringComparison.OrdinalIgnoreCase));
        if (current is null || current.NextPageUrl.Length == 0) return;
        int operationVersion = _searchScopeVersion;
        CancellationToken cancellationToken = _aggregatedSearchCancellation?.Token ?? CancellationToken.None;

        _isLoading = true;
        UpdateLoadingIndicator();
        ParseButton.IsEnabled = false;
        SetModeSelectorsEnabled(false);
        UpdateSearchPagination();
        SetStatus($"正在加载 {current.Source.Name} 第 {pageNumber} 页…");
        try
        {
            BookSourceSearchState loaded = await _aggregatedSearchService.SearchSourcePageAsync(
                current.Source,
                _searchKeyword,
                pageNumber,
                current.NextPageUrl,
                cancellationToken);
            if (!IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: true)) return;
            if (loaded.Status == BookSourceSearchStatus.Failed)
            {
                SetStatus($"{current.Source.Name} 第 {pageNumber} 页加载失败：{loaded.ErrorMessage}", isError: true);
                return;
            }

            CacheAggregatedSearchPage(loaded);
            UpdateAggregatedSearchState(loaded);
            _searchResultsScrollOffset = 0;
            RefreshBookSourceSelector();
            ShowSelectedAggregatedSourceResults(updateStatus: true);
        }
        catch (OperationCanceledException)
        {
            if (IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: true))
            {
                SetStatus($"{current.Source.Name} 第 {pageNumber} 页加载已取消。", isError: true);
            }
        }
        finally
        {
            if (IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: true))
            {
                _isLoading = false;
                UpdateLoadingIndicator();
                ParseButton.IsEnabled = true;
                SetModeSelectorsEnabled(true);
                UpdateSearchPagination();
            }
        }
    }

    private async Task LoadSearchPageAsync(int pageNumber)
    {
        if (string.IsNullOrWhiteSpace(_searchKeyword)) return;
        if (!_webViewReady)
        {
            SetStatus("网页搜索组件尚未准备好，请稍后重试。", isError: true);
            return;
        }
        if (_isLoading) return;
        int operationVersion = _searchScopeVersion;
        CancellationToken cancellationToken = BeginSearchOperation();

        _isLoading = true;
        UpdateLoadingIndicator();
        ParseButton.IsEnabled = false;
        SetModeSelectorsEnabled(false);
        SearchResultsList.Visibility = Visibility.Collapsed;
        SearchPaginationPanel.Visibility = Visibility.Collapsed;
        SetStatus("正在从 18mh 小说网搜索，请稍候…");

        try
        {
            await NavigateToUrlAsync(
                NovelSearchParser.CreateSearchUrl(_searchKeyword, pageNumber),
                cancellationToken);
            await Task.Delay(DynamicContentPollMilliseconds, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            NovelSearchPage searchPage = await _novelSearchParser.ExtractPageAsync(ParserView);
            if (!IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: false)) return;
            _searchPageNumber = pageNumber;
            _searchHasNext = searchPage.HasNext;
            _searchResultReturnAvailable = false;
            _searchResultsScrollOffset = 0;
            SearchResultsList.ItemsSource = searchPage.Results;
            SearchResultsList.Visibility = Visibility.Visible;
            RunViewTransition();
            UpdateSearchPagination();
            ScrollSearchResultsToTop();
            SetStatus(searchPage.Results.Count == 0 ? "没有找到匹配的小说。" : $"第 {_searchPageNumber} 页：找到 {searchPage.Results.Count} 条结果，点击标题即可解析。");
        }
        catch (OperationCanceledException)
        {
            if (IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: false))
            {
                SetStatus("18mh 小说网搜索已取消。", isError: true);
            }
        }
        catch (Exception exception)
        {
            if (IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: false))
            {
                SetStatus($"搜索失败：{exception.Message}", isError: true);
            }
        }
        finally
        {
            if (IsCurrentSearchScopeOperation(operationVersion, aggregatedMode: false))
            {
                _isLoading = false;
                UpdateLoadingIndicator();
                ParseButton.IsEnabled = true;
                SetModeSelectorsEnabled(true);
                UpdateSearchPagination();
            }
        }
    }

    private async void SearchResultClick(object sender, MouseButtonEventArgs e)
    {
        ListBoxItem? item = ItemsControl.ContainerFromElement(SearchResultsList, e.OriginalSource as DependencyObject) as ListBoxItem;
        if (item?.DataContext is not NovelSearchResult result || !TryPrepareSearchResultNavigation(result)) return;
        SaveSearchResultsScroll();
        _searchResultReturnAvailable = true;
        SetSearchMode(false, clearInput: false, clearSearchResults: false);
        UrlBox.Text = result.Url;
        try
        {
            _currentBookTitle = result.Title;
            BookSourceDefinition source = string.IsNullOrWhiteSpace(result.SourceId)
                ? BookSourceCatalog.GetRequired(BookSourceCatalog.Legacy18MhId)
                : BookSourceCatalog.GetRequired(result.SourceId);
            _activeBookSourceId = source.ParserKind == BookSourceParserKind.HttpRules
                ? source.Id
                : string.Empty;
            string readingUrl = source.ParserKind == BookSourceParserKind.HttpRules
                ? await ResolveBookSourceReadingUrlAsync(source, result)
                : await ResolveReadingUrlAsync(result.Url);
            UrlBox.Text = readingUrl;
            LibraryBookEntry libraryBook = new()
            {
                BookKey = LibraryBookEntry.CreateBookKey(source.Id, result.Url),
                Title = _currentBookTitle,
                SourceId = source.Id,
                SourceName = source.Name,
                DetailUrl = result.Url,
                ChapterUrl = readingUrl,
                LastReadUtc = DateTime.UtcNow
            };
            await ParseUrlAsync(
                readingUrl,
                libraryBookContext: libraryBook,
                replaceLibraryContext: true);
        }
        catch (Exception exception)
        {
            _activeBookSourceId = string.Empty;
            _currentBookTitle = string.Empty;
            ClearChapterCatalog("目录加载失败，请重新选择书籍。");
            SetSearchMode(true, clearInput: false, clearSearchResults: false);
            UrlBox.Text = _searchKeyword;
            ShowInputPanel();
            RestoreSearchResultsScroll();
            SetStatus($"书籍解析失败：{exception.Message}", isError: true);
        }
    }

    private bool TryPrepareSearchResultNavigation(NovelSearchResult result)
    {
        if (!_aggregatedSearchMode)
        {
            return !_isLoading;
        }

        string sourceId = string.IsNullOrWhiteSpace(result.SourceId)
            ? _selectedAggregatedSourceId
            : result.SourceId;
        BookSourceSearchState? sourceState = _aggregatedSearchStates.FirstOrDefault(state =>
            string.Equals(state.Source.Id, sourceId, StringComparison.OrdinalIgnoreCase));
        bool isDisplayedSucceededResult = sourceState?.Status == BookSourceSearchStatus.Succeeded &&
            string.Equals(_selectedAggregatedSourceId, sourceId, StringComparison.OrdinalIgnoreCase) &&
            sourceState.Results.Any(candidate =>
                ReferenceEquals(candidate, result) ||
                string.Equals(candidate.Url, result.Url, StringComparison.OrdinalIgnoreCase));
        if (!isDisplayedSucceededResult)
        {
            return false;
        }

        if (!_isLoading)
        {
            return true;
        }

        // Invalidate queued progress callbacks before cancelling the outstanding source requests.
        // The completed source/page caches remain available for "返回搜索结果".
        _searchScopeVersion++;
        _aggregatedSearchCancellation?.Cancel();
        _isLoading = false;
        UpdateLoadingIndicator();
        ParseButton.IsEnabled = true;
        SetModeSelectorsEnabled(true);
        UpdateSearchPagination();
        return true;
    }

    private async Task<string> ResolveBookSourceReadingUrlAsync(
        BookSourceDefinition source,
        NovelSearchResult searchResult)
    {
        _isLoading = true;
        UpdateLoadingIndicator();
        ParseButton.IsEnabled = false;
        SetModeSelectorsEnabled(false);
        SetStatus($"正在从 {source.Name} 解析书籍详情与章节目录…");
        try
        {
            BookSourceBookPage book = await _bookSourceParser.ResolveBookAsync(source, searchResult.Url);
            if (!string.IsNullOrWhiteSpace(book.Title)) _currentBookTitle = book.Title;
            SetChapterCatalog(_currentBookTitle, book.Chapters, "该书源暂未提供章节目录。");
            if (!IsHttpUrl(book.FirstChapterUrl))
            {
                throw new InvalidOperationException($"{source.Name} 没有可用的章节入口。");
            }
            return book.FirstChapterUrl;
        }
        finally
        {
            _isLoading = false;
            UpdateLoadingIndicator();
            ParseButton.IsEnabled = true;
            SetModeSelectorsEnabled(true);
        }
    }

    private async Task<string> ResolveReadingUrlAsync(string detailUrl)
    {
        if (!_webViewReady)
        {
            throw new InvalidOperationException("网页解析组件尚未准备好，请稍后重试。");
        }

        _isLoading = true;
        UpdateLoadingIndicator();
        ParseButton.IsEnabled = false;
        SetModeSelectorsEnabled(false);
        SetStatus("正在打开书籍并定位“开始阅读”…");
        try
        {
            await NavigateToUrlAsync(detailUrl);
            await Task.Delay(DynamicContentPollMilliseconds);

            try
            {
                List<NovelChapterItem> chapters = await _novelSearchParser.ExtractChapterCatalogAsync(ParserView);
                SetChapterCatalog(_currentBookTitle, chapters,
                    chapters.Count == 0 ? "该书籍详情页暂未提供章节目录。" : "暂无目录");
            }
            catch (Exception exception)
            {
                SetChapterCatalog(_currentBookTitle, [], $"目录解析失败：{exception.Message}");
            }

            string readingUrl = await _novelSearchParser.ExtractReadingUrlAsync(ParserView);
            if (!IsHttpUrl(readingUrl))
            {
                throw new InvalidOperationException("该书籍详情页没有可用的章节入口。");
            }
            return readingUrl;
        }
        finally
        {
            _isLoading = false;
            UpdateLoadingIndicator();
            ParseButton.IsEnabled = true;
            SetModeSelectorsEnabled(true);
        }
    }

    private void SetChapterCatalog(string bookTitle, IEnumerable<NovelChapterItem> chapters, string emptyMessage)
    {
        _chapterCatalogBookTitle = bookTitle.Trim();
        _chapterCatalogSourceId = _activeBookSourceId;
        _chapterCatalog = chapters
            .Where(chapter => !string.IsNullOrWhiteSpace(chapter.Title) && IsHttpUrl(chapter.Url))
            .GroupBy(chapter => NormalizeChapterUrl(chapter.Url), StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToList();

        ChapterCatalogBookTitle.Text = string.IsNullOrWhiteSpace(_chapterCatalogBookTitle)
            ? "当前书籍"
            : _chapterCatalogBookTitle;
        ChapterCatalogBookTitle.ToolTip = ChapterCatalogBookTitle.Text;
        ChapterCatalogCountText.Text = _chapterCatalog.Count > 0 ? $"{_chapterCatalog.Count} 章" : string.Empty;
        ChapterCatalogList.ItemsSource = _chapterCatalog;
        ChapterCatalogList.Visibility = _chapterCatalog.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ChapterCatalogEmptyText.Text = string.IsNullOrWhiteSpace(emptyMessage) ? "暂无目录" : emptyMessage;
        ChapterCatalogEmptyText.Visibility = _chapterCatalog.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SetChapterCatalogExpanded(false, animate: false);
        UpdateCurrentChapterHighlight();
    }

    private void ClearChapterCatalog(string message)
        => SetChapterCatalog(_currentBookTitle, [], message);

    private void UpdateCurrentChapterHighlight()
    {
        NovelChapterItem? current = _chapterCatalog.FirstOrDefault(chapter =>
            AreSameChapterUrl(chapter.Url, _currentUrl));
        ChapterCatalogList.SelectedItem = current;
        if (current is not null && _isChapterCatalogExpanded)
        {
            Dispatcher.BeginInvoke(DispatcherPriority.Loaded,
                new Action(() => ChapterCatalogList.ScrollIntoView(current)));
        }
    }

    private async void ChapterCatalogItemClick(object sender, MouseButtonEventArgs e)
    {
        ListBoxItem? item = ItemsControl.ContainerFromElement(
            ChapterCatalogList, e.OriginalSource as DependencyObject) as ListBoxItem;
        if (item?.DataContext is not NovelChapterItem chapter || _isLoading) return;
        if (AreSameChapterUrl(chapter.Url, _currentUrl)) return;

        await ParseUrlAsync(chapter.Url, recordToHistory: false);
        UpdateCurrentChapterHighlight();
    }

    private void ChapterCatalogTriggerMouseEnter(object sender, System.Windows.Input.MouseEventArgs e)
        => AnimateChapterCatalogToggleVisibility(1);

    private void ChapterCatalogTriggerMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!_isChapterCatalogExpanded)
        {
            AnimateChapterCatalogToggleVisibility(0);
        }
    }

    private void ChapterCatalogToggleClick(object sender, RoutedEventArgs e)
        => SetChapterCatalogExpanded(!_isChapterCatalogExpanded, animate: true);

    private void SetChapterCatalogExpanded(bool expanded, bool animate)
    {
        _isChapterCatalogExpanded = expanded;
        double targetOffset = expanded ? 0 : ChapterCatalogHiddenOffset;
        ChapterCatalogToggleButton.ToolTip = expanded ? "收起章节目录" : "展开章节目录";
        AnimateChapterCatalogIcon(expanded, animate);
        AnimateChapterCatalogToggleVisibility(expanded || ChapterCatalogTriggerZone.IsMouseOver ? 1 : 0);

        if (expanded)
        {
            ChapterCatalogPanel.IsHitTestVisible = true;
        }

        if (!animate)
        {
            ChapterCatalogTranslate.BeginAnimation(TranslateTransform.XProperty, null);
            ChapterCatalogTranslate.X = targetOffset;
            ChapterCatalogPanel.IsHitTestVisible = expanded;
            return;
        }

        double currentOffset = ChapterCatalogTranslate.X;
        ChapterCatalogTranslate.BeginAnimation(TranslateTransform.XProperty, null);
        ChapterCatalogTranslate.X = currentOffset;
        DoubleAnimation slide = new(targetOffset, TimeSpan.FromMilliseconds(ChapterCatalogAnimationMilliseconds))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.HoldEnd
        };
        slide.Completed += (_, _) =>
        {
            if (_isChapterCatalogExpanded == expanded)
            {
                ChapterCatalogPanel.IsHitTestVisible = expanded;
                if (expanded)
                {
                    UpdateCurrentChapterHighlight();
                }
            }
        };
        ChapterCatalogTranslate.BeginAnimation(TranslateTransform.XProperty, slide, HandoffBehavior.SnapshotAndReplace);
    }

    private void AnimateChapterCatalogToggleVisibility(double opacity)
    {
        ChapterCatalogToggleButton.BeginAnimation(OpacityProperty,
            new DoubleAnimation(opacity, TimeSpan.FromMilliseconds(ChapterCatalogFadeMilliseconds))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            },
            HandoffBehavior.SnapshotAndReplace);
    }

    private void AnimateChapterCatalogIcon(bool expanded, bool animate)
    {
        TimeSpan duration = animate
            ? TimeSpan.FromMilliseconds(ChapterCatalogFadeMilliseconds)
            : TimeSpan.Zero;
        ChapterCatalogExpandIcon.BeginAnimation(OpacityProperty,
            new DoubleAnimation(expanded ? 0 : 1, duration), HandoffBehavior.SnapshotAndReplace);
        ChapterCatalogCollapseIcon.BeginAnimation(OpacityProperty,
            new DoubleAnimation(expanded ? 1 : 0, duration), HandoffBehavior.SnapshotAndReplace);
    }

    private static bool AreSameChapterUrl(string left, string right)
        => string.Equals(NormalizeChapterUrl(left), NormalizeChapterUrl(right), StringComparison.OrdinalIgnoreCase);

    private static string NormalizeChapterUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out Uri? uri)) return value.Trim();
        return uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
    }

    private async Task<bool> ParseUrlAsync(
        string url,
        bool isExpiredHistoryCache = false,
        bool recordToHistory = true,
        LibraryBookEntry? libraryBookContext = null,
        bool replaceLibraryContext = false,
        double? restoreProgress = null,
        bool keepLibraryOpenOnFailure = false)
    {
        if (_isLoading) return false;
        BookSourceDefinition? activeSource = GetActiveHttpBookSource();
        if (activeSource is null && !_webViewReady)
        {
            SetStatus("网页解析组件尚未准备好，请稍后重试。", isError: true);
            return false;
        }

        _isLoading = true;
        UpdateLoadingIndicator();
        ParseButton.IsEnabled = false;
        SetModeSelectorsEnabled(false);
        SetStatus(activeSource is null
            ? "正在打开网页并提取正文，请稍候……"
            : $"正在从 {activeSource.Name} 提取章节正文，请稍候……");
        SaveCurrentProgress();
        bool readerWasVisible = ReaderBox.Visibility == Visibility.Visible;

        try
        {
            PageParseResult result = activeSource is null
                ? await NavigateAndExtractAsync(url)
                : await _bookSourceParser.ParseChapterAsync(activeSource, url, _chapterCatalog);
            _currentPage = result;
            _currentUrl = string.IsNullOrWhiteSpace(result.SourceUrl) ? url : result.SourceUrl;
            UpdateCurrentChapterHighlight();
            UrlBox.Text = _currentUrl;
            if (recordToHistory)
            {
                _settings.LastUrl = _currentUrl;
                _database.SetSetting("LastUrl", _settings.LastUrl);
            }

            HistoryEntry? previous = recordToHistory ? _database.GetHistoryByUrl(_currentUrl) : null;
            HistoryEntry entry = new()
            {
                Url = _currentUrl,
                Title = BuildDisplayTitle(result.Title),
                Content = result.Text,
                PreviousUrl = result.PreviousUrl,
                NextUrl = result.NextUrl,
                Progress = restoreProgress ?? previous?.Progress ?? 0,
                CreatedUtc = previous?.CreatedUtc ?? DateTime.UtcNow,
                LastReadUtc = DateTime.UtcNow,
                LastParsedUtc = DateTime.UtcNow,
                ParseCount = (previous?.ParseCount ?? 0) + 1,
                LocalPath = previous?.LocalPath ?? string.Empty,
                SourceId = activeSource?.Id ?? string.Empty
            };
            if (recordToHistory)
            {
                _database.SaveHistory(entry);
            }
            _database.ClearExpiredContent(DateTime.UtcNow.AddDays(-15));
            _currentEntry = entry;
            _currentEntryWritesHistory = recordToHistory;
            if (replaceLibraryContext)
            {
                _currentLibraryBook = libraryBookContext;
            }
            SaveCurrentBookToLibrary(result, entry.Progress);

            RenderArticle(result, entry.Progress);
            UpdateHistoryMenu();
            SetStatus($"已解析：{entry.Title}");
            return true;
        }
        catch (Exception exception)
        {
            string prefix = isExpiredHistoryCache ? "本地正文缓存已过期，重新解析失败" : "解析失败";
            SetStatus($"{prefix}：{exception.Message}", isError: true);
            if (keepLibraryOpenOnFailure && _libraryPanelActive)
            {
                RefreshLibraryPanel();
            }
            else if (!readerWasVisible && _aggregatedSearchMode && _searchResultReturnAvailable)
            {
                SetSearchMode(true, clearInput: false, clearSearchResults: false);
                UrlBox.Text = _searchKeyword;
                ShowInputPanel();
                RestoreSearchResultsScroll();
            }
            else if (!readerWasVisible)
            {
                ShowInputPanel();
            }
            return false;
        }
        finally
        {
            _isLoading = false;
            UpdateLoadingIndicator();
            ParseButton.IsEnabled = true;
            SetModeSelectorsEnabled(true);
        }
    }

    private BookSourceDefinition? GetActiveHttpBookSource()
    {
        if (string.IsNullOrWhiteSpace(_activeBookSourceId)) return null;
        return BookSourceCatalog.All.FirstOrDefault(source =>
            source.ParserKind == BookSourceParserKind.HttpRules &&
            string.Equals(source.Id, _activeBookSourceId, StringComparison.OrdinalIgnoreCase));
    }

    private async Task<PageParseResult> NavigateAndExtractAsync(string url)
    {
        await NavigateToUrlAsync(url);

        PageParseResult? last = null;
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(DynamicContentTimeoutMilliseconds);
        do
        {
            await Task.Delay(DynamicContentPollMilliseconds);
            try
            {
                last = await _pageParser.ExtractAsync(ParserView);
                if (PageParser.IsUseful(last))
                {
                    return await _pageParser.LoadLazyContentAsync(ParserView, last);
                }
            }
            catch (InvalidOperationException)
            {
                // Dynamic pages can create the article shell before inserting its text.
                // Keep polling until the bounded content wait expires.
            }
        }
        while (DateTime.UtcNow < deadline);

        throw new InvalidOperationException("正文内容尚未加载完成，或当前页面未找到可识别的正文结构。");
    }

    private async Task NavigateToUrlAsync(string url, CancellationToken cancellationToken = default)
    {
        TaskCompletionSource<bool> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        _navigationCompletion = completion;
        try
        {
            try
            {
                ParserView.CoreWebView2.Navigate(url);
            }
            catch (Exception exception)
            {
                throw new InvalidOperationException($"无法打开网址：{exception.Message}", exception);
            }

            Task finished = await Task.WhenAny(
                completion.Task,
                Task.Delay(NavigationTimeoutMilliseconds, cancellationToken));
            cancellationToken.ThrowIfCancellationRequested();
            if (finished != completion.Task)
            {
                throw new TimeoutException("网页加载超时。");
            }
            if (!await completion.Task)
            {
                throw new InvalidOperationException("网页加载失败，请检查网址或网络连接。");
            }
        }
        finally
        {
            if (ReferenceEquals(_navigationCompletion, completion))
            {
                _navigationCompletion = null;
            }
        }
    }

    private void ParserViewNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        _navigationCompletion?.TrySetResult(e.IsSuccess);
    }

    private void RenderArticle(PageParseResult result, double progress)
    {
        FlowDocument document = ArticleDocumentFactory.Create(
            result.Text,
            _settings.FontFamily,
            _settings.FontSize,
            GetReadingForeground());
        CloseLibraryPanelShell();
        _readingReturnProgress = Math.Clamp(progress, 0, 1);
        ReaderBox.Document = document;
        ReaderBox.Visibility = Visibility.Visible;
        InputPanel.Visibility = Visibility.Collapsed;
        BookSourceSelectorPanel.Visibility = Visibility.Collapsed;
        SearchResultsList.Visibility = Visibility.Collapsed;
        SearchPaginationPanel.Visibility = Visibility.Collapsed;
        EmptyText.Visibility = Visibility.Collapsed;
        UpdateReturnToSearchResultsMenu();
        ReparseMenuItem.IsEnabled = true;
        OpenLoginMenuItem.IsEnabled = true;
        SaveTxtMenuItem.IsEnabled = true;
        UpdateReturnToReadingButton();
        UpdateChapterNavigationEnabled(readingActive: true);
        UpdateCurrentChapterHighlight();
        UpdateLibraryActions();
        RunViewTransition();

        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() => RestoreProgress(progress)));
        if (_settings.TransparentMode)
        {
            Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(EnterTransparentMode));
        }
    }

    private void ShowInputPanel()
    {
        CloseLibraryPanelShell();
        if (ReaderBox.Visibility == Visibility.Visible)
        {
            _readingReturnProgress = GetCurrentReaderProgress();
        }
        InputPanel.Visibility = Visibility.Visible;
        ReaderBox.Visibility = Visibility.Collapsed;
        EmptyText.Visibility = Visibility.Collapsed;
        SearchResultsList.Visibility = _searchModeActive && SearchResultsList.ItemsSource is not null
            ? Visibility.Visible
            : Visibility.Collapsed;
        RefreshBookSourceSelector();
        UpdateSearchPagination();
        UpdateChapterNavigationEnabled(readingActive: false);
        UpdateReturnToReadingButton();
        UpdateLibraryActions();
        RunViewTransition();
        UrlBox.Focus();
        UrlBox.SelectAll();
    }

    private void SetSearchMode(bool searchMode, bool clearInput, bool clearSearchResults = true)
    {
        _searchModeActive = searchMode;
        _updatingInputMode = true;
        ParseModeSelector.IsChecked = !searchMode;
        SearchModeSelector.IsChecked = searchMode;
        _updatingInputMode = false;
        ParseButton.Content = searchMode ? "开始搜索" : "开始解析";
        ParseButton.ToolTip = searchMode
            ? _aggregatedSearchMode ? "同时搜索全部内置书源" : "仅搜索 18mh 小说网"
            : "解析输入的网址";
        UrlBox.ToolTip = searchMode
            ? _aggregatedSearchMode
                ? "输入小说名称、作者或关键词，同时搜索全部内置书源"
                : "输入小说名称、作者或关键词，仅搜索 18mh 小说网"
            : "输入文章或小说章节网址，按 Enter 或点击开始解析";
        UrlBox.Tag = searchMode ? "输入小说名称、作者或关键词" : "输入文章或章节网址";
        InputPanel.VerticalAlignment = searchMode ? VerticalAlignment.Top : VerticalAlignment.Center;
        if (!_isLoading)
        {
            SetStatus(searchMode
                ? _aggregatedSearchMode
                    ? $"请输入书名或作者，将同时搜索 {BookSourceCatalog.Aggregated.Count} 个书源。"
                    : "请输入要在 18mh 小说网单独搜索的小说名称。"
                : "请输入文章或章节网址。");
        }
        if (clearSearchResults)
        {
            ClearSearchResults();
        }
        else
        {
            BookSourceSelectorPanel.Visibility = Visibility.Collapsed;
            SearchResultsList.Visibility = Visibility.Collapsed;
            SearchPaginationPanel.Visibility = Visibility.Collapsed;
        }
        if (clearInput)
        {
            UrlBox.Clear();
        }
        UpdateReturnToSearchResultsMenu();
    }

    private void SetModeSelectorsEnabled(bool enabled)
    {
        ParseModeSelector.IsEnabled = enabled;
        SearchModeSelector.IsEnabled = enabled || _searchModeActive;
    }

    private void SetAggregatedSearchMode(bool enabled)
    {
        _aggregatedSearchMode = enabled;
        SearchModeSelector.ToolTip = enabled
            ? $"小说搜索：默认聚合搜索全部 {BookSourceCatalog.Aggregated.Count} 个书源；双击切换为 18mh 小说网单独搜索"
            : "小说搜索：当前为 18mh 小说网单独搜索；双击切回聚合搜索";
        ApplySearchScopeAccent();
        ApplyTrayMenuTheme();
        if (!enabled)
        {
            _aggregatedSearchStates = [];
            _aggregatedSearchPageCache.Clear();
            _selectedAggregatedSourceId = string.Empty;
        }
        RefreshBookSourceSelector();
    }

    private void SwitchSearchScope()
    {
        bool enableAggregatedSearch = !_aggregatedSearchMode;
        _searchScopeVersion++;
        CancelActiveSearchForScopeSwitch();
        SetAggregatedSearchMode(enableAggregatedSearch);
        ClearSearchResults();
        SetSearchMode(searchMode: true, clearInput: false, clearSearchResults: false);
        ShowInputPanel();
        SetStatus(enableAggregatedSearch
            ? $"已切换为聚合搜索：将同时搜索 {BookSourceCatalog.Aggregated.Count} 个书源。"
            : "已切换为 18mh 小说网单独搜索。");
    }

    private void CancelActiveSearchForScopeSwitch()
    {
        _aggregatedSearchCancellation?.Cancel();
        if (!_searchModeActive || _navigationCompletion is null) return;

        _navigationCompletion.TrySetCanceled();
        if (!_webViewReady) return;
        try
        {
            ParserView.CoreWebView2.Stop();
        }
        catch
        {
            // The legacy WebView may already have completed between cancellation and Stop().
        }
    }

    private CancellationToken BeginSearchOperation()
    {
        _aggregatedSearchCancellation?.Cancel();
        _aggregatedSearchCancellation?.Dispose();
        _aggregatedSearchCancellation = new CancellationTokenSource();
        return _aggregatedSearchCancellation.Token;
    }

    private bool IsCurrentSearchScopeOperation(int operationVersion, bool aggregatedMode)
        => operationVersion == _searchScopeVersion && _aggregatedSearchMode == aggregatedMode;

    private void ApplySearchScopeAccent()
    {
        ResourceDictionary resources = System.Windows.Application.Current?.Resources ?? Resources;
        foreach ((string target, _) in SearchScopeAccentResources)
        {
            resources.Remove(target);
        }
        if (_aggregatedSearchMode) return;

        foreach ((string target, string legacySource) in SearchScopeAccentResources)
        {
            if (TryFindResource(legacySource) is not System.Windows.Media.Brush sourceBrush) continue;
            System.Windows.Media.Brush accentBrush = sourceBrush.CloneCurrentValue();
            accentBrush.Freeze();
            resources[target] = accentBrush;
        }
    }

    private void ClearSearchResults()
    {
        SearchResultsList.ItemsSource = null;
        SearchResultsList.Visibility = Visibility.Collapsed;
        _aggregatedSearchStates = [];
        _aggregatedSearchPageCache.Clear();
        _selectedAggregatedSourceId = string.Empty;
        RefreshBookSourceSelector();
        SearchPaginationPanel.Visibility = Visibility.Collapsed;
        _searchKeyword = string.Empty;
        _searchPageNumber = 1;
        _searchHasNext = false;
        _searchResultReturnAvailable = false;
        _searchResultsScrollOffset = 0;
        UpdateReturnToSearchResultsMenu();
        UpdateLibraryActions();
    }

    private void SaveSearchResultsScroll()
    {
        ScrollViewer? scrollViewer = FindVisualChild<ScrollViewer>(SearchResultsList);
        if (scrollViewer is not null)
        {
            _searchResultsScrollOffset = scrollViewer.VerticalOffset;
        }
    }

    private void RestoreSearchResultsScroll()
    {
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            ScrollViewer? scrollViewer = FindVisualChild<ScrollViewer>(SearchResultsList);
            scrollViewer?.ScrollToVerticalOffset(_searchResultsScrollOffset);
        }));
    }

    private void ScrollSearchResultsToTop()
    {
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            ScrollViewer? scrollViewer = FindVisualChild<ScrollViewer>(SearchResultsList);
            scrollViewer?.ScrollToTop();
        }));
    }

    private void UpdateSearchPagination()
    {
        bool showPagination = !_libraryPanelActive &&
            _searchModeActive &&
            SearchResultsList.ItemsSource is not null;
        SearchPaginationPanel.Visibility = showPagination ? Visibility.Visible : Visibility.Collapsed;
        UpdateLibraryActions();
        if (!showPagination) return;

        SearchPageText.Text = $"第 {_searchPageNumber} 页";
        PreviousSearchPageButton.IsEnabled = _searchPageNumber > 1 && !_isLoading;
        NextSearchPageButton.IsEnabled = _searchHasNext && !_isLoading;
    }

    private void UpdateReturnToSearchResultsMenu()
    {
        ReturnToSearchResultsMenuItem.IsEnabled = _searchResultReturnAvailable && !_searchModeActive;
    }

    private bool HasReadingSession()
        => _currentPage is { IsContentReady: true } &&
           _currentEntry is not null &&
           ReaderBox.Document is not null;

    private void UpdateReturnToReadingButton()
    {
        bool show = !_libraryPanelActive &&
            ReaderBox.Visibility != Visibility.Visible &&
            HasReadingSession();
        ReturnToReadingButton.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        ReturnToReadingButton.IsEnabled = show && !_isLoading;
    }

    private void UpdateChapterNavigationEnabled(bool readingActive)
    {
        bool hasPreviousChapter = readingActive &&
            _currentPage is not null &&
            !string.IsNullOrWhiteSpace(_currentPage.PreviousUrl);
        bool hasNextChapter = readingActive &&
            _currentPage is not null &&
            !string.IsNullOrWhiteSpace(_currentPage.NextUrl);
        PreviousChapterMenuItem.IsEnabled = hasPreviousChapter;
        PreviousChapterButton.IsEnabled = hasPreviousChapter;
        NextChapterMenuItem.IsEnabled = hasNextChapter;
        NextChapterButton.IsEnabled = hasNextChapter;
    }

    private void ToggleTransparentMode()
    {
        if (_transparentModeActive)
        {
            ReturnToNormalMode();
        }
        else
        {
            EnterTransparentMode();
        }
    }

    private void EnterTransparentMode()
    {
        if (_transparentModeActive) return;
        if (_currentEntry is null)
        {
            SetStatus("请先解析文章，再按 F12 进入透明阅读。", isError: true);
            return;
        }

        SaveCurrentProgress();
        Rect readerViewportScreenBounds = GetReaderViewportScreenBounds();
        TransparentReaderWindow readerWindow = GetTransparentWindow();
        Rect bounds = WindowState == WindowState.Maximized ? RestoreBounds : new Rect(Left, Top, Width, Height);
        readerWindow.WindowState = WindowState.Normal;
        readerWindow.Left = bounds.Left;
        readerWindow.Top = bounds.Top;
        readerWindow.Width = Math.Max(MinWidth, bounds.Width);
        readerWindow.Height = Math.Max(MinHeight, bounds.Height);
        readerWindow.Topmost = Topmost;
        readerWindow.ShowInTaskbar = false;
        _transparentModeActive = true;
        _settings.TransparentMode = true;
        _database.SetSetting("TransparentMode", bool.TrueString);
        readerWindow.ShowArticle(_currentEntry, _settings, GetReadingForeground(), _currentEntry.Progress);
        readerWindow.Show();
        readerWindow.MatchReaderViewport(readerViewportScreenBounds);
        readerWindow.FocusReader();
        ShowInTaskbar = false;
        Hide();
    }

    private TransparentReaderWindow GetTransparentWindow()
    {
        if (_transparentWindow is not null) return _transparentWindow;

        _transparentWindow = new TransparentReaderWindow();
        _transparentWindow.ReturnToNormalRequested += (_, _) => ReturnToNormalMode();
        _transparentWindow.NextChapterRequested += GlobalNextChapterPressed;
        _transparentWindow.PreviousChapterRequested += GlobalPreviousChapterPressed;
        _transparentWindow.ReadingProgressChanged += (_, progress) =>
        {
            if (_currentEntry is null) return;
            _currentEntry.Progress = progress;
            _progressTimer.Stop();
            _progressTimer.Start();
        };
        return _transparentWindow;
    }

    private void RefreshTransparentReaderContent()
    {
        if (!_transparentModeActive || _transparentWindow is null || _currentEntry is null) return;
        _transparentWindow.ShowArticle(
            _currentEntry,
            _settings,
            GetReadingForeground(),
            _currentEntry.Progress);
    }

    private void ReturnToNormalMode()
    {
        if (!_transparentModeActive) return;

        SaveTransparentProgress();
        SyncMainWindowBoundsFromTransparentWindow();
        if (_transparentWindow is not null)
        {
            _transparentWindow.Hide();
        }
        _transparentModeActive = false;
        _settings.TransparentMode = false;
        _database.SetSetting("TransparentMode", bool.FalseString);
        ShowInTaskbar = true;
        BringWindowToForeground(this, () => Focus());
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() => RestoreProgress(_currentEntry?.Progress ?? 0)));
    }

    private void SyncMainWindowBoundsFromTransparentWindow()
    {
        if (_transparentWindow is null) return;
        WindowState = WindowState.Normal;
        Width = _transparentWindow.Width;
        Height = _transparentWindow.Height;
        Left = _transparentWindow.Left;
        Top = _transparentWindow.Top;
    }

    private Rect GetReaderViewportScreenBounds()
    {
        ReaderBox.UpdateLayout();
        System.Windows.Point topLeft = ReaderBox.PointToScreen(new System.Windows.Point(0, 0));
        System.Windows.Point bottomRight = ReaderBox.PointToScreen(new System.Windows.Point(ReaderBox.ActualWidth, ReaderBox.ActualHeight));
        return new Rect(topLeft, bottomRight);
    }

    private void RestoreProgress(double progress)
    {
        ScrollViewer? scrollViewer = FindVisualChild<ScrollViewer>(ReaderBox);
        if (scrollViewer is null) return;
        double maximum = Math.Max(0, scrollViewer.ExtentHeight - scrollViewer.ViewportHeight);
        scrollViewer.ScrollToVerticalOffset(Math.Clamp(progress, 0, 1) * maximum);
    }

    private double GetCurrentReaderProgress()
    {
        ScrollViewer? scrollViewer = FindVisualChild<ScrollViewer>(ReaderBox);
        if (scrollViewer is null)
        {
            return _currentEntry?.Progress ?? _readingReturnProgress;
        }
        double maximum = Math.Max(0, scrollViewer.ExtentHeight - scrollViewer.ViewportHeight);
        return maximum <= 0 ? 0 : Math.Clamp(scrollViewer.VerticalOffset / maximum, 0, 1);
    }

    private void ReaderScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        double maximum = Math.Max(0, e.ExtentHeight - e.ViewportHeight);
        _syncingReaderScrollBar = true;
        try
        {
            ReaderScrollBar.Maximum = maximum;
            ReaderScrollBar.LargeChange = Math.Max(1, e.ViewportHeight);
            ReaderScrollBar.Value = Math.Clamp(e.VerticalOffset, 0, maximum);
            ReaderScrollBar.Visibility = maximum > 0.5 ? Visibility.Visible : Visibility.Hidden;
        }
        finally
        {
            _syncingReaderScrollBar = false;
        }

        if (_currentEntry is not null)
        {
            _progressTimer.Stop();
            _progressTimer.Start();
        }
    }

    private void ReaderScrollBarValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_syncingReaderScrollBar) return;
        FindVisualChild<ScrollViewer>(ReaderBox)?.ScrollToVerticalOffset(e.NewValue);
    }

    private void SaveCurrentBookToLibrary(PageParseResult page, double progress)
    {
        if (_currentLibraryBook is null) return;

        try
        {
            DateTime now = DateTime.UtcNow;
            _currentLibraryBook.Title = string.IsNullOrWhiteSpace(_currentBookTitle)
                ? _currentLibraryBook.Title
                : _currentBookTitle;
            _currentLibraryBook.ChapterUrl = _currentUrl;
            _currentLibraryBook.ChapterTitle = page.Title;
            _currentLibraryBook.Progress = Math.Clamp(progress, 0, 1);
            _currentLibraryBook.LastReadUtc = now;
            if (_chapterCatalog.Count > 0)
            {
                _currentLibraryBook.CatalogJson = JsonSerializer.Serialize(_chapterCatalog);
            }
            _database.SaveRecentLibraryBook(_currentLibraryBook);
            _currentLibraryBook = _database.GetLibraryBook(_currentLibraryBook.BookKey) ?? _currentLibraryBook;
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"保存书库最近阅读失败：{exception}");
        }
    }

    private void SaveCurrentLibraryProgress(double progress, DateTime lastReadUtc)
    {
        if (_currentLibraryBook is null || string.IsNullOrWhiteSpace(_currentUrl)) return;

        try
        {
            _currentLibraryBook.ChapterUrl = _currentUrl;
            _currentLibraryBook.ChapterTitle = _currentPage?.Title ?? _currentLibraryBook.ChapterTitle;
            _currentLibraryBook.Progress = Math.Clamp(progress, 0, 1);
            _currentLibraryBook.LastReadUtc = lastReadUtc;
            _database.UpdateLibraryReadingPosition(
                _currentLibraryBook.BookKey,
                _currentLibraryBook.ChapterUrl,
                _currentLibraryBook.ChapterTitle,
                _currentLibraryBook.Progress,
                lastReadUtc);
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"保存书库阅读进度失败：{exception}");
        }
    }

    private void SaveCurrentProgress()
    {
        if (_currentEntry is null || string.IsNullOrWhiteSpace(_currentUrl)) return;
        _currentEntry.Progress = GetCurrentReaderProgress();
        _readingReturnProgress = _currentEntry.Progress;
        _currentEntry.LastReadUtc = DateTime.UtcNow;
        if (_currentEntryWritesHistory)
        {
            _database.UpdateProgress(_currentUrl, _currentEntry.Progress);
        }
        SaveCurrentLibraryProgress(_currentEntry.Progress, _currentEntry.LastReadUtc);
    }

    private void SaveActiveProgress()
    {
        if (_transparentModeActive)
        {
            SaveTransparentProgress();
        }
        else
        {
            SaveCurrentProgress();
        }
    }

    private void SaveTransparentProgress()
    {
        if (_currentEntry is null || string.IsNullOrWhiteSpace(_currentUrl) || _transparentWindow is null) return;
        _currentEntry.Progress = _transparentWindow.GetReadingProgress();
        _currentEntry.LastReadUtc = DateTime.UtcNow;
        if (_currentEntryWritesHistory)
        {
            _database.UpdateProgress(_currentUrl, _currentEntry.Progress);
        }
        SaveCurrentLibraryProgress(_currentEntry.Progress, _currentEntry.LastReadUtc);
    }

    private void UpdateHistoryMenu()
    {
        HistoryMenu.IsEnabled = true;
    }

    private async Task OpenHistoryEntryAsync(HistoryEntry entry)
    {
        SaveActiveProgress();
        _activeBookSourceId = BookSourceCatalog.All.Any(source =>
            source.ParserKind == BookSourceParserKind.HttpRules &&
            string.Equals(source.Id, entry.SourceId, StringComparison.OrdinalIgnoreCase))
            ? entry.SourceId
            : string.Empty;
        if (string.IsNullOrWhiteSpace(entry.Content))
        {
            SetStatus("本地正文缓存已过期，正在重新解析…");
            await ParseUrlAsync(
                entry.Url,
                isExpiredHistoryCache: true,
                replaceLibraryContext: true);
            return;
        }

        _currentLibraryBook = null;
        _currentEntry = entry;
        _currentEntryWritesHistory = true;
        _currentUrl = entry.Url;
        _currentBookTitle = ExtractBookTitle(entry.Title);
        if (!string.Equals(_chapterCatalogBookTitle, _currentBookTitle, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(_chapterCatalogSourceId, _activeBookSourceId, StringComparison.OrdinalIgnoreCase))
        {
            ClearChapterCatalog("历史记录未缓存章节目录，请从小说搜索重新进入该书籍。");
        }
        _currentPage = new PageParseResult
        {
            Title = entry.Title,
            Text = entry.Content,
            PreviousUrl = entry.PreviousUrl,
            NextUrl = entry.NextUrl,
            SourceUrl = entry.Url,
            IsContentReady = true
        };
        _settings.LastUrl = entry.Url;
        UrlBox.Text = entry.Url;
        _database.SetSetting("LastUrl", entry.Url);
        _database.UpdateProgress(entry.Url, entry.Progress);
        RenderArticle(_currentPage, entry.Progress);
        SetStatus($"已打开历史记录：{entry.Title}");
    }

    private string BuildDisplayTitle(string chapterTitle)
    {
        string normalizedChapterTitle = chapterTitle.Trim();
        if (string.IsNullOrWhiteSpace(_currentBookTitle) || string.IsNullOrWhiteSpace(normalizedChapterTitle))
        {
            return normalizedChapterTitle;
        }
        if (normalizedChapterTitle.StartsWith(_currentBookTitle, StringComparison.OrdinalIgnoreCase))
        {
            return normalizedChapterTitle;
        }
        return $"{_currentBookTitle}-{normalizedChapterTitle}";
    }

    private static string ExtractBookTitle(string displayTitle)
    {
        int separatorIndex = displayTitle.LastIndexOf("-第", StringComparison.Ordinal);
        return separatorIndex > 0 ? displayTitle[..separatorIndex].Trim() : string.Empty;
    }

    private void ApplyFontSize(double size, bool persist)
    {
        _settings.FontSize = Math.Clamp(size, 8, 48);
        UpdateFontSizeMenuCheck();
        ReaderBox.FontSize = _settings.FontSize;
        if (ReaderBox.Document is not null)
        {
            ReaderBox.Document.FontSize = _settings.FontSize;
        }
        if (persist)
        {
            _database.SetSetting("FontSize", _settings.FontSize.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
    }

    private void ApplyFontFamily(string family, bool persist)
    {
        _settings.FontFamily = string.IsNullOrWhiteSpace(family) ? "Microsoft YaHei UI" : family;
        UpdateFontFamilyMenuCheck();
        ReaderBox.FontFamily = new System.Windows.Media.FontFamily(_settings.FontFamily);
        if (ReaderBox.Document is not null)
        {
            ReaderBox.Document.FontFamily = ReaderBox.FontFamily;
        }
        if (persist)
        {
            _database.SetSetting("FontFamily", _settings.FontFamily);
        }
    }

    private void ApplyAppTheme(string theme, bool persist)
    {
        _settings.AppTheme = theme is "Light" or "Dark" ? theme : "System";
        AppThemeService.Current.SetPreference(_settings.AppTheme);
        UpdateAppThemeMenuCheck();
        ApplyTextColor(_settings.TextColor, persist: false);
        if (persist)
        {
            _database.SetSetting("AppTheme", _settings.AppTheme);
        }
    }

    private void ApplyTextColor(string color, bool persist)
    {
        _settings.TextColor = NormalizeTextColor(color);
        UpdateTextColorMenuCheck();
        System.Windows.Media.Brush foreground = GetReadingForeground();
        ReaderBox.Foreground = foreground;
        if (ReaderBox.Document is not null)
        {
            ReaderBox.Document.Foreground = foreground;
        }
        if (_transparentModeActive && _transparentWindow is not null && _currentEntry is not null)
        {
            _transparentWindow.ShowArticle(_currentEntry, _settings, foreground, _transparentWindow.GetReadingProgress());
        }
        if (persist)
        {
            _database.SetSetting("TextColor", _settings.TextColor);
        }
    }

    private void UpdateFontFamilyMenuCheck()
    {
        SetMenuCheckByTag(FontFamilyMenuItem, _settings.FontFamily);
    }

    private void UpdateFontSizeMenuCheck()
    {
        foreach (object menuObject in FontSizeMenuItem.Items)
        {
            if (menuObject is MenuItem menuItem && double.TryParse(menuItem.Tag?.ToString(), out double size))
            {
                menuItem.IsChecked = Math.Abs(size - _settings.FontSize) < 0.01;
            }
        }
    }

    private void UpdateAppThemeMenuCheck()
    {
        SetMenuCheckByTag(AppThemeMenuItem, _settings.AppTheme);
    }

    private void UpdateTextColorMenuCheck()
    {
        bool hasPreset = false;
        foreach (object menuObject in TextColorMenuItem.Items)
        {
            if (menuObject is MenuItem menuItem && menuItem.Tag is not null)
            {
                menuItem.IsChecked = string.Equals(menuItem.Tag.ToString(), _settings.TextColor, StringComparison.OrdinalIgnoreCase);
                hasPreset |= menuItem.IsChecked;
            }
        }
        CustomTextColorMenuItem.IsChecked = !hasPreset && !string.IsNullOrWhiteSpace(_settings.TextColor);
    }

    private static void SetMenuCheckByTag(MenuItem group, string value)
    {
        foreach (object menuObject in group.Items)
        {
            if (menuObject is MenuItem menuItem)
            {
                menuItem.IsChecked = string.Equals(menuItem.Tag?.ToString(), value, StringComparison.OrdinalIgnoreCase);
            }
        }
    }

    private static void SetExclusiveMenuCheck(MenuItem selected)
    {
        if (selected.Parent is not MenuItem group) return;
        foreach (object menuObject in group.Items)
        {
            if (menuObject is MenuItem menuItem)
            {
                menuItem.IsChecked = ReferenceEquals(menuItem, selected);
            }
        }
    }

    private void ApplyWindowSettings()
    {
        if (_settings.WindowWidth >= MinWidth) Width = _settings.WindowWidth;
        if (_settings.WindowHeight >= MinHeight) Height = _settings.WindowHeight;
        if (!double.IsNaN(_settings.WindowLeft)) Left = _settings.WindowLeft;
        if (!double.IsNaN(_settings.WindowTop)) Top = _settings.WindowTop;
        if (Enum.TryParse(_settings.WindowState, out WindowState state))
        {
            WindowState = state == WindowState.Minimized ? WindowState.Normal : state;
        }
    }

    private void EnsureWindowVisible()
    {
        if (WindowState == WindowState.Minimized)
        {
            WindowState = WindowState.Normal;
        }

        Rect workArea = SystemParameters.WorkArea;
        bool offScreen = double.IsNaN(Left) || double.IsNaN(Top) ||
                         Left + Math.Min(Width, 160) < workArea.Left ||
                         Top + Math.Min(Height, 100) < workArea.Top ||
                         Left > workArea.Right - 32 ||
                         Top > workArea.Bottom - 32;
        if (offScreen)
        {
            Left = workArea.Left + Math.Max(0, (workArea.Width - Width) / 2);
            Top = workArea.Top + Math.Max(0, (workArea.Height - Height) / 2);
        }

        ShowInTaskbar = true;
        if (!IsVisible)
        {
            Show();
        }
        Activate();
    }

    private void SaveWindowSettings()
    {
        if (_transparentModeActive)
        {
            SyncMainWindowBoundsFromTransparentWindow();
        }
        WindowState state = WindowState == WindowState.Minimized ? WindowState.Normal : WindowState;
        if (state == WindowState.Normal)
        {
            _settings.WindowWidth = Width;
            _settings.WindowHeight = Height;
            _settings.WindowLeft = Left;
            _settings.WindowTop = Top;
        }
        _settings.WindowState = state.ToString();
        _settings.LastUrl = _currentUrl.Length > 0 ? _currentUrl : UrlBox.Text.Trim();
        _database.SaveSettings(_settings);
    }

    private void WindowSizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateCompactLayout();
        if (IsLoaded && _startupDisplayReady && WindowState == WindowState.Normal)
        {
            _settings.WindowWidth = Width;
            _settings.WindowHeight = Height;
        }
    }

    private void WindowLocationChanged(object? sender, EventArgs e)
    {
        if (IsLoaded && _startupDisplayReady && WindowState == WindowState.Normal)
        {
            _settings.WindowLeft = Left;
            _settings.WindowTop = Top;
        }
    }

    private void MainWindowStateChanged(object? sender, EventArgs e)
    {
        if (_startupDisplayReady && WindowState == WindowState.Minimized)
        {
            HideToTray();
        }
    }

    private void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (!_allowExit)
        {
            e.Cancel = true;
            SaveActiveProgress();
            SaveWindowSettings();
            HideToTray();
            SetStatus("已隐藏到系统托盘，按 Alt+M、Shift+E 或双击托盘图标恢复。", isError: false);
        }
    }

    private void ExitClick(object sender, RoutedEventArgs e)
    {
        ExitApplication();
    }

    private void ToggleTrayVisibility()
    {
        if (_transparentModeActive)
        {
            if (_transparentWindow?.IsVisible == true)
            {
                HideTransparentToTray();
            }
            else
            {
                RestoreFromTray();
            }
            return;
        }

        if (IsVisible && ShowInTaskbar)
        {
            SaveCurrentProgress();
            SaveWindowSettings();
            HideToTray();
        }
        else
        {
            RestoreFromTray();
        }
    }

    private void HideToTray()
    {
        ShowInTaskbar = false;
        Hide();
    }

    private void RestoreFromTray()
    {
        if (_transparentModeActive && _transparentWindow is not null)
        {
            _transparentWindow.ShowInTaskbar = false;
            BringWindowToForeground(_transparentWindow, _transparentWindow.FocusReader);
            return;
        }

        ShowInTaskbar = true;
        BringWindowToForeground(this, () => Focus());
    }

    private static void BringWindowToForeground(Window window, Action focusAction)
    {
        bool persistentTopmost = window.Topmost;
        if (!window.IsVisible)
        {
            window.Show();
        }

        IntPtr handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero)
        {
            window.Activate();
            focusAction();
            return;
        }

        ShowWindow(handle, window.WindowState == WindowState.Minimized ? SwRestore : SwShow);

        IntPtr foregroundWindow = GetForegroundWindow();
        uint currentThreadId = GetCurrentThreadId();
        uint foregroundThreadId = foregroundWindow == IntPtr.Zero
            ? 0
            : GetWindowThreadProcessId(foregroundWindow, IntPtr.Zero);
        bool inputAttached = false;
        try
        {
            if (foregroundThreadId != 0 && foregroundThreadId != currentThreadId)
            {
                inputAttached = AttachThreadInput(currentThreadId, foregroundThreadId, true);
            }

            window.Topmost = true;
            SetWindowPos(
                handle,
                HwndTopmost,
                0,
                0,
                0,
                0,
                SwpNoMove | SwpNoSize | SwpShowWindow | SwpNoOwnerZOrder);
            BringWindowToTop(handle);
            SetForegroundWindow(handle);
            window.Activate();
            focusAction();
        }
        finally
        {
            if (inputAttached)
            {
                AttachThreadInput(currentThreadId, foregroundThreadId, false);
            }
        }

        DispatcherTimer releaseTimer = new(DispatcherPriority.ApplicationIdle, window.Dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(RestoreForegroundDelayMilliseconds)
        };
        releaseTimer.Tick += (_, _) =>
        {
            releaseTimer.Stop();
            window.Topmost = persistentTopmost;
            if (!window.IsVisible) return;

            IntPtr currentHandle = new WindowInteropHelper(window).Handle;
            if (currentHandle != IntPtr.Zero)
            {
                SetWindowPos(
                    currentHandle,
                    persistentTopmost ? HwndTopmost : HwndNotTopmost,
                    0,
                    0,
                    0,
                    0,
                    SwpNoMove | SwpNoSize | SwpNoActivate | SwpShowWindow | SwpNoOwnerZOrder);
                BringWindowToTop(currentHandle);
                SetForegroundWindow(currentHandle);
            }
            window.Activate();
            focusAction();
        };
        releaseTimer.Start();
    }

    private void HideTransparentToTray()
    {
        if (_transparentWindow is null) return;
        SaveTransparentProgress();
        SyncMainWindowBoundsFromTransparentWindow();
        _transparentWindow.ShowInTaskbar = false;
        _transparentWindow.Hide();
    }

    private void ExitApplication()
    {
        _allowExit = true;
        _aggregatedSearchCancellation?.Cancel();
        _aggregatedSearchCancellation?.Dispose();
        _aggregatedSearchService.Dispose();
        SaveActiveProgress();
        SaveWindowSettings();
        _transparentWindow?.CloseForShutdown();
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _trayMenu?.Dispose();
        _hotKeyService.Dispose();
        System.Windows.Application.Current.Shutdown();
    }

    private System.Windows.Forms.NotifyIcon CreateNotifyIcon()
    {
        System.Windows.Forms.NotifyIcon notifyIcon = new()
        {
            Text = "素若阅读",
            Visible = true,
            Icon = new System.Drawing.Icon(AppPaths.IconPath)
        };
        System.Windows.Forms.ContextMenuStrip menu = new()
        {
            Font = new System.Drawing.Font("Segoe UI", 9F),
            ShowCheckMargin = false,
            ShowImageMargin = false,
            Padding = new System.Windows.Forms.Padding(2)
        };
        menu.Items.Add("显示窗口", null, (_, _) => RestoreFromTray());
        menu.Items.Add("输入网址", null, (_, _) =>
        {
            if (_transparentModeActive)
            {
                ReturnToNormalMode();
            }
            RestoreFromTray();
            ShowInputPanel();
        });
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add("退出程序", null, (_, _) => ExitApplication());
        _trayMenu = menu;
        ApplyTrayMenuTheme();
        notifyIcon.ContextMenuStrip = menu;
        notifyIcon.DoubleClick += (_, _) => RestoreFromTray();
        return notifyIcon;
    }

    private void ApplyTrayMenuTheme()
    {
        if (_trayMenu is null) return;

        System.Drawing.Color background = GetDrawingColor("SurfaceBrush", System.Drawing.Color.FromArgb(43, 43, 43));
        System.Drawing.Color foreground = GetDrawingColor("TextPrimaryBrush", System.Drawing.Color.White);
        System.Drawing.Color selection = GetDrawingColor("AccentSubtleHoverBrush", System.Drawing.Color.FromArgb(48, 75, 100));
        System.Drawing.Color border = GetDrawingColor("AccentBrush", System.Drawing.Color.FromArgb(71, 158, 245));
        System.Drawing.Color separator = GetDrawingColor("BorderBrush", System.Drawing.Color.FromArgb(59, 59, 59));

        _trayMenu.BackColor = background;
        _trayMenu.ForeColor = foreground;
        _trayMenu.Renderer = new TrayMenuThemeRenderer(background, selection, border, separator);
        foreach (System.Windows.Forms.ToolStripItem item in _trayMenu.Items)
        {
            item.BackColor = background;
            item.ForeColor = foreground;
        }
        _trayMenu.Invalidate();
    }

    private System.Drawing.Color GetDrawingColor(string resourceKey, System.Drawing.Color fallback)
    {
        if (TryFindResource(resourceKey) is not System.Windows.Media.SolidColorBrush brush) return fallback;
        System.Windows.Media.Color color = brush.Color;
        return System.Drawing.Color.FromArgb(color.A, color.R, color.G, color.B);
    }

    private void SetStatus(string message, bool isError = false)
    {
        StatusText.Text = message;
        StatusText.Foreground = GetResourceBrush(isError ? "ErrorBrush" : "TextSecondaryBrush");
    }

    private void UpdateLoadingIndicator()
    {
        if (_isLoading)
        {
            LoadingIndicator.Visibility = Visibility.Visible;
            DoubleAnimation rotation = new(0, 360, TimeSpan.FromMilliseconds(900))
            {
                RepeatBehavior = RepeatBehavior.Forever
            };
            LoadingSpinnerRotation.BeginAnimation(RotateTransform.AngleProperty, rotation);
        }
        else
        {
            LoadingSpinnerRotation.BeginAnimation(RotateTransform.AngleProperty, null);
            LoadingIndicator.Visibility = Visibility.Collapsed;
        }
        UpdateReturnToReadingButton();
    }

    private void RunViewTransition()
    {
        ViewTransitionOverlay.Opacity = 0.34;
        if (ViewTransitionOverlay.RenderTransform is TranslateTransform transform)
        {
            transform.X = 10;
            transform.BeginAnimation(TranslateTransform.XProperty,
                new DoubleAnimation(0, TimeSpan.FromMilliseconds(240))
                {
                    EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
                });
        }
        ViewTransitionOverlay.BeginAnimation(OpacityProperty,
            new DoubleAnimation(0, TimeSpan.FromMilliseconds(240))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            });
    }

    private void SearchResultItemLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is not ListBoxItem item) return;
        int index = SearchResultsList.ItemContainerGenerator.IndexFromContainer(item);
        AnimateListItem(item, index);
    }

    internal static void AnimateListItem(FrameworkElement item, int index)
    {
        TranslateTransform transform = new(0, 8);
        item.RenderTransform = transform;
        item.Opacity = 0;
        TimeSpan delay = TimeSpan.FromMilliseconds(Math.Clamp(index, 0, 10) * 40);
        CubicEase easing = new() { EasingMode = EasingMode.EaseOut };
        item.BeginAnimation(OpacityProperty,
            new DoubleAnimation(1, TimeSpan.FromMilliseconds(240)) { BeginTime = delay, EasingFunction = easing });
        transform.BeginAnimation(TranslateTransform.YProperty,
            new DoubleAnimation(0, TimeSpan.FromMilliseconds(240)) { BeginTime = delay, EasingFunction = easing });
    }

    private void UpdateCompactLayout()
    {
        StatusRegion.Visibility = ActualHeight > 150 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static bool IsHttpUrl(string value)
        => Uri.TryCreate(value, UriKind.Absolute, out Uri? uri) &&
           (uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
            uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase));

    private static System.Windows.Media.Brush BrushFromHex(string value)
        => new BrushConverter().ConvertFromString(value) as System.Windows.Media.Brush ?? System.Windows.Media.Brushes.Transparent;

    private System.Windows.Media.Brush GetResourceBrush(string key)
        => TryFindResource(key) as System.Windows.Media.Brush ?? System.Windows.Media.Brushes.Transparent;

    private System.Windows.Media.Brush GetReadingForeground()
        => string.IsNullOrWhiteSpace(_settings.TextColor) ? GetResourceBrush("ReaderForegroundBrush") : BrushFromHex(_settings.TextColor);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr windowHandle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr windowHandle, int command);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(
        IntPtr windowHandle,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr windowHandle, IntPtr processId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachThreadInput(uint attachThreadId, uint attachToThreadId, bool attach);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BringWindowToTop(IntPtr windowHandle);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    private void AppThemeChanged(object? sender, EventArgs e)
    {
        ApplySearchScopeAccent();
        ApplyTextColor(_settings.TextColor, persist: false);
        ApplyTrayMenuTheme();
    }

    private static string NormalizeTextColor(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return string.Empty;
        if (new BrushConverter().ConvertFromString(value) is System.Windows.Media.SolidColorBrush brush)
        {
            return $"#{brush.Color.R:X2}{brush.Color.G:X2}{brush.Color.B:X2}";
        }
        return string.Empty;
    }

    private static T? FindVisualChild<T>(DependencyObject? parent) where T : DependencyObject
    {
        if (parent is null) return null;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(parent, index);
            if (child is T result) return result;
            T? descendant = FindVisualChild<T>(child);
            if (descendant is not null) return descendant;
        }
        return null;
    }
}
