using System.IO;
using ReadAI;
using ReadAI.Sync;

internal static class LibraryScopeProbe
{
    public static void Run(string root)
    {
        string path = Path.Combine(root, "mobile-special-library.db");
        string phone = Guid.NewGuid().ToString("N");
        (string Source, string Url, bool Special)[] books =
        [
            ("18mh", "https://18mh.net/novel/detail/1", true),
            ("yeshe", "https://yeshezy1.com/artdetail/2.html", true),
            ("old18", "https://www.18mh.net/novel/detail/3", true),
            ("oldyeshe", "https://yeshezy1.com/artdetail/4.html", true),
            ("xbiqugu", "https://example.invalid/book/5", false),
            ("normal", "https://18mh.net.example.invalid/book/6", false),
            ("normal", "https://example.invalid/book/7?next=https://yeshezy1.com/", false),
            (" YESHE ", "https://example.invalid/book/8", true)
        ];
        List<SyncChange> changes = [];
        foreach (var (source, url, _) in books)
        {
            // These are the same book metadata/groups emitted by DiscoverBook.toShelfBook
            // and the mobile SyncRepository. Preserve the original sync identity.
            foreach (string group in new[] { "favorite", "recent", "position" })
            {
                string seq = (changes.Count + 1).ToString();
                changes.Add(new SyncChange(SyncProtocol.BookId(LibraryBookEntry.CreateBookKey(source, url)),
                    group, phone, seq, new() { [phone] = seq }, new SyncPayload
                    {
                        SourceId = source, SourceName = source == "yeshe" ? "夜社" : source,
                        DetailUrl = url, Title = "手机同步归类测试", Active = true,
                        ChapterUrl = group == "position" ? url + "/chapter" : "",
                        ChapterTitle = group == "position" ? "已阅读章节" : "",
                        Progress = group == "position" ? .4 : 0,
                        UpdatedUtc = DateTime.UtcNow.ToString("O")
                    }));
            }
        }
        using (ReaderDatabase desktop = new(path))
        {
            desktop.Initialize();
            desktop.ApplySyncChanges(phone, changes);
            desktop.ApplySyncChanges(phone, changes);
            AssertGroups(desktop, books);
            if (desktop.GetLocalSyncSequence() != "0") throw new Exception("Library grouping created a sync echo.");
        }
        using (ReaderDatabase reopened = new(path))
        {
            reopened.Initialize();
            AssertGroups(reopened, books);
            using ReaderDatabase restored = new(Path.Combine(root, "mobile-special-snapshot.db"));
            restored.Initialize();
            restored.ApplyClientSnapshot(phone, changes.Count.ToString(), reopened.GetSyncSnapshot().Records);
            AssertGroups(restored, books);
        }
        Console.WriteLine("PASS mobile special bookshelf: 18mh/yeshe, legacy URL fallback, ordinary-source isolation, delta/snapshot/restart and no echo");
    }

    private static void AssertGroups(ReaderDatabase db, (string Source, string Url, bool Special)[] books)
    {
        foreach (LibraryScope scope in new[] { LibraryScope.Normal, LibraryScope.Legacy18Mh })
        {
            var expected = books.Where(b => b.Special == (scope == LibraryScope.Legacy18Mh))
                .Select(b => LibraryBookEntry.CreateBookKey(b.Source, b.Url)).ToHashSet();
            var recent = db.GetRecentLibraryBooks(scope: scope);
            var favorites = db.GetFavoriteLibraryBooks(scope: scope);
            if (!expected.SetEquals(recent.Select(b => b.BookKey)) || !expected.SetEquals(favorites.Select(b => b.BookKey)))
                throw new Exception($"Phone favorite/recent books were grouped incorrectly: {scope}");
            if (recent.Any(b => b.Progress != .4)) throw new Exception("Library grouping changed reading progress.");
        }
        foreach (var book in books)
            if (db.GetLibraryBook(LibraryBookEntry.CreateBookKey(book.Source, book.Url))?.SourceId != book.Source)
                throw new Exception("Grouping rewrote a source ID or sync entity key.");
    }
}
