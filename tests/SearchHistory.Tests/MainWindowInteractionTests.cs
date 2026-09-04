using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ReadAI;

internal static partial class Program
{
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;

    private static object? Invoke(object target, string method, params object[] arguments)
        => target.GetType().GetMethod(method, PrivateInstance)!.Invoke(target, arguments);

    private static T Field<T>(object target, string name) => (T)target.GetType().GetField(name, PrivateInstance)!.GetValue(target)!;
    private static void SetField(object target, string name, object value) => target.GetType().GetField(name, PrivateInstance)!.SetValue(target, value);

    private static void TestOverlay(string directory)
    {
        SearchOverlayControl overlay = new();
        Window host = new() { Content = overlay };
        string? submitted = null;
        overlay.SearchRequested += (_, keyword) => submitted = keyword;
        overlay.SearchText = "  保留搜索词  ";
        overlay.Open("聚合搜索 11 个书源", animate: false);
        overlay.Measure(new Size(640, 300));
        overlay.Arrange(new Rect(0, 0, 640, 300));
        overlay.UpdateLayout();
        Check(Math.Abs(((StackPanel)overlay.FindName("SearchCard")).ActualWidth - 640 * 0.68) < 1,
            "overlay capsule uses 68 percent of the window width");
        Click((Button)overlay.FindName("SubmitButton"));
        Check(submitted == "保留搜索词", "overlay search button submits a normalized keyword");
        overlay.Close(animate: false);
        Check(!overlay.IsOpen && overlay.SearchText.Length == 0, "closing overlay clears the submitted draft");
        overlay.Open("18mh 小说网单独搜索", animate: false);
        Check(((TextBlock)overlay.FindName("ModeHintText")).Text.Contains("18mh") && overlay.SearchText.Length == 0,
            "reopening shows the current mode with an empty input");
        overlay.SearchText = "   ";
        submitted = null;
        Click((Button)overlay.FindName("SubmitButton"));
        Check(submitted is null && overlay.IsOpen, "empty overlay input never starts search or closes the overlay");
        overlay.SearchText = "凡人修仙传";
        overlay.Open("18mh 小说网单独搜索", animate: false);
        overlay.UpdateLayout();
        RenderTargetBitmap bitmap = new(640, 300, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(overlay);
        PngBitmapEncoder encoder = new();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (FileStream stream = File.Create(Path.Combine(directory, "search-overlay-dark.png"))) encoder.Save(stream);
        Border backdrop = (Border)overlay.FindName("Backdrop");
        backdrop.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left)
        {
            RoutedEvent = UIElement.MouseLeftButtonDownEvent
        });
        Check(!overlay.IsOpen && overlay.SearchText.Length == 0, "clicking the backdrop cancels and clears input");
        host.Close();
    }

    private static void TestMainWindowInteractions(string directory)
    {
        using ReaderDatabase database = new(Path.Combine(directory, "window-test.db"));
        database.Initialize();
        MainWindow window = (MainWindow)Activator.CreateInstance(typeof(MainWindow), PrivateInstance, null, [database, false], null)!;
        var navigation = Field<ReaderNavigation>(window, "_viewNavigation");
        var history = (SearchHistoryControl)window.FindName("SearchHistoryPanel");
        var reader = (RichTextBox)window.FindName("ReaderBox");
        var results = (ListBox)window.FindName("SearchResultsList");
        var input = (Grid)window.FindName("InputPanel");
        var previous = (Button)window.FindName("PreviousChapterButton");
        var next = (Button)window.FindName("NextChapterButton");
        var back = (Button)window.FindName("ReturnToReadingButton");
        window.Width = 640;
        window.Height = 180;
        foreach (bool searchMode in new[] { true, false, true })
        {
            ((RadioButton)window.FindName(searchMode ? "SearchModeSelector" : "ParseModeSelector")).IsChecked = true;
            Check(window.Width == 640 && window.Height == 180 && window.MinHeight == 130 && window.MinWidth == 360,
                "real mode-switch handlers preserve user window size and limits");
        }
        database.AddSearchHistory(SearchHistoryModes.Aggregated, "测试记录");
        Invoke(window, "RefreshSearchHistory");
        Check(history.Visibility == Visibility.Visible && back.Visibility == Visibility.Visible && !back.IsEnabled,
            "home shows records but back stays visible and disabled");
        MenuItem disableHistory = (MenuItem)window.FindName("DisableSearchHistoryMenuItem");
        disableHistory.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Invoke(window, "RecordSearchHistory", "不记录的新关键词");
        Invoke(window, "RefreshSearchHistory");
        Check(disableHistory.IsChecked && !database.LoadSettings().SearchHistoryEnabled &&
            database.GetSearchHistory(SearchHistoryModes.Aggregated).Count == 1 && history.Visibility == Visibility.Visible,
            "settings menu disables recording without hiding or deleting old records");
        disableHistory.IsChecked = false;
        disableHistory.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Check(disableHistory.IsChecked, "clicking the active history option cannot uncheck it");
        ((MenuItem)window.FindName("EnableSearchHistoryMenuItem")).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Invoke(window, "RecordSearchHistory", "重新记录");
        Check(database.LoadSettings().SearchHistoryEnabled && database.GetSearchHistory(SearchHistoryModes.Aggregated).Count == 2,
            "settings menu re-enables persistent recording");
        var source = BookSourceCatalog.Aggregated[0];
        var state = new BookSourceSearchState
        {
            Source = source, Status = BookSourceSearchStatus.Succeeded,
            Results = Enumerable.Range(0, 45).Select(i => new NovelSearchResult { Title = $"书名 {i}", Url = $"https://example.invalid/{i}", SourceId = source.Id }).ToList()
        };
        SetField(window, "_selectedAggregatedSourceId", source.Id);
        SetField(window, "_aggregatedSearchStates", new List<BookSourceSearchState> { state });
        Invoke(window, "CacheAggregatedSearchPage", state);
        Invoke(window, "ShowSearchResultsView");
        Invoke(window, "ShowSelectedAggregatedSourceResults", false);
        Check(input.Visibility == Visibility.Collapsed && history.Visibility == Visibility.Collapsed && results.Items.Count == 20,
            "real results transition hides input/history and slices to 20");
        Check(back.IsEnabled && !previous.IsEnabled && next.IsEnabled && next.ToolTip.ToString()!.Contains("下一页"),
            "result state enables page arrows with correct boundary and tooltip");
        Click(next);
        Check(results.Items.Count == 20 && previous.IsEnabled, "status next arrow switches the local result page");
        Click(next);
        Check(results.Items.Count == 5 && !next.IsEnabled, "status next arrow disables on the final local page");
        Click(previous);
        Check(results.Items.Count == 20 && next.IsEnabled, "status previous arrow restores the cached slice");
        Check(!(bool)Invoke(window, "CanNavigateChapter", true)!, "chapter shortcuts are not active on a results page");

        PageParseResult page = new()
        {
            Title = "测试章节", Text = string.Join('\n', Enumerable.Repeat("这是用于验证阅读恢复的正文。", 80)),
            IsContentReady = true, PreviousUrl = "https://example.invalid/previous", NextUrl = "https://example.invalid/next"
        };
        SetField(window, "_currentPage", page);
        SetField(window, "_currentEntry", new HistoryEntry { Title = page.Title, Content = page.Text, Url = "https://example.invalid/current" });
        Invoke(window, "RenderArticle", page, 0.4);
        var document = reader.Document;
        Check(navigation.Current == ReaderView.Reader && back.IsEnabled && next.IsEnabled && next.ToolTip.ToString() == "下一章",
            "reading restores chapter arrows without altering pagination handlers");
        Click((Button)window.FindName("SearchButton"));
        SearchOverlayControl overlay = (SearchOverlayControl)window.FindName("SearchOverlay");
        Check(overlay.IsOpen && navigation.Current == ReaderView.Reader && ReferenceEquals(reader.Document, document),
            "opening search leaves the reading page and document intact");
        Check(!(bool)Invoke(window, "CanNavigateChapter", true)!, "search overlay blocks chapter shortcuts underneath typing");
        Check(!Field<HotKeyService>(window, "_hotKeyService").ChapterShortcutsEnabled, "overlay does not intercept shifted F/J as chapter hotkeys");
        overlay.SearchText = "草稿";
        overlay.Close(animate: false);
        Check(Field<HotKeyService>(window, "_hotKeyService").ChapterShortcutsEnabled, "closing overlay restores chapter hotkeys");
        Check(overlay.SearchText.Length == 0 && navigation.Current == ReaderView.Reader, "cancel overlay clears input and leaves the original reader intact");
        Invoke(window, "ShowSearchResultsView");
        SetField(window, "_currentUrl", "https://example.invalid/current");
        SetField(window, "_readingReturnProgress", 0.37);
        Invoke(window, "SaveCurrentProgress");
        Check(Field<HistoryEntry>(window, "_currentEntry").Progress == 0.37 && Field<double>(window, "_readingReturnProgress") == 0.37,
            "delayed progress saves do not reset a hidden reader to the top");
        Click(back);
        Check(navigation.Current == ReaderView.Reader && reader.Visibility == Visibility.Visible && ReferenceEquals(reader.Document, document),
            "search results back returns to the retained reading document");
        Invoke(window, "ShowLibraryPanel");
        Check(!previous.IsEnabled && !next.IsEnabled && back.IsEnabled, "library disables arrows and keeps a valid return target");
        Click(back);
        Check(navigation.Current == ReaderView.Reader, "library status back returns to reading");
        Click((Button)window.FindName("HomeButton"));
        Check(navigation.Current == ReaderView.Home && !back.IsEnabled && !previous.IsEnabled && !next.IsEnabled,
            "home resets return and arrow state without discarding the reading session");
        Check(window.Width == 640 && window.Height == 180, "results/reading/library/home transitions never resize the window");
        window.Width = 360;
        window.Height = 130;
        Invoke(window, "ShowSearchResultsView");
        Check(window.Width == 360 && window.Height == 130 && ((StatusBar)window.FindName("StatusRegion")).Visibility == Visibility.Visible,
            "smallest user window remains small and status controls stay visible");
        Invoke(window, "SaveWindowSettings");
        Check(database.LoadSettings().WindowWidth == 360 && database.LoadSettings().WindowHeight == 130,
            "window size persistence keeps user dimensions");

        window.Width = 640;
        window.Height = 420;
        Click((Button)window.FindName("HomeButton"));
        Invoke(window, "SwitchSearchScope");
        Click((Button)window.FindName("SearchButton"));
        Check(((TextBlock)overlay.FindName("ModeHintText")).Text.Contains("18mh") && !Field<bool>(window, "_aggregatedSearchMode"),
            "overlay follows the home-selected source mode without changing it");
        overlay.Close(animate: false);
        Invoke(window, "SwitchSearchScope");
        Grid root = (Grid)window.Content;
        ((UIElement)window.FindName("ViewTransitionOverlay")).BeginAnimation(UIElement.OpacityProperty, null);
        ((UIElement)window.FindName("ViewTransitionOverlay")).Opacity = 0;
        foreach (string theme in new[] { "Dark", "Light" })
        {
            Application.Current.Resources.MergedDictionaries[0] = Theme(theme);
            root.Measure(new Size(640, 390));
            root.Arrange(new Rect(0, 0, 640, 390));
            root.UpdateLayout();
            RenderToFile(root, 640, 390, Path.Combine(directory, $"main-home-{theme.ToLowerInvariant()}.png"));
            overlay.Open("聚合搜索 11 个书源", animate: false);
            root.UpdateLayout();
            RenderToFile(root, 640, 390, Path.Combine(directory, $"main-search-overlay-{theme.ToLowerInvariant()}.png"));
            Check(((SolidColorBrush)((TextBox)overlay.FindName("SearchTextBox")).Foreground).Color ==
                ((SolidColorBrush)Application.Current.FindResource("TextPrimaryBrush")).Color,
                $"existing overlay adapts dynamically to {theme} theme");
            overlay.Close(animate: false);
        }
        Application.Current.Resources.MergedDictionaries[0] = Theme("Dark");
        database.AddSearchHistory(SearchHistoryModes.Legacy18Mh, "单独搜索记录");
        Invoke(window, "ClearAllSearchHistoryClick", window, new RoutedEventArgs());
        Check(database.GetSearchHistory(SearchHistoryModes.Aggregated).Count == 0 &&
            database.GetSearchHistory(SearchHistoryModes.Legacy18Mh).Count == 0 && history.Visibility == Visibility.Collapsed,
            "main settings clear both search modes immediately and update home");

        SetField(window, "_allowExit", true);
        window.Close();
        ((IDisposable)Field<object>(window, "_notifyIcon")).Dispose();
        ((IDisposable)Field<object>(window, "_hotKeyService")).Dispose();
        ((IDisposable)Field<object>(window, "_aggregatedSearchService")).Dispose();
    }

    private static void RenderToFile(UIElement element, int width, int height, string path)
    {
        RenderTargetBitmap bitmap = new(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(element);
        PngBitmapEncoder encoder = new();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using FileStream stream = File.Create(path);
        encoder.Save(stream);
    }
}
