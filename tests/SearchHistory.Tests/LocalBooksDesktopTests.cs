using System.IO;
using System.IO.Compression;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ReadAI;
using ReadAI.Sync;

internal static partial class Program
{
    private static void TestLocalBooksDesktop(string directory)
    {
        string root = Path.Combine(directory, "local-books");
        Directory.CreateDirectory(root);
        using var database = new ReaderDatabase(Path.Combine(root, "desktop.db"));
        database.Initialize();
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        string txt = Path.Combine(root, "两章小说.txt");
        File.WriteAllText(txt, "第一章 开场\r\n保留 <p> 原文。\r\n第二章 续读\r\n这是第二章正文。", Encoding.GetEncoding(54936));
        var text = LocalBookImporter.ImportAsync(database, txt).GetAwaiter().GetResult().Book;
        Check(text.State.UnitCount == 2 && database.GetLocalBookBlocks(text.State.Sha256, 0).Single().Text == "保留 <p> 原文。",
            "GB18030 input keeps literal angle brackets and chapter boundaries");
        string unicode = Path.Combine(root, "UTF16.txt");
        File.WriteAllText(unicode, "前言内容\n第一章 续读\n正文 😀", Encoding.BigEndianUnicode);
        var unicodeBook = LocalBook.Parse(unicode, "txt", "UTF16");
        Check(unicodeBook.Units[0].Title == "前言" && unicodeBook.Units[1].Blocks[0].Text.EndsWith("😀"),
            "UTF-16 BOM, preface and Unicode scalar decode");

        string epub = Path.Combine(root, "漫画.epub");
        string mixedEpub = Path.Combine(root, "图文.epub");
        MakeEpub(epub, comic: true);
        MakeEpub(mixedEpub, comic: false);
        var comic = LocalBookImporter.ImportAsync(database, epub).GetAwaiter().GetResult().Book;
        var mixed = LocalBookImporter.ImportAsync(database, mixedEpub).GetAwaiter().GetResult().Book;
        Check(comic.State.Comic && comic.State.UnitCount == 3 && comic.State.Title == "漫画样例",
            "EPUB 3 fixed-layout and image sequence includes the text-only opening page");
        Check(database.GetLocalBookBlocks(comic.State.Sha256, 1).Single().ImagePath == "OPS/Images/图 1.png" &&
            database.GetLocalBookBlocks(comic.State.Sha256, 2).Single().ImagePath == "OPS/Images/图 2.png",
            "EPUB relative percent-encoded image paths and SVG wrapper preserve page order");
        var mixedBlocks = database.GetLocalBookBlocks(mixed.State.Sha256, 0);
        Check(!mixed.State.Comic && mixedBlocks.Count == 3 && mixedBlocks[0].Text.Contains("图前") &&
            mixedBlocks[1].ImagePath is not null && mixedBlocks[2].Text.Contains("图后"), "EPUB 2 retains mixed content order");
        Check(database.GetLibraryBook(LocalBook.BookKey(mixed.State.Sha256))!.CatalogJson.Contains(
            "EPUB2 TOC"), "EPUB2 NCX supplies title");

        var window = (MainWindow)Activator.CreateInstance(typeof(MainWindow), PrivateInstance, null, [database, false], null)!;
        window.Width = 680; window.Height = 510;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = window.Top = -10000;
        window.ShowInTaskbar = window.ShowActivated = false;
        try
        {
            window.Show();
            var mainMenu = (Menu)window.FindName("MainMenu");
            Check(mainMenu.Items.OfType<MenuItem>().Select(item => item.Header.ToString())
                .SequenceEqual(["解析", "设置", "导入", "帮助"]), "Import sits between settings and help");
            var importMenu = (MenuItem)window.FindName("ImportBooksMenuItem");
            importMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            var import = (ImportBooksControl)window.FindName("ImportBooksPanel");
            Check(import.IsVisible && ((ListBox)import.FindName("BooksList")).Items.Count == 3,
                "Import opens in main content with all installed books");
            foreach (string theme in new[] { "Dark", "Light" })
            {
                System.Windows.Application.Current.Resources.MergedDictionaries[0] = Theme(theme);
                PumpReader();
                window.UpdateLayout();
                var cards = Descendants<LibraryBookCard>(import).ToList();
                Check(cards.Count == 3 && cards.All(card => card.CanDelete), $"{theme} import shares the collection card removal affordance");
                var bitmap = new RenderTargetBitmap((int)import.ActualWidth, (int)import.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(import);
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var image = File.Create(Path.Combine(directory, $"import-books-{theme.ToLowerInvariant()}.png"));
                encoder.Save(image);
            }
            int windows = System.Windows.Application.Current.Windows.Count;
            window.Height = 180;
            ((MenuItem)window.FindName("DeviceLinkMenuItem")).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            window.UpdateLayout();
            PumpReader();
            Check(!import.IsVisible && ((ContentControl)window.FindName("DeviceLinkPanelHost")).Content is DeviceLinkControl { IsVisible: true },
                "Device link replaces import in the main content area");
            Check(System.Windows.Application.Current.Windows.Count == windows, "Device link creates no second window");
            Check(window.Height > 180 && window.Width == 680, "Compact window expands enough for device link without widening");
            Invoke(window, "NavigateBack");
            Check(import.IsVisible, "Device link returns to the previous import page");
            Invoke(window, "NavigateBack");
            Check(window.Height == 180 && window.Width == 680, "Leaving the utility pages restores the prior size");
            window.Height = 510;
            importMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));

            var textEntry = database.GetLibraryBook(LocalBook.BookKey(text.State.Sha256))!;
            WaitForLocalBook(window, () => (Task)Invoke(window, "OpenLibraryBookAsync", textEntry)!);
            var reader = (RichTextBox)window.FindName("ReaderBox");
            Check(new TextRange(reader.Document.ContentStart, reader.Document.ContentEnd).Text.Contains("<p> 原文"),
                "TXT rendered as literal text");
            WaitForLocalBook(window, () => (Task)Invoke(window, "NavigateChapterAsync", true)!);
            Check(Field<string>(window, "_currentUrl") == LocalBook.UnitUrl(text.State.Sha256, 1), "Local next chapter uses local reader");
            Invoke(window, "NavigateBack");
            Check(import.IsVisible, "Local reader returns to import");

            var comicEntry = database.GetLibraryBook(LocalBook.BookKey(comic.State.Sha256))!;
            WaitForLocalBook(window, () => (Task)Invoke(window, "OpenLibraryBookAsync", comicEntry)!);
            var pages = (ListBox)window.FindName("ComicPages");
            PumpReader();
            Check(pages.IsVisible && pages.Items.Count == 3 &&
                Descendants<System.Windows.Controls.Image>(pages).Any(image => image.Source is BitmapSource),
                "EPUB comic renders images in a continuous vertical list");
            WaitForLocalBook(window, () => (Task)Invoke(window, "NavigateChapterAsync", true)!);
            Check(database.GetLocalBook(comic.State.Sha256)!.State.Position?.Index == 1,
                "Comic page advance is saved as the shared page index");
            Invoke(window, "NavigateBack");
            WaitForLocalBook(window, () => (Task)Invoke(window, "OpenLibraryBookAsync", comicEntry)!);
            Check(Field<string>(window, "_currentUrl") == LocalBook.UnitUrl(comic.State.Sha256, 1),
                "Reopening comic restores the saved page");
            Invoke(database, "ApplyLocalBookState", comic.State.Sha256,
                comic.State with { Position = new LocalBookPosition(2, 0) });
            PumpReader();
            Check(Field<string>(window, "_currentUrl") == LocalBook.UnitUrl(comic.State.Sha256, 2),
                "Active comic reader follows a newer synchronized page");
            var illustrated = database.GetLibraryBook(LocalBook.BookKey(mixed.State.Sha256))!;
            WaitForLocalBook(window, () => (Task)Invoke(window, "OpenLibraryBookAsync", illustrated)!);
            Check(reader.Document.Blocks.OfType<BlockUIContainer>().Single().Child is System.Windows.Controls.Image { Source: BitmapSource },
                "Mixed EPUB renders an inline image between text blocks");
        }
        finally
        {
            SetField(window, "_allowExit", true); window.Close();
            ((IDisposable)Field<object>(window, "_notifyIcon")).Dispose();
            ((IDisposable)Field<object>(window, "_hotKeyService")).Dispose();
            ((IDisposable)Field<object>(window, "_aggregatedSearchService")).Dispose();
        }
    }

    private static void WaitForLocalBook(MainWindow window, Func<Task> action)
    {
        Task task = window.Dispatcher.InvokeAsync(action).Task.Unwrap();
        for (int i = 0; !task.IsCompleted && i < 25; i++) PumpReader();
        if (!task.IsCompleted) throw new TimeoutException("Local book operation did not complete");
        task.GetAwaiter().GetResult();
        PumpReader();
    }

    private static void MakeEpub(string path, bool comic)
    {
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        void Add(string name, string value)
        {
            using var stream = new StreamWriter(zip.CreateEntry(name).Open(), new UTF8Encoding(false));
            stream.Write(value);
        }
        Add("META-INF/container.xml", "<container><rootfiles><rootfile full-path='OPS/book.opf'/></rootfiles></container>");
        Add("OPS/book.opf", $"""
            <package xmlns:dc="http://purl.org/dc/elements/1.1/">
              <metadata><dc:title>{(comic ? "漫画样例" : "图文样例")}</dc:title>
                {(comic ? "<meta property='rendition:layout'>pre-paginated</meta>" : "")}
              </metadata>
              <manifest>
                <item id="start" href="Text/start.xhtml" media-type="application/xhtml+xml"/>
                <item id="p1" href="Text/p1.xhtml" media-type="application/xhtml+xml"/>
                <item id="p2" href="Text/p2.svg" media-type="image/svg+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
              </manifest>
              <spine toc="ncx"><itemref idref="start"/>{(comic ? "<itemref idref='p1'/><itemref idref='p2'/>" : "")}</spine>
            </package>
            """);
        Add("OPS/Text/start.xhtml", comic ? "<body><p>漫画版权页。</p></body>" :
            "<body><p>图前文字。</p><img src='../Images/%E5%9B%BE%201.png'/><p>图后文字。</p></body>");
        Add("OPS/Text/p1.xhtml", "<body><img src='../Images/%E5%9B%BE%201.png'/></body>");
        Add("OPS/Text/p2.svg", "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'><image xlink:href='../Images/图%202.png'/></svg>");
        Add("OPS/nav.xhtml", "<nav epub:type='toc'><a href='Text/p1.xhtml'>漫画第一页</a></nav>");
        Add("OPS/toc.ncx", "<ncx><navMap><navPoint><navLabel><text>EPUB2 TOC</text></navLabel><content src='Text/start.xhtml'/></navPoint></navMap></ncx>");
        foreach (int index in new[] { 1, 2 })
        {
            byte[] pixels = Enumerable.Repeat((byte)(index * 100), 200 * 420).ToArray();
            var frame = BitmapSource.Create(200, 420, 96, 96, PixelFormats.Gray8, null, pixels, 200);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(frame));
            using var buffer = new MemoryStream();
            encoder.Save(buffer);
            buffer.Position = 0;
            using var output = zip.CreateEntry($"OPS/Images/图 {index}.png").Open();
            buffer.CopyTo(output);
        }
    }
}
