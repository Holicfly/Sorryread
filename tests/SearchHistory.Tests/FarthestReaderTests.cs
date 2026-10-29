using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using ReadAI;
using ReadAI.Sync;

internal static partial class Program
{
    private static void PumpReader()
    {
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer(DispatcherPriority.ContextIdle) { Interval = TimeSpan.FromMilliseconds(160) };
        timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
        timer.Start(); Dispatcher.PushFrame(frame);
    }

    private static void TestFarthestReader(string directory)
    {
        using var database = new ReaderDatabase(Path.Combine(directory, "farthest-reader.db"));
        database.Initialize();
        var window = (MainWindow)Activator.CreateInstance(typeof(MainWindow), PrivateInstance, null, [database, false], null)!;
        try
        {
            var source = BookSourceCatalog.Aggregated.First(s => s.ParserKind == BookSourceParserKind.HttpRules);
            var chapters = Enumerable.Range(0, 10).Select(i => new NovelChapterItem {
                Title = $"第{i + 1}章", Url = $"https://example.invalid/farthest/chapter/{i}" }).ToList();
            var book = new LibraryBookEntry { SourceId = source.Id, SourceName = source.Name,
                Title = "合成最远进度测试", DetailUrl = "https://example.invalid/farthest/book",
                ChapterUrl = chapters[3].Url, ChapterTitle = chapters[3].Title, Progress = .31,
                LastReadUtc = DateTime.UtcNow, CatalogJson = JsonSerializer.Serialize(chapters) };
            book.BookKey = LibraryBookEntry.CreateBookKey(book.SourceId, book.DetailUrl);
            database.SaveRecentLibraryBook(book);
            var page = new PageParseResult { Title = book.ChapterTitle, SourceUrl = book.ChapterUrl,
                Text = string.Join("\n\n", Enumerable.Repeat("用于验证同步后阅读界面跟随最远位置的合成段落。", 300)), IsContentReady = true };
            SetField(window, "_currentLibraryBook", book);
            SetField(window, "_currentUrl", book.ChapterUrl);
            SetField(window, "_currentPage", page);
            SetField(window, "_currentEntry", new HistoryEntry { Url = book.ChapterUrl, Title = book.Title, Content = page.Text, Progress = .31 });
            Field<List<NovelChapterItem>>(window, "_chapterCatalog").AddRange(chapters);
            Invoke(window, "RenderArticle", page, .31);
            var root = (Grid)window.Content;
            root.Measure(new Size(640, 480)); root.Arrange(new Rect(0, 0, 640, 480)); root.UpdateLayout();
            PumpReader();
            string phone = Guid.NewGuid().ToString("N");
            var payload = new SyncPayload { Kind = "book", SourceId = book.SourceId, SourceName = book.SourceName,
                Title = book.Title, DetailUrl = book.DetailUrl, ChapterUrl = book.ChapterUrl, ChapterTitle = book.ChapterTitle,
                ChapterIndex = 3, ChapterCount = 10, BookProgressChapterUrl = book.ChapterUrl, Progress = .4,
                UpdatedUtc = DateTime.UtcNow.AddDays(-1).ToString("O") };
            var change = new SyncChange(SyncProtocol.BookId(book.BookKey), "position", phone, "1", new() { [phone] = "1" }, payload);
            string before = database.GetLocalSyncSequence();
            var document = ((RichTextBox)window.FindName("ReaderBox")).Document;
            database.ApplySyncChanges(phone, [change]); PumpReader();
            Check(Field<HistoryEntry>(window, "_currentEntry").Progress == .4, "active desktop follows older-timestamp but farther phone position");
            Check(ReferenceEquals(((RichTextBox)window.FindName("ReaderBox")).Document, document), "same-chapter sync keeps the reading document");
            Check(database.GetLocalSyncSequence() == before, "remote reader restore creates no local echo operation");
            database.UpdateLibraryReadingPosition(book.BookKey, book.ChapterUrl, book.ChapterTitle, .1, DateTime.UtcNow);
            Check(database.GetLibraryBook(book.BookKey)!.Progress == .4, "desktop reread cannot lower persisted farthest position");
            database.ApplySyncChanges(phone, [change]); PumpReader();
            Check(database.GetLocalSyncSequence() == before, "duplicate remote state and local backtrack generate no echo");
            database.SaveHistory(new HistoryEntry { Url = chapters[4].Url, Title = chapters[4].Title, Content = page.Text,
                CreatedUtc = DateTime.UtcNow, LastReadUtc = DateTime.UtcNow, LastParsedUtc = DateTime.UtcNow });
            database.ApplySyncChanges(phone, [change with { Seq = "2", Clock = new() { [phone] = "2" },
                Payload = payload with { ChapterUrl = chapters[4].Url, ChapterTitle = chapters[4].Title,
                    ChapterIndex = 4, BookProgressChapterUrl = chapters[4].Url, Progress = .05 } }]);
            PumpReader(); root.UpdateLayout(); PumpReader();
            Check(Field<string>(window, "_currentUrl") == chapters[4].Url, "active desktop follows remote advance into a different cached chapter");
            Check(database.GetLibraryBook(book.BookKey)!.ChapterUrl == chapters[4].Url, "persisted desktop chapter stays at the farthest point");
        }
        finally
        {
            SetField(window, "_allowExit", true); window.Close();
            ((IDisposable)Field<object>(window, "_notifyIcon")).Dispose();
            ((IDisposable)Field<object>(window, "_hotKeyService")).Dispose();
            ((IDisposable)Field<object>(window, "_aggregatedSearchService")).Dispose();
        }
    }
}
