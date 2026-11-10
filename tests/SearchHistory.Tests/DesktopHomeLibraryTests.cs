using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ReadAI;

internal static partial class Program
{
    private static void TestDesktopHomeAndLibrary(string directory)
    {
        using ReaderDatabase database = new(Path.Combine(directory, "desktop-home-library.db"));
        database.Initialize();
        string normalSource = BookSourceCatalog.Aggregated.First(s => s.ParserKind == BookSourceParserKind.HttpRules).Id;
        LibraryBookEntry MakeBook(string sourceId, int i) => new()
        {
            SourceId = sourceId, SourceName = sourceId == "18mh" ? "18mh 小说网" : "普通书源 · 阅读测试",
            BookKey = LibraryBookEntry.CreateBookKey(sourceId, $"https://example.invalid/{sourceId}/book/{i}"),
            DetailUrl = $"https://example.invalid/{sourceId}/book/{i}",
            ChapterUrl = $"https://example.invalid/{sourceId}/chapter/{i}",
            ChapterTitle = $"第 {i + 1} 章 · 山间来信",
            Title = i == 0 ? "山间来信与一个很长很长的书名，用于检查卡片的文字显示范围" : $"阅读测试书籍 {i + 1}",
            Progress = .42, LastReadUtc = DateTime.UtcNow.AddMinutes(-i),
            FavoriteUtc = i < 3 ? DateTime.UtcNow.AddMinutes(-i) : null
        };
        foreach (string sourceId in new[] { normalSource, "18mh" })
            for (int i = 0; i < 12; i++) database.SaveRecentLibraryBook(MakeBook(sourceId, i));
        LibraryBookEntry normalBook = MakeBook(normalSource, 0);
        LibraryBookEntry specialBook = MakeBook("18mh", 0);
        var normalRecent = database.GetRecentLibraryBooks(scope: LibraryScope.Normal);
        var specialRecent = database.GetRecentLibraryBooks(scope: LibraryScope.Legacy18Mh);
        Check(normalRecent.Count == 10 && normalRecent.All(b => b.SourceId != "18mh"), "normal library has its own ten recent books");
        Check(specialRecent.Count == 10 && specialRecent.All(b => b.SourceId == "18mh"), "18mh library has its own ten recent books");
        Check(database.GetFavoriteLibraryBooks(scope: LibraryScope.Normal).Count == 3 &&
            database.GetFavoriteLibraryBooks(scope: LibraryScope.Legacy18Mh).Count == 3,
            "existing favorites are classified without changing their timestamps or progress");
        database.DeleteRecentLibraryBook(normalRecent[5].BookKey);
        Check(database.GetRecentLibraryBooks(scope: LibraryScope.Legacy18Mh).Count == 10 &&
            database.GetLibraryBook(normalBook.BookKey)!.Progress == .42,
            "removing one normal recent book preserves special recents and saved positions");

        string body = string.Join("\n\n", Enumerable.Range(1, 90).Select(i =>
            $"清晨的风穿过山谷，窗前的纸页轻轻翻动。第{i}段里，他把远方寄来的信收进口袋，沿着石阶走向仍未散去的薄雾。"));
        PageParseResult normalPage = new() { Title = normalBook.ChapterTitle, Text = body, IsContentReady = true };
        PageParseResult specialPage = new() { Title = specialBook.ChapterTitle, Text = "特殊分区缓存正文。\n\n" + body, IsContentReady = true };
        database.SaveLibraryChapterCache(normalBook.BookKey, normalBook.ChapterUrl, normalPage);
        database.SaveLibraryChapterCache(specialBook.BookKey, specialBook.ChapterUrl, specialPage);
        Check(database.GetHistoryCount() == 0 && database.GetLibraryChapterCache(normalBook)!.Text == body,
            "chapter preview cache does not create URL parsing records");
        using (ReaderDatabase reopened = new(Path.Combine(directory, "desktop-home-library.db")))
        {
            reopened.Initialize();
            Check(reopened.GetLibraryChapterCache(normalBook)?.Text == body, "preview cache survives restarting the database");
        }
        LibraryBookEntry differentChapter = MakeBook(normalSource, 0);
        differentChapter.ChapterUrl += "/different";
        Check(database.GetLibraryChapterCache(differentChapter) is null, "a different chapter never receives stale preview text");
        for (int i = 0; i < 3; i++)
            database.SaveHistory(new HistoryEntry
            {
                Url = $"https://example.invalid/article/{i}/a-long-url-for-parsing-record-layout",
                Title = $"解析示例 {i + 1}：很长的网址也可以完整复制", Content = body,
                CreatedUtc = DateTime.UtcNow.AddDays(-4), LastReadUtc = DateTime.UtcNow,
                LastParsedUtc = DateTime.UtcNow.AddMinutes(-i), ParseCount = i + 2,
                SourceId = i == 0 ? "18mh" : normalSource
            });
        Check(database.GetRecentHistory(500, includeContent: false).All(e => e.Content.Length == 0) &&
            database.GetHistoryByUrl(database.GetRecentHistory(1, false)[0].Url)!.Content == body,
            "record list loads metadata while opening still retrieves the full cached article");

        MainWindow window = (MainWindow)Activator.CreateInstance(typeof(MainWindow), PrivateInstance, null, [database, false], null)!;
        try
        {
            var navigation = Field<ReaderNavigation>(window, "_viewNavigation");
            var preview = (Button)window.FindName("HomePreviewButton");
            var previewReader = (RichTextBox)window.FindName("HomePreviewReader");
            var input = (TextBox)window.FindName("UrlBox");
            var parse = (Button)window.FindName("ParseButton");
            var recent = (ListBox)window.FindName("RecentLibraryList");
            var favorites = (ListBox)window.FindName("FavoriteLibraryList");
            var records = (ParseRecordsControl)window.FindName("ParseRecordsPanel");
            var recordsButton = (Button)window.FindName("OpenParseRecordsButton");
            Invoke(window, "ShowInputPanel");
            LayoutDesktop(window, 340, 500);
            Check(Field<LibraryScope>(window, "_libraryScope") == LibraryScope.Normal && preview.Visibility == Visibility.Visible,
                "new desktop windows default to a normal-library preview");
            Check(input.ActualWidth > 200 && Grid.GetRow(input) == 1 && Grid.GetRow(parse) == 1,
                "narrow home gives the input over 200 pixels on a separate row");
            Check(new TextRange(previewReader.Document.ContentStart, previewReader.Document.ContentEnd).Text.Contains("清晨的风") &&
                !new TextRange(previewReader.Document.ContentStart, previewReader.Document.ContentEnd).Text.Contains("特殊分区"),
                "normal home preview never shows the most recent special book");
            Check(!Descendants<Button>(preview).Any() && recordsButton.Visibility == Visibility.Visible,
                "preview has no nested continue-reading button and URL home exposes parsing records");
            RenderDesktop(window, directory, "desktop-home-narrow-dark", 340, 500);
            RenderDesktop(window, directory, "desktop-home-compact-dark", 340, 370);
            TestHomePreviewBottomFade(window);
            for (int i = 0; i < 15; i++)
                database.AddSearchHistory(SearchHistoryModes.Aggregated, $"用于验证切换后布局恢复的搜索记录 {i}");
            foreach (int homeWidth in new[] { 340, 760 })
            {
                LayoutDesktop(window, homeWidth, 370);
                for (int cycle = 0; cycle < 3; cycle++)
                {
                    ((RadioButton)window.FindName("SearchModeSelector")).IsChecked = true;
                    ((Grid)window.Content).UpdateLayout();
                    PumpReader();
                    Check(preview.Visibility == Visibility.Collapsed, "novel search hides the URL-home reading preview");
                    ((RadioButton)window.FindName("ParseModeSelector")).IsChecked = true;
                    ((Grid)window.Content).UpdateLayout();
                    PumpReader();
                    Check(preview.Visibility == Visibility.Visible && Field<LibraryBookEntry?>(window, "_homePreviewBook")?.BookKey == normalBook.BookKey,
                        $"{homeWidth}px: switching back from search history restores the normal preview without resizing");
                }
            }
            LayoutDesktop(window, 760, 500);
            Check(Grid.GetRow(input) == 0 && input.ActualWidth > 300, "wide home restores a single spacious input row");
            RenderDesktop(window, directory, "desktop-home-wide-dark", 760, 500);
            LayoutDesktop(window, 340, 180);
            Check(preview.Visibility == Visibility.Visible &&
                ((Grid)window.FindName("HomePreviewBody")).Visibility == Visibility.Collapsed,
                "short windows keep the preview title without growing the window");
            var homeScroll = (ScrollViewer)window.FindName("HomeScrollViewer");
            homeScroll.ScrollToBottom();
            ((Grid)window.Content).UpdateLayout();
            double formBottom = homeScroll.TranslatePoint(new Point(0, homeScroll.ActualHeight), (Grid)window.Content).Y;
            var homeActions = (StackPanel)window.FindName("LibraryActionsButtons");
            double actionsTop = homeActions.TranslatePoint(new Point(), (Grid)window.Content).Y;
            Check(formBottom <= actionsTop && homeScroll.ClipToBounds,
                "compact input scrolls within its area and never overlaps the bottom library/record buttons");
            LayoutDesktop(window, 340, 500);
            Click(preview);
            Check(navigation.Current == ReaderView.Reader && Field<string>(window, "_currentUrl") == normalBook.ChapterUrl &&
                Math.Abs(Field<HistoryEntry>(window, "_currentEntry").Progress - .42) < .001,
                "clicking the preview resumes its saved chapter and position offline without a catalog");

            Invoke(window, "ShowLibraryPanel");
            LayoutDesktop(window, 340, 500);
            Check(recent.Items.Count == 10 && favorites.Items.Count == 3, "normal bookshelf binds independent lists and counts");
            LibraryBookCard card = Descendants<LibraryBookCard>(recent).First();
            Button open = (Button)card.FindName("OpenButton");
            Grid cardText = (Grid)card.FindName("CardText");
            Check(cardText.ActualWidth >= card.ActualWidth - 25 && open.Padding.Right == 10,
                "book title and source use the card width instead of reserving an empty delete column");
            Invoke(card, "SetDeleteHover", true);
            PumpReader();
            for (int i = 0; i < 5 && ((GradientStop)card.FindName("TextFadeEnd")).Color.A > 4; i++) PumpReader();
            Check(((MarqueeTextBlock)card.FindName("TitleText")).IsPaused &&
                ((MarqueeTextBlock)card.FindName("SourceText")).IsPaused &&
                ((Button)card.FindName("DeleteButton")).Opacity > .95,
                "right-side hover fades in delete and pauses both overflowing text lines");
            Check(((GradientStop)card.FindName("TextFadeEnd")).Color.A < 5,
                "the rightmost text fades out under the delete overlay");
            RenderDesktop(window, directory, "desktop-library-hover-dark", 340, 500);
            Invoke(card, "SetDeleteHover", false);
            PumpReader();
            for (int i = 0; i < 5 && ((GradientStop)card.FindName("TextFadeEnd")).Color.A < 251; i++) PumpReader();
            Check(!((MarqueeTextBlock)card.FindName("TitleText")).IsPaused &&
                ((Button)card.FindName("DeleteButton")).Opacity < .05 &&
                ((GradientStop)card.FindName("TextFadeEnd")).Color.A > 250,
                "leaving the right edge restores text opacity and resumes scrolling");

            var searchScope = Field<SearchInputScope>(window, "_searchInputScope");
            for (int i = 0; i < 4; i++) ClickLibraryTitle(window);
            Check(Field<LibraryScope>(window, "_libraryScope") == LibraryScope.Normal, "four title clicks do not switch libraries");
            ClickLibraryTitle(window);
            Check(Field<LibraryScope>(window, "_libraryScope") == LibraryScope.Legacy18Mh &&
                recent.Items.Cast<LibraryBookEntry>().All(b => b.SourceId == "18mh") && favorites.Items.Count == 3 &&
                Field<SearchInputScope>(window, "_searchInputScope") == searchScope,
                "five title clicks switch both lists without changing novel search mode");
            Click((Button)window.FindName("HomeButton"));
            LayoutDesktop(window, 340, 500);
            Check(new TextRange(previewReader.Document.ContentStart, previewReader.Document.ContentEnd).Text.Contains("特殊分区"),
                "home preview follows the selected special bookshelf");
            ((RadioButton)window.FindName("SearchModeSelector")).IsChecked = true;
            ((Grid)window.Content).UpdateLayout();
            PumpReader();
            ((RadioButton)window.FindName("ParseModeSelector")).IsChecked = true;
            ((Grid)window.Content).UpdateLayout();
            PumpReader();
            Check(preview.Visibility == Visibility.Visible && Field<LibraryBookEntry?>(window, "_homePreviewBook")?.BookKey == specialBook.BookKey,
                "switching home input modes restores the selected special preview without leaking a normal book");
            Invoke(window, "ShowLibraryPanel");
            SetField(window, "_libraryScopeClickCount", 4);
            SetField(window, "_libraryScopeClickStart", Environment.TickCount64 - 4000);
            ClickLibraryTitle(window);
            Check(Field<LibraryScope>(window, "_libraryScope") == LibraryScope.Legacy18Mh,
                "a click after the three-second deadline resets the hidden switch sequence");
            for (int i = 0; i < 4; i++) ClickLibraryTitle(window);
            Check(Field<LibraryScope>(window, "_libraryScope") == LibraryScope.Normal, "another five clicks return to the normal library");

            Click((Button)window.FindName("HomeButton"));
            LayoutDesktop(window, 340, 500);
            double widthBefore = window.Width, heightBefore = window.Height;
            Click(recordsButton);
            LayoutDesktop(window, 340, 500);
            Check(navigation.Current == ReaderView.ParseRecords && records.Visibility == Visibility.Visible &&
                ((ListBox)records.FindName("HistoryList")).Items.Count == 3,
                "parsing records replace the home content and include normal and special-source URL records");
            Check(window.Width == widthBefore && window.Height == heightBefore && window.MinWidth == 360 && window.MinHeight == 130,
                "opening parsing records preserves window dimensions and minimum limits");
            Check(((Menu)window.FindName("MainMenu")).Items.Cast<MenuItem>().All(item =>
                item.Header.ToString() is not "历史记录" and not "解析记录"), "old top history menu is removed");
            Check(Descendants<TextBlock>(records).Any(t => t.Text.StartsWith("首次解析：")) &&
                Descendants<TextBlock>(records).Any(t => t.Text.StartsWith("上次解析：")) &&
                Descendants<TextBlock>(records).Any(t => t.Text == "2 次"),
                "embedded records retain both timestamps, URLs, and parse counts");
            RenderDesktop(window, directory, "desktop-records-narrow-dark", 340, 500);
            RenderDesktop(window, directory, "desktop-records-compact-dark", 340, 370);
            RenderDesktop(window, directory, "desktop-records-wide-dark", 760, 500);
            Click((Button)window.FindName("ReturnToReadingButton"));
            Check(navigation.Current == ReaderView.Home && records.Visibility == Visibility.Collapsed,
                "embedded records return to the originating home page");
            Invoke(window, "SetStatus", "用于验证状态栏完整提示的一条很长的消息，不能因为窗口变窄而丢失。", false);
            var status = (TextBlock)window.FindName("StatusText");
            var tooltip = (ToolTip)status.ToolTip;
            tooltip.PlacementTarget = status;
            tooltip.ApplyTemplate();
            tooltip.Measure(new Size(420, double.PositiveInfinity));
            tooltip.Arrange(new Rect(new Point(), tooltip.DesiredSize));
            tooltip.UpdateLayout();
            PumpReader();
            Check(tooltip.Content is TextBlock { TextWrapping: TextWrapping.Wrap } tipText && tipText.Text == status.Text,
                "status tooltip binding contains the entire untruncated message and wraps it");

            foreach (string theme in new[] { "Light", "Dark" })
            {
                Application.Current.Resources.MergedDictionaries[0] = Theme(theme);
                Invoke(window, "ShowInputPanel");
                RenderDesktop(window, directory, $"desktop-home-narrow-{theme.ToLowerInvariant()}", 340, 500);
                double previewTop = preview.TranslatePoint(new Point(), (Grid)window.Content).Y;
                double inputBottom = input.TranslatePoint(new Point(0, input.ActualHeight), (Grid)window.Content).Y;
                Check(preview.Visibility == Visibility.Visible && previewTop > inputBottom,
                    $"{theme} theme: returning from records keeps preview below the complete input form");
            }
            LibraryBookEntry uncachedLatest = MakeBook(normalSource, 99);
            uncachedLatest.LastReadUtc = DateTime.UtcNow.AddHours(1);
            database.SaveRecentLibraryBook(uncachedLatest);
            Invoke(window, "RefreshHomePreview");
            Check(preview.Visibility == Visibility.Visible && Field<LibraryBookEntry?>(window, "_homePreviewBook")?.BookKey == normalBook.BookKey,
                "a latest book with no body keeps the next recent preview with a cache");
            database.SaveLibraryChapterCache(uncachedLatest.BookKey, uncachedLatest.ChapterUrl,
                new PageParseResult { Title = "最新章节", Text = "最新章节正文", IsContentReady = true });
            PumpReader();
            Check(Field<LibraryBookEntry?>(window, "_homePreviewBook")?.BookKey == uncachedLatest.BookKey,
                "saving the new chapter cache refreshes the preview without reopening home");
            var advanced = database.GetLibraryBook(uncachedLatest.BookKey)!;
            advanced.ChapterUrl = uncachedLatest.ChapterUrl + "?next=1";
            advanced.ChapterTitle = "已同步的新章节";
            database.SaveRecentLibraryBook(advanced);
            Invoke(window, "RefreshHomePreview");
            Check(((TextBlock)window.FindName("HomePreviewChapter")).Text == "最新章节",
                "previous cache keeps its own chapter title while synced chapter has no body");
            foreach (LibraryBookEntry book in database.GetRecentLibraryBooks(scope: LibraryScope.Normal))
                database.DeleteRecentLibraryBook(book.BookKey);
            foreach (LibraryBookEntry book in database.GetRecentLibraryBooks(scope: LibraryScope.Normal))
                database.DeleteRecentLibraryBook(book.BookKey);
            Invoke(window, "RefreshHomePreview");
            Check(preview.Visibility == Visibility.Collapsed && database.GetRecentLibraryBooks(scope: LibraryScope.Legacy18Mh).Count == 10,
                "an empty normal library hides preview while retaining the special library");
            Console.WriteLine($"Desktop previews: {directory}");
        }
        finally
        {
            SetField(window, "_allowExit", true);
            window.Close();
            ((IDisposable)Field<object>(window, "_notifyIcon")).Dispose();
            ((IDisposable)Field<object>(window, "_hotKeyService")).Dispose();
            ((IDisposable)Field<object>(window, "_aggregatedSearchService")).Dispose();
        }
    }

    private static void ClickLibraryTitle(MainWindow window)
        => ((TextBlock)window.FindName("LibraryTitleText")).RaiseEvent(
            new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left)
            { RoutedEvent = UIElement.MouseLeftButtonDownEvent });

    private static void TestHomePreviewBottomFade(MainWindow window)
    {
        var root = (Grid)window.Content;
        var reader = (RichTextBox)window.FindName("HomePreviewReader");
        var body = (Grid)window.FindName("HomePreviewBody");
        var status = (FrameworkElement)window.FindName("StatusRegion");
        double gap = status.TranslatePoint(new Point(), root).Y
            - reader.TranslatePoint(new Point(0, reader.ActualHeight), root).Y;
        Check(gap >= 4 && gap <= 12, "preview fades to within a small gap of the status bar instead of leaving a blank footer band");
        ScrollViewer viewer = Descendants<ScrollViewer>(reader).First();
        Check(double.IsNaN(viewer.Height) && Math.Abs(viewer.ActualHeight - reader.ActualHeight) < 1,
            "preview viewport fills the fade area without a whole-line height cutoff");

        int width = (int)Math.Ceiling(root.ActualWidth), height = (int)Math.Ceiling(root.ActualHeight);
        byte[] ReadPixels()
        {
            RenderTargetBitmap bitmap = new(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(root);
            byte[] pixels = new byte[width * height * 4];
            bitmap.CopyPixels(pixels, width * 4, 0);
            return pixels;
        }
        byte[] faded = ReadPixels();
        Brush mask = body.OpacityMask;
        body.OpacityMask = null;
        byte[] plain;
        try { plain = ReadPixels(); }
        finally { body.OpacityMask = mask; }
        long fadedInk = 0, plainInk = 0;
        Point origin = body.TranslatePoint(new Point(), root);
        int bottom = Math.Min(height, (int)Math.Floor(origin.Y + body.ActualHeight));
        int start = Math.Max((int)Math.Ceiling(origin.Y), bottom - 60);
        var background = ((SolidColorBrush)root.Background).Color;
        // Sample the left side so the floating navigation buttons do not affect text contrast.
        int left = (int)Math.Ceiling(origin.X), right = left + (int)Math.Floor(body.ActualWidth - 96);
        for (int y = start; y < bottom; y++)
            for (int x = left; x < right; x++)
            {
                int pixel = (y * width + x) * 4;
                fadedInk += Math.Abs(faded[pixel] - background.B) + Math.Abs(faded[pixel + 1] - background.G)
                    + Math.Abs(faded[pixel + 2] - background.R);
                plainInk += Math.Abs(plain[pixel] - background.B) + Math.Abs(plain[pixel + 1] - background.G)
                    + Math.Abs(plain[pixel + 2] - background.R);
            }
        Check(plainInk > 1000 && fadedInk < plainInk * .65,
            "rendered bottom text visibly loses opacity before disappearing into the page background");
    }

    private static void LayoutDesktop(MainWindow window, int width, int height)
    {
        Grid root = (Grid)window.Content;
        for (int i = 0; i < 3; i++)
        {
            root.Measure(new Size(width, height));
            root.Arrange(new Rect(0, 0, width, height));
            root.UpdateLayout();
            Invoke(window, "UpdateHomeLayout");
        }
        PumpReader();
        root.UpdateLayout();
    }

    private static void RenderDesktop(MainWindow window, string directory, string name, int width, int height)
    {
        LayoutDesktop(window, width, height);
        UIElement transition = (UIElement)window.FindName("ViewTransitionOverlay");
        transition.BeginAnimation(UIElement.OpacityProperty, null);
        transition.Opacity = 0;
        RenderToFile((Grid)window.Content, width, height, Path.Combine(directory, name + ".png"));
    }
}
