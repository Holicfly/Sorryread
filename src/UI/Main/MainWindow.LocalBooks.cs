using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using ReadAI.Sync;
using Image = System.Windows.Controls.Image;
using KeyEvent = System.Windows.Input.Key;

namespace ReadAI;

public partial class MainWindow
{
    private bool _localBookOpening, _localIllustrated, _restoringComicPage;
    private LocalBookState? _comicBook;
    private int _comicPage;

    private void LocalBookRemoved(object? sender, string sha) => Dispatcher.BeginInvoke(new Action(() =>
    {
        if (_currentLibraryBook?.BookKey != LocalBook.BookKey(sha)) return;
        _progressTimer.Stop();
        _currentLibraryBook = null;
        _currentEntry = null;
        _currentPage = null;
        _currentUrl = "";
        ResetLocalReader();
        ClearChapterCatalog("图书已移出。");
        if (_transparentModeActive) ReturnToNormalMode();
        if (_viewNavigation.Current == ReaderView.Reader) ShowInputPanel();
        SetStatus("当前本地图书已移出。");
    }));

    private async Task<bool> OpenLocalBookAsync(LibraryBookEntry book, int? requestedIndex = null)
    {
        if (_localBookOpening || !book.DetailUrl.StartsWith(LocalBook.UrlPrefix, StringComparison.Ordinal)) return false;
        string sha = book.DetailUrl[LocalBook.UrlPrefix.Length..];
        var record = _database.GetLocalBook(sha);
        if (record is not { HasFile: true })
        {
            SetStatus("原文件尚未就绪，可等待设备同步或选择同一份文件导入。", isError: true);
            return false;
        }
        _localBookOpening = true;
        _isLoading = true;
        UpdateLoadingIndicator();
        try
        {
            var state = record.State;
            var catalog = JsonSerializer.Deserialize<List<NovelChapterItem>>(book.CatalogJson) ?? [];
            int index = requestedIndex ?? state.Position?.Index ?? 0;
            if (index < 0 || index >= catalog.Count || catalog.Count != state.UnitCount)
                throw new InvalidDataException("目录尚未就绪，请重新导入原文件。");
            double progress = state.Position?.Index == index ? state.Position.Progress : 0;
            if (state.Comic && _comicBook?.Sha256 == sha && ReaderBox.Visibility == Visibility.Visible)
            {
                SetComicPosition(index);
                RestoreComicPage();
                _progressTimer.Stop();
                SaveCurrentProgress();
                return true;
            }
            var blocks = state.Comic ? [] : await Task.Run(() => LocalComicPageControl.ReadBlocks(_database, state, index));
            if (_allowExit || _database.GetLocalBook(sha) is not { HasFile: true }) return false;
            bool illustrated = state.Comic || blocks.Any(block => block.HasImage);
            if (illustrated && _transparentModeActive) ReturnToNormalMode();
            else SaveActiveProgress();
            _progressTimer.Stop();
            UpdateDesktopReading();
            ResetLocalReader();
            _activeBookSourceId = "";
            _currentBookTitle = book.Title;
            _currentLibraryBook = book;
            _currentEntryWritesHistory = false;
            SetChapterCatalog(book.Title, catalog, "暂无目录。");
            var page = BuildLocalPage(sha, index, catalog.Count, catalog[index].Title,
                string.Join("\n\n", blocks.Where(block => block.Text.Length > 0).Select(block => block.Text)));
            SetLocalPage(page, progress);
            _localIllustrated = illustrated;
            if (state.Comic)
            {
                _comicBook = state;
                _comicPage = index;
                ComicPages.ItemsSource = Enumerable.Range(0, catalog.Count)
                    .Select(number => new ComicPageSource(_database, state, number)).ToArray();
                ComicPages.Visibility = Visibility.Visible;
                ReaderBox.IsHitTestVisible = false;
                ReaderBox.Opacity = 0;
                _restoringComicPage = true;
            }
            RenderArticleDocument(page, progress, BuildLocalDocument(blocks));
            if (!_applyingRemotePosition) SaveCurrentBookToLibrary(page, progress);
            SetStatus($"本地书 · {book.Title} · {page.Title}");
            RefreshTransparentReaderContent();
            return true;
        }
        catch (Exception error) when (LocalComicPageControl.IsImageError(error) ||
            error is Microsoft.Data.Sqlite.SqliteException or JsonException)
        {
            SetStatus($"打开本地书失败：{error.Message}", isError: true);
            return false;
        }
        finally
        {
            _localBookOpening = _isLoading = false;
            UpdateLoadingIndicator();
            UpdateReturnToReadingButton();
            UpdateDesktopReading();
        }
    }

    private FlowDocument BuildLocalDocument(List<LocalComicPageControl.RenderedBlock> blocks)
    {
        FlowDocument Create(string text) => ArticleDocumentFactory.Create(text, _settings.FontFamily,
            _settings.FontSize, GetReadingForeground(), plainText: true);
        if (blocks.Count == 1 && !blocks[0].HasImage) return Create(blocks[0].Text);
        var document = Create("");
        document.Blocks.Clear();
        foreach (var block in blocks)
        {
            if (block.Image is { } bitmap)
            {
                var image = new Image { Source = bitmap, Stretch = Stretch.Uniform, MaxWidth = 1180 };
                document.Blocks.Add(new BlockUIContainer(image) { Margin = new Thickness(0, 8, 0, 8) });
                continue;
            }
            var text = Create(block.HasImage ? "〔图片无法读取〕" : block.Text);
            while (text.Blocks.FirstBlock is { } paragraph)
            {
                text.Blocks.Remove(paragraph);
                document.Blocks.Add(paragraph);
            }
        }
        return document;
    }

    private static PageParseResult BuildLocalPage(string sha, int index, int count, string title, string text = "") => new()
    {
        Title = title,
        Text = text,
        IsContentReady = true,
        SourceUrl = LocalBook.UnitUrl(sha, index),
        PreviousUrl = index > 0 ? LocalBook.UnitUrl(sha, index - 1) : "",
        NextUrl = index + 1 < count ? LocalBook.UnitUrl(sha, index + 1) : ""
    };

    private void SetLocalPage(PageParseResult page, double progress)
    {
        _currentPage = page;
        _currentUrl = page.SourceUrl;
        DateTime now = DateTime.UtcNow;
        _currentEntry = new HistoryEntry
        {
            Url = _currentUrl, Title = BuildDisplayTitle(page.Title), Content = page.Text,
            PreviousUrl = page.PreviousUrl, NextUrl = page.NextUrl, Progress = progress,
            CreatedUtc = now, LastReadUtc = now, LastParsedUtc = now, SourceId = LocalBook.SourceId
        };
    }

    private async Task<bool> OpenLocalUrlAsync(string url)
    {
        if (_currentLibraryBook is { SourceId: LocalBook.SourceId } book &&
            book.DetailUrl.StartsWith(LocalBook.UrlPrefix, StringComparison.Ordinal) &&
            LocalBook.UnitIndex(url, book.DetailUrl[LocalBook.UrlPrefix.Length..]) is int index)
            return await OpenLocalBookAsync(book, index);
        SetStatus("请从导入页或书库打开本地书。", isError: true);
        return false;
    }

    private void ResetLocalReader()
    {
        _comicBook = null;
        _localIllustrated = _restoringComicPage = false;
        ComicPages.Visibility = Visibility.Collapsed;
        ComicPages.ItemsSource = null;
        ReaderBox.IsHitTestVisible = true;
        ReaderBox.Opacity = 1;
    }

    private void RestoreComicPage()
    {
        if (_comicBook is null || !ComicPages.IsVisible || _comicPage >= ComicPages.Items.Count) return;
        _restoringComicPage = true;
        object item = ComicPages.Items[_comicPage];
        ComicPages.ScrollIntoView(item);
        ComicPages.UpdateLayout();
        var viewport = FindVisualChild<ScrollContentPresenter>(ComicPages);
        var viewer = FindVisualChild<ScrollViewer>(ComicPages);
        if (viewport is not null && viewer is not null &&
            ComicPages.ItemContainerGenerator.ContainerFromItem(item) is ListBoxItem container)
        {
            double top = container.TransformToAncestor(viewport).Transform(new System.Windows.Point()).Y;
            viewer.ScrollToVerticalOffset(viewer.VerticalOffset + top);
        }
        Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(() => _restoringComicPage = false));
    }

    private void ComicScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (_comicBook is null || _restoringComicPage || !ComicPages.IsVisible || e.VerticalChange == 0) return;
        var panel = FindVisualChild<VirtualizingStackPanel>(ComicPages);
        var viewport = FindVisualChild<ScrollContentPresenter>(ComicPages);
        if (panel is null || viewport is null) return;
        double nearest = double.NegativeInfinity;
        int page = _comicPage;
        int lastVisible = -1;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(panel); i++)
        {
            if (VisualTreeHelper.GetChild(panel, i) is not ListBoxItem item || item.Content is not ComicPageSource source)
                continue;
            double top = item.TransformToAncestor(viewport).Transform(new System.Windows.Point()).Y;
            if (top >= viewport.ActualHeight || top + item.ActualHeight <= 0) continue;
            lastVisible = Math.Max(lastVisible, source.Index);
            // Use the page at the top of the viewport; use the first visible page if a gap crosses the top.
            double rank = top <= 0 ? top : -viewport.ActualHeight - top;
            if (rank <= nearest) continue;
            nearest = rank;
            page = source.Index;
        }
        if (lastVisible == _comicBook.UnitCount - 1 &&
            e.VerticalOffset >= e.ExtentHeight - e.ViewportHeight - 1)
            page = lastVisible;
        if (page == _comicPage) return;
        SetComicPosition(page);
        _progressTimer.Stop();
        _progressTimer.Start();
    }

    private void SetComicPosition(int index)
    {
        var comic = _comicBook!;
        if (_comicPage == index) return;
        _comicPage = index;
        SetLocalPage(BuildLocalPage(comic.Sha256, index, comic.UnitCount, _chapterCatalog[index].Title), 0);
        UpdateCurrentChapterHighlight();
        UpdateStatusNavigationButtons();
        UpdateDesktopReading();
        SetStatus($"本地书 · {comic.Title} · 第 {index + 1} / {comic.UnitCount} 页");
    }

    private bool HandleComicKey(KeyEvent key)
    {
        if (FindVisualChild<ScrollViewer>(ComicPages) is not { } viewer) return false;
        switch (key)
        {
            case KeyEvent.Up: viewer.ScrollToVerticalOffset(viewer.VerticalOffset - 48); return true;
            case KeyEvent.Down: viewer.ScrollToVerticalOffset(viewer.VerticalOffset + 48); return true;
            case KeyEvent.PageUp: viewer.PageUp(); return true;
            case KeyEvent.PageDown: viewer.PageDown(); return true;
            case KeyEvent.Home: viewer.ScrollToTop(); return true;
            case KeyEvent.End: viewer.ScrollToBottom(); return true;
            default: return false;
        }
    }
}
