using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Threading;

namespace ReadAI;

public partial class MainWindow
{
    private LibraryScope _libraryScope = LibraryScope.Normal;
    private int _libraryScopeClickCount;
    private long _libraryScopeClickStart;
    private LibraryBookEntry? _homePreviewBook;
    private bool _homePreviewRestorePending;
    private double _homePreviewProgress;
    private bool _homePreviewHasBody;
    private (string BookKey, string ChapterUrl)? _homePreviewAttempt;
    private CancellationTokenSource? _homePreviewLoad;
    private string LibraryScopeName => _libraryScope == LibraryScope.Normal ? "普通" : "特殊";

    private void LibraryTitleMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        long now = Environment.TickCount64;
        if (_libraryScopeClickCount == 0 || now - _libraryScopeClickStart > 3000)
        {
            _libraryScopeClickStart = now;
            _libraryScopeClickCount = 0;
        }
        if (++_libraryScopeClickCount < 5) return;
        _libraryScopeClickCount = 0;
        _libraryScope = _libraryScope == LibraryScope.Normal ? LibraryScope.Legacy18Mh : LibraryScope.Normal;
        RefreshLibraryPanel();
        SetStatus($"已切换为{LibraryScopeName}书库。");
    }

    private void HomePanelSizeChanged(object sender, SizeChangedEventArgs e) => UpdateHomeLayout();
    // Search history collapses before its parent viewport finishes shrinking.
    // Re-evaluate the preview against the final viewport height as well.
    private void HomeFormViewportSizeChanged(object sender, SizeChangedEventArgs e) => UpdateHomePreviewVisibility();
    private void HomeInputSizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateHomeFormHeight();
        UpdateHomePreviewVisibility();
    }
    private void HomePreviewReaderSizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateHomePreviewFade();
        QueueHomePreviewPosition();
    }

    private void UpdateHomePreviewFade()
    {
        double height = HomePreviewReader.ActualHeight;
        if (height <= 0) return;
        double topFade = Math.Min(12, height * .1);
        double bottomFade = Math.Min(height * .65, Math.Max(72, HomePreviewReader.Document.LineHeight * 3));
        HomePreviewTopOpaque.Offset = topFade / height;
        HomePreviewBottomOpaque.Offset = Math.Max(HomePreviewTopOpaque.Offset, 1 - bottomFade / height);
    }

    private void UpdateHomeLayout()
    {
        if (HomePanel is null || InputModeBorder is null || HomePreviewButton is null) return;
        double width = HomePanel.ActualWidth > 0 ? HomePanel.ActualWidth : Math.Max(0, ActualWidth - 48);
        bool narrow = width < 480;
        Grid.SetColumnSpan(InputModeBorder, narrow ? 3 : 1);
        InputModeBorder.Margin = new Thickness(0, 0, 0, narrow ? 8 : 0);
        InputFieldRow.Height = narrow ? GridLength.Auto : new GridLength(0);
        Grid.SetRow(UrlBox, narrow ? 1 : 0);
        Grid.SetColumn(UrlBox, narrow ? 0 : 1);
        Grid.SetColumnSpan(UrlBox, narrow ? 2 : 1);
        UrlBox.Margin = new Thickness(narrow ? 0 : 8, 0, 8, 0);
        Grid.SetRow(ParseButton, narrow ? 1 : 0);
        UpdateHomeFormHeight();
        UpdateHomePreviewVisibility();
        if (OpenLibraryButton is not null) UpdateLibraryActions();
    }

    private void UpdateHomeFormHeight()
    {
        if (HomeInputRow is null || HomeScrollViewer is null) return;
        // Keep the form's measured space during page/theme switches, including a ScrollViewer remeasure.
        double available = SearchInputLayout.ActualHeight;
        double formHeight = InputPanel.ActualHeight;
        double formSpace = available >= 80 ? available - 44 : available;
        HomeInputRow.Height = available > 0 && formHeight > 0
            ? new GridLength(Math.Min(formSpace, formHeight)) : GridLength.Auto;
    }

    private void RefreshHomePreview()
    {
        if (HomePreviewButton is null) return;
        if (_searchModeActive || InputPanel.Visibility != Visibility.Visible)
        {
            HomePreviewButton.Visibility = Visibility.Collapsed;
            return;
        }
        try
        {
            var recent = _database.GetRecentLibraryBooks(scope: _libraryScope);
            LibraryBookEntry? latest = recent.FirstOrDefault();
            if (latest is null)
            {
                _homePreviewBook = null;
                UpdateHomeLayout();
                return;
            }
            LibraryBookEntry book = latest;
            PageParseResult? page = GetExactHomePreview(latest);
            if (page is null)
            {
                page = _database.GetLatestLibraryChapterCache(latest.BookKey);
                foreach (LibraryBookEntry other in recent.Skip(1))
                {
                    if (page is not null) break;
                    page = GetExactHomePreview(other) ?? _database.GetLatestLibraryChapterCache(other.BookKey);
                    if (page is not null) book = other;
                }
                LoadLatestHomePreview(latest);
            }
            bool previousChapter = page is not null && IsHttpUrl(page.SourceUrl) &&
                !string.Equals(page.SourceUrl, book.ChapterUrl, StringComparison.Ordinal);
            _homePreviewBook = book;
            _homePreviewHasBody = page is not null;
            _homePreviewProgress = previousChapter ? 0 : book.Progress;
            HomePreviewTitle.Text = book.Title;
            HomePreviewChapter.Text = previousChapter
                ? page!.Title
                : string.IsNullOrWhiteSpace(book.ChapterTitle) ? page?.Title ?? "" : book.ChapterTitle;
            HomePreviewProgress.Text = previousChapter ? "" : $"本章 {book.Progress:P0}";
            if (page is not null)
            {
                HomePreviewReader.Document = ArticleDocumentFactory.Create(page.Text, _settings.FontFamily,
                    _settings.FontSize, GetReadingForeground());
                HomePreviewReader.Document.PagePadding = new Thickness(0);
                HomePreviewReader.Document.LineHeight = _settings.FontSize * 1.55;
                foreach (Paragraph paragraph in HomePreviewReader.Document.Blocks.OfType<Paragraph>())
                {
                    paragraph.LineHeight = HomePreviewReader.Document.LineHeight;
                    paragraph.Margin = new Thickness(0, 0, 0, _settings.FontSize * .55);
                }
            }
            UpdateHomePreviewFade();
            UpdateHomeLayout();
            QueueHomePreviewPosition();
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"读取首页最近阅读预览失败：{exception}");
        }
    }

    private PageParseResult? GetExactHomePreview(LibraryBookEntry book)
    {
        var page = _database.GetLibraryChapterCache(book);
        if (page is not null || !IsHttpUrl(book.ChapterUrl)) return page;
        if (_currentLibraryBook?.BookKey == book.BookKey &&
            _currentPage is { IsContentReady: true } &&
            !string.IsNullOrWhiteSpace(_currentPage.Text) &&
            string.Equals(_currentUrl, book.ChapterUrl, StringComparison.Ordinal))
            return _currentPage;
        var cached = _database.GetHistoryByUrl(book.ChapterUrl);
        return cached is not null && !string.IsNullOrWhiteSpace(cached.Content)
            ? new PageParseResult { Title = cached.Title, Text = cached.Content, SourceUrl = book.ChapterUrl, IsContentReady = true }
            : null;
    }

    private async void LoadLatestHomePreview(LibraryBookEntry book)
    {
        var target = (book.BookKey, book.ChapterUrl);
        if (!IsLoaded || _homePreviewAttempt == target ||
            BookSourceCatalog.FindByBookUrl(book.ChapterUrl) is not { ParserKind: BookSourceParserKind.HttpRules } source ||
            source.Id != book.SourceId || !source.IsSearchable)
            return;
        _homePreviewAttempt = target;
        _homePreviewLoad?.Cancel();
        using var load = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        _homePreviewLoad = load;
        try
        {
            var page = await _bookSourceParser.ParseChapterAsync(source, book.ChapterUrl, [], load.Token);
            if (!load.IsCancellationRequested && !_allowExit &&
                _database.GetRecentLibraryBooks(1, _libraryScope).FirstOrDefault() is { } latest &&
                (latest.BookKey, latest.ChapterUrl) == target &&
                GetExactHomePreview(latest) is null)
                _database.SaveLibraryChapterCache(book.BookKey, book.ChapterUrl, page);
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"首页预览正文暂不可用：{exception.Message}");
        }
        finally
        {
            if (ReferenceEquals(_homePreviewLoad, load)) _homePreviewLoad = null;
        }
    }

    private void HomePreviewCacheChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (!_allowExit && InputPanel.Visibility == Visibility.Visible) RefreshHomePreview();
        }));

    private double HomePreviewTitleHeight()
    {
        HomePreviewTitle.Measure(new System.Windows.Size(double.PositiveInfinity, double.PositiveInfinity));
        return Math.Max(HomePreviewTitle.DesiredSize.Height, Math.Ceiling(HomePreviewTitle.FontSize * 1.3));
    }

    private void UpdateHomePreviewVisibility()
    {
        if (HomePreviewButton is null) return;
        double space = HomePanel.ActualHeight - HomeScrollViewer.ActualHeight;
        double titleHeight = HomePreviewTitleHeight();
        bool showDetails = space >= titleHeight + 28;
        bool showLabel = space >= titleHeight + 58;
        bool useFullSpacing = space >= titleHeight + 110;
        HomePreviewButton.Margin = useFullSpacing ? new Thickness(0, 18, 0, 4) : new Thickness(0);
        HomePreviewButton.Padding = new Thickness(12, useFullSpacing ? 8 : 0, 12, 0);
        HomePreviewLabel.Visibility = showLabel ? Visibility.Visible : Visibility.Collapsed;
        HomePreviewChapter.Visibility = HomePreviewProgress.Visibility = showDetails ? Visibility.Visible : Visibility.Collapsed;
        HomePreviewBody.Visibility = _homePreviewHasBody && space >= titleHeight + 76
            ? Visibility.Visible : Visibility.Collapsed;
        HomePreviewButton.Visibility = _homePreviewBook is not null && !_searchModeActive && space >= titleHeight
            ? Visibility.Visible : Visibility.Collapsed;
        if (HomePreviewButton.Visibility == Visibility.Visible) QueueHomePreviewPosition();
    }

    private void QueueHomePreviewPosition()
    {
        if (_homePreviewRestorePending) return;
        _homePreviewRestorePending = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            _homePreviewRestorePending = false;
            if (_homePreviewBook is not null && HomePreviewButton.Visibility == Visibility.Visible &&
                InputPanel.Visibility == Visibility.Visible && HomePreviewBody.Visibility == Visibility.Visible)
            {
                HomePreviewReader.ApplyTemplate();
                ScrollViewer? viewer = FindVisualChild<ScrollViewer>(HomePreviewReader);
                if (viewer is null) return;
                // Preview text must fill the fade area, including a partial last line.
                // Keep the real reader's whole-line alignment out of this decorative viewport.
                viewer.ClearValue(HeightProperty);
                viewer.VerticalAlignment = VerticalAlignment.Stretch;
                HomePreviewReader.UpdateLayout();
                viewer.ScrollToVerticalOffset(Math.Max(0, viewer.ScrollableHeight) * _homePreviewProgress);
            }
        }));
    }

    private async void HomePreviewClick(object sender, RoutedEventArgs e)
    {
        if (_homePreviewBook is not null && !_isLoading)
            await OpenLibraryBookAsync(_homePreviewBook);
    }
}
