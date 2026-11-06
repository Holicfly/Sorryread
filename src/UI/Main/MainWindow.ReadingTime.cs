using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using ReadAI.Sync;

namespace ReadAI;

public partial class MainWindow
{
    private static readonly TimeSpan ReadingCheckpointInterval = TimeSpan.FromSeconds(30);
    private DispatcherTimer? _readingTimer;
    private (DesktopReadingEntry Chapter, DateTime StartUtc, long StartTick)? _readingSegment;

    private void InitializeDesktopReading()
    {
        _readingTimer = new DispatcherTimer { Interval = ReadingCheckpointInterval };
        _readingTimer.Tick += (_, _) => UpdateDesktopReading();
        Activated += (_, _) => UpdateDesktopReading();
        Deactivated += (_, _) => UpdateDesktopReading();
        IsVisibleChanged += (_, _) => UpdateDesktopReading();
        ReaderBox.IsVisibleChanged += (_, _) => UpdateDesktopReading();
        Closed += (_, _) => StopDesktopReading();
    }

    private void ObserveTransparentReading(Window window)
    {
        if (_readingTimer is null) return;
        window.Activated += (_, _) => UpdateDesktopReading();
        window.Deactivated += (_, _) => UpdateDesktopReading();
        window.IsVisibleChanged += (_, _) => UpdateDesktopReading();
    }

    private DesktopReadingEntry? CurrentReadingChapter()
    {
        if (_currentLibraryBook is not { } book || book.SourceId == LocalBook.SourceId || _currentEntry is null ||
            string.IsNullOrWhiteSpace(book.Title) || string.IsNullOrWhiteSpace(_currentUrl)) return null;

        int index = _chapterCatalog.FindIndex(chapter => AreSameChapterUrl(chapter.Url, _currentUrl));
        double progress = _transparentModeActive && _transparentWindow?.IsVisible == true
            ? _transparentWindow.GetReadingProgress()
            : ReaderBox.IsVisible ? GetCurrentReaderProgress() : _currentEntry.Progress;
        return new DesktopReadingEntry(
            0, "", SyncProtocol.BookId(book.BookKey), book.Title, book.SourceId, book.DetailUrl,
            _currentUrl, _currentPage?.Title ?? _currentEntry.Title,
            index < 0 ? null : index, index < 0 ? null : _chapterCatalog.Count,
            Math.Clamp(progress, 0, 1), "", 0);
    }

    private void UpdateDesktopReading()
    {
        if (_readingTimer is null) return;
        var chapter = CurrentReadingChapter();
        DateTime wall = DateTime.UtcNow;
        long tick = Stopwatch.GetTimestamp();
        SaveDesktopReadingSegment(chapter, tick);
        bool visibleReader = _transparentModeActive
            ? _transparentWindow is { IsVisible: true, IsActive: true, WindowState: not WindowState.Minimized }
            : IsActive && WindowState != WindowState.Minimized && ReaderBox.IsVisible && !SearchOverlay.IsOpen;
        if (chapter != null && visibleReader && !_isLoading && !_applyingRemotePosition && !_allowExit)
        {
            _readingSegment = (chapter, wall, tick);
            if (!_readingTimer.IsEnabled) _readingTimer.Start();
        }
        else
        {
            _readingTimer.Stop();
        }
    }

    private void SaveDesktopReadingSegment(DesktopReadingEntry? current, long tick)
    {
        if (_readingSegment is not { } segment) return;
        _readingSegment = null;
        var elapsed = Stopwatch.GetElapsedTime(segment.StartTick, tick);
        // A suspended computer cannot contribute the time between timer ticks.
        if (elapsed > ReadingCheckpointInterval + TimeSpan.FromSeconds(15)) return;
        var chapter = segment.Chapter;
        if (current?.BookId == chapter.BookId && current.ChapterUrl == chapter.ChapterUrl)
            chapter = current;
        try
        {
            _database.RecordDesktopReading(chapter, segment.StartUtc, (long)elapsed.TotalMilliseconds);
        }
        catch (Exception exception)
        {
            Debug.WriteLine($"保存电脑阅读时长失败：{exception}");
        }
    }

    private void StopDesktopReading()
    {
        if (_readingTimer is null) return;
        _readingTimer.Stop();
        SaveDesktopReadingSegment(CurrentReadingChapter(), Stopwatch.GetTimestamp());
        _readingTimer = null;
    }
}
