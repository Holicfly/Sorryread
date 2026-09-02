using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Markup;
using System.Xml.Linq;
using Microsoft.Data.Sqlite;
using ReadAI;

internal static partial class Program
{
    private static int _assertions;

    [STAThread]
    private static void Main()
    {
        string directory = Path.Combine(Path.GetTempPath(), "Sorryread-SearchHistory-Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "test.db");
        TestDatabase(path);
        TestNavigationAndPaging();
        TestControl(directory);
        Console.WriteLine($"PASS: {_assertions} assertions; isolated database: {path}");
    }

    private static void TestDatabase(string path)
    {
        const string aggregated = SearchHistoryModes.Aggregated;
        const string legacy = SearchHistoryModes.Legacy18Mh;
        // Start from an old schema, without the new table or the latest History columns.
        using (SqliteConnection connection = new($"Data Source={path}"))
        {
            connection.Open();
            using SqliteCommand command = connection.CreateCommand();
            command.CommandText = """
                CREATE TABLE Settings(Key TEXT PRIMARY KEY, Value TEXT NOT NULL);
                INSERT INTO Settings VALUES ('TextColor', '#123456');
                CREATE TABLE History (
                    Id INTEGER PRIMARY KEY AUTOINCREMENT, Url TEXT NOT NULL UNIQUE,
                    Title TEXT NOT NULL, Content TEXT NOT NULL, PreviousUrl TEXT NOT NULL DEFAULT '',
                    NextUrl TEXT NOT NULL DEFAULT '', Progress REAL NOT NULL DEFAULT 0,
                    CreatedUtc TEXT NOT NULL, LastReadUtc TEXT NOT NULL, LocalPath TEXT NOT NULL DEFAULT ''
                );
                INSERT INTO History(Url, Title, Content, Progress, CreatedUtc, LastReadUtc)
                VALUES ('https://example.invalid/chapter', 'existing title', 'existing content', 0.4,
                    '2026-09-01T00:00:00.0000000Z', '2026-09-01T00:00:00.0000000Z');
                """;
            command.ExecuteNonQuery();
        }

        using ReaderDatabase database = new(path);
        database.Initialize();
        database.Initialize();
        Check(database.LoadSettings().TextColor == "#123456", "schema upgrade preserves settings");
        Check(database.GetHistoryByUrl("https://example.invalid/chapter") is { Content: "existing content", Progress: 0.4 },
            "schema upgrade preserves reading content and progress");
        Check(database.GetSearchHistory(aggregated).Count == 0, "old database starts with no search history");

        database.AddSearchHistory(aggregated, "   ");
        Check(database.GetSearchHistory(aggregated).Count == 0, "empty keyword ignored");
        database.AddSearchHistory(aggregated, "  三体  ");
        database.AddSearchHistory(aggregated, "凡人修仙传");
        database.AddSearchHistory(aggregated, "三体");
        Check(database.GetSearchHistory(aggregated).Select(entry => entry.Keyword).SequenceEqual(new[] { "三体", "凡人修仙传" }),
            "trimmed duplicate moves to front without duplication");
        database.AddSearchHistory(legacy, "三体");
        Check(database.GetSearchHistory(legacy).Single().Mode == legacy && database.GetSearchHistory(aggregated).Count == 2,
            "same keyword is independent across modes");

        for (int i = 0; i < 17; i++) database.AddSearchHistory(aggregated, $"小说{i:D2}");
        var entries = database.GetSearchHistory(aggregated);
        Check(entries.Count == 15 && entries[0].Keyword == "小说16" && entries[^1].Keyword == "小说02",
            "each mode keeps only the 15 latest searches in strict order");
        Check(database.GetSearchHistory(legacy).Single().Keyword == "三体", "trimming one mode leaves the other untouched");
        database.AddSearchHistory(aggregated, "小说02");
        Check(database.GetSearchHistory(aggregated)[0].Keyword == "小说02", "oldest duplicate becomes newest at capacity");
        database.AddSearchHistory(aggregated, "BOOK");
        database.AddSearchHistory(aggregated, "book");
        Check(database.GetSearchHistory(aggregated).Count(entry => entry.Keyword.Equals("book", StringComparison.OrdinalIgnoreCase)) == 1,
            "ASCII case duplicates are merged");
        database.AddSearchHistory(legacy, "O'Brien'; DELETE FROM Settings;--");
        database.DeleteSearchHistory(legacy, "O'Brien'; DELETE FROM Settings;--");
        Check(database.LoadSettings().TextColor == "#123456" && database.GetSearchHistory(legacy).Count == 1,
            "SQL-looking keywords are safely parameterized");
        database.DeleteSearchHistory(aggregated, "book");
        Check(database.GetSearchHistory(aggregated).All(entry => entry.Keyword != "book"), "single delete is immediate");
        database.DeleteSearchHistory(aggregated, "三体");
        Check(database.GetSearchHistory(legacy).Count == 1, "single delete is mode-scoped");

        using ReaderDatabase reopened = new(path);
        reopened.Initialize();
        Check(reopened.GetSearchHistory(aggregated).SequenceEqual(database.GetSearchHistory(aggregated)), "records and order survive reopening");
        reopened.ClearSearchHistory(aggregated);
        Check(reopened.GetSearchHistory(aggregated).Count == 0 && reopened.GetSearchHistory(legacy).Count == 1, "clear only removes current mode");
        Check(reopened.GetHistoryCount() == 1 && reopened.LoadSettings().TextColor == "#123456", "clear preserves reading history and settings");
        bool rejected = false;
        try { database.ClearSearchHistory("other"); }
        catch (ArgumentException) { rejected = true; }
        Check(rejected, "unknown modes are rejected");
        Check(database.LoadSettings().SearchHistoryEnabled, "search history defaults to enabled for existing databases");
        database.SetSetting("SearchHistoryEnabled", "False");
        database.AddSearchHistory(legacy, "不应新增");
        database.AddSearchHistory(legacy, "三体");
        Check(!reopened.LoadSettings().SearchHistoryEnabled && reopened.GetSearchHistory(legacy).Single().Keyword == "三体",
            "disabled setting persists and preserves existing records without adding or reordering");
        database.SetSetting("SearchHistoryEnabled", "True");
        database.AddSearchHistory(aggregated, "重新开启");
        Check(reopened.GetSearchHistory(aggregated).Single().Keyword == "重新开启" && reopened.GetSearchHistory(legacy).Count == 1,
            "re-enabling resumes recording and keeps the old other-mode records");
        database.ClearAllSearchHistory();
        Check(reopened.GetSearchHistory(aggregated).Count == 0 && reopened.GetSearchHistory(legacy).Count == 0 &&
            reopened.GetHistoryCount() == 1 && reopened.LoadSettings().TextColor == "#123456",
            "settings clear removes both search modes but not reading data");
    }

    private static void TestControl(string outputDirectory)
    {
        Application application = new() { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        application.Resources.MergedDictionaries.Add(Theme("Light"));
        application.Resources.MergedDictionaries.Add(Theme("Styles"));
        SearchHistoryControl control = new();
        // A logical window root lets Application propagate resource changes; it is never shown.
        Window testHost = new() { Content = control };
        List<SearchHistoryEntry> entries = Enumerable.Range(0, 15)
            .Select(i => new SearchHistoryEntry(SearchHistoryModes.Aggregated, $"较长的搜索关键词用于检查换行和截断{i}"))
            .ToList();
        control.SetEntries(SearchHistoryModes.Aggregated, entries);
        Layout(control, 336);
        ItemsControl items = (ItemsControl)control.FindName("HistoryItems");
        ScrollViewer scroll = (ScrollViewer)control.FindName("HistoryScrollViewer");
        Check(control.Visibility == Visibility.Visible, "history is visible when nonempty");
        Check(scroll.ViewportHeight <= 96 && scroll.ExtentHeight > scroll.ViewportHeight, "wrapped history scrolls within its height cap");
        WrapPanel wrap = Descendants<WrapPanel>(items).Single();
        Check(wrap.Children.Count == 15, "all history capsules are generated");
        Check(wrap.Children.Cast<FrameworkElement>().All(child => child.ActualWidth <= 336), "long capsules fit a narrow window");
        Check(wrap.Children.Cast<FrameworkElement>().Select(child => child.TranslatePoint(new Point(), wrap).Y).Distinct().Count() > 1,
            "capsules wrap across multiple rows");

        SearchHistoryEntry? searched = null;
        SearchHistoryEntry? deleted = null;
        bool cleared = false;
        control.SearchRequested += (_, entry) => searched = entry;
        control.DeleteRequested += (_, entry) => deleted = entry;
        control.ClearRequested += (_, _) => cleared = true;
        Button keywordButton = Descendants<Button>(items).First(button => button.Name != "DeleteButton");
        Button deleteButton = Descendants<Button>(items).First(button => button.Name == "DeleteButton");
        Click(keywordButton);
        Check(searched == entries[0], "normal click emits the exact keyword and mode");
        searched = null;
        Click((Button)control.FindName("ManageButton"));
        Layout(control, 336);
        Check(control.IsManaging && deleteButton.Visibility == Visibility.Visible && !keywordButton.IsEnabled,
            "management shows delete controls and disables keyword search");
        Click(deleteButton);
        Check(deleted == entries[0] && searched is null, "delete is a separate action and never starts a search");
        Click((Button)control.FindName("ClearButton"));
        Check(cleared, "clear action needs no second confirmation");
        Click((Button)control.FindName("ManageButton"));
        Check(!control.IsManaging, "done leaves management mode");

        control.IsManaging = true;
        control.SetEntries(SearchHistoryModes.Legacy18Mh, [new(SearchHistoryModes.Legacy18Mh, "三体")]);
        Layout(control, 336);
        Check(!control.IsManaging && control.Mode == SearchHistoryModes.Legacy18Mh, "scope switch resets management");
        Click(keywordButton);
        Check(searched is null, "stale controls cannot search in the wrong scope");
        Button currentKeyword = Descendants<Button>(items).First(button => button.Name != "DeleteButton");
        control.CanSearch = false;
        Click(currentKeyword);
        Check(searched is null, "busy search guard blocks repeated history clicks");

        application.Resources.MergedDictionaries[0] = Theme("Dark");
        Layout(control, 336);
        TextBlock title = (TextBlock)control.FindName("HistoryTitle");
        Check(((SolidColorBrush)title.Foreground).Color == ((SolidColorBrush)application.FindResource("TextDisabledBrush")).Color,
            "existing control updates to the dark theme dynamically");
        control.SetEntries(SearchHistoryModes.Legacy18Mh, []);
        Check(control.Visibility == Visibility.Collapsed && !control.IsManaging, "empty state hides the entire module");
        testHost.Close();
        TestSearchLayout(outputDirectory);
        TestOverlay(outputDirectory);
        TestMainWindowInteractions(outputDirectory);
        application.Shutdown();
    }

    private static void TestSearchLayout(string outputDirectory)
    {
        // Load the actual search/input markup without its MainWindow handlers, startup or WebView.
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        XDocument document = XDocument.Load(Path.Combine(AppContext.BaseDirectory, "MainWindow.Source.xaml"));
        XElement markup = new(document.Descendants().Single(element => (string?)element.Attribute(x + "Name") == "SearchInputLayout"));
        markup.Add(new XAttribute(XNamespace.Xmlns + "x", x.NamespaceName));
        markup.Add(new XAttribute(XNamespace.Xmlns + "local", "clr-namespace:ReadAI;assembly=素若阅读"));
        string[] events = ["Click", "Checked", "KeyDown", "PreviewMouseLeftButtonDown", "PreviewMouseDown", "PreviewMouseUp",
            "PreviewMouseWheel", "MouseLeftButtonUp", "SearchRequested", "DeleteRequested", "ClearRequested"];
        foreach (XElement element in markup.DescendantsAndSelf())
        {
            if (element.Name.NamespaceName == "clr-namespace:ReadAI")
                element.Name = XName.Get(element.Name.LocalName, "clr-namespace:ReadAI;assembly=素若阅读");
            foreach (string eventName in events) element.Attribute(eventName)?.Remove();
        }
        markup.Descendants().Where(element => element.Name.LocalName == "EventSetter").Remove();
        Grid layout = (Grid)XamlReader.Parse(markup.ToString());
        Window host = new() { Content = layout };
        layout.VerticalAlignment = VerticalAlignment.Stretch;
        SearchHistoryControl history = (SearchHistoryControl)layout.FindName("SearchHistoryPanel");
        history.SetEntries(SearchHistoryModes.Aggregated,
            Enumerable.Range(0, 15).Select(i => new SearchHistoryEntry(SearchHistoryModes.Aggregated, $"凡人修仙传{i}" )).ToList());
        Border sources = (Border)layout.FindName("BookSourceSelectorPanel");
        sources.Visibility = Visibility.Visible;
        ((ItemsControl)layout.FindName("BookSourceSelectorItems")).ItemsSource = new[]
        {
            new BookSourceSearchTab { DisplayText = "18mh（15）", SourceId = "legacy", IsSelected = true },
            new BookSourceSearchTab { DisplayText = "书源二（12）", SourceId = "second" }
        };
        ListBox results = (ListBox)layout.FindName("SearchResultsList");
        Grid resultPanel = (Grid)layout.FindName("SearchResultsPanel");
        Grid inputPanel = (Grid)layout.FindName("InputPanel");
        inputPanel.Visibility = Visibility.Collapsed;
        resultPanel.Visibility = Visibility.Visible;
        results.Visibility = Visibility.Visible;
        results.ItemsSource = Enumerable.Range(0, 20).Select(i => new NovelSearchResult { Title = $"搜索结果 {i + 1}" }).ToList();
        Check(layout.FindName("SearchPaginationPanel") is null, "old bottom pagination controls are removed");
        foreach (double width in new[] { 336d, 496d, 616d })
        {
            foreach (double height in new[] { 90d, 180d, 370d })
            {
                foreach (bool aggregated in new[] { true, false })
                {
                    sources.Visibility = aggregated ? Visibility.Visible : Visibility.Collapsed;
                    layout.Measure(new Size(width, height));
                    layout.Arrange(new Rect(0, 0, width, height));
                    layout.UpdateLayout();
                    double resultTop = results.TranslatePoint(new Point(), layout).Y;
                    Check(resultTop == (aggregated ? sources.ActualHeight : 0) && results.ActualHeight > 0,
                        $"{width}x{height}: {(aggregated ? "aggregate" : "18mh")} results start at top with no input/history space");
                }
            }
        }
        sources.Visibility = Visibility.Visible;
        layout.Measure(new Size(616, 370));
        layout.Arrange(new Rect(0, 0, 616, 370));
        layout.UpdateLayout();
        RenderTargetBitmap bitmap = new(616, 370, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(layout);
        PngBitmapEncoder encoder = new();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        string previewPath = Path.Combine(outputDirectory, "search-layout-dark.png");
        using (FileStream stream = File.Create(previewPath)) encoder.Save(stream);
        Console.WriteLine($"Layout preview: {previewPath}");
        resultPanel.Visibility = Visibility.Collapsed;
        inputPanel.Visibility = Visibility.Visible;
        layout.Measure(new Size(336, 90));
        layout.Arrange(new Rect(0, 0, 336, 90));
        layout.UpdateLayout();
        ScrollViewer homeScroll = (ScrollViewer)layout.FindName("HomeScrollViewer");
        Check(homeScroll.ExtentHeight > homeScroll.ViewportHeight, "compact home scrolls instead of forcing window growth");
        host.Close();
    }

    private static ResourceDictionary Theme(string name) => new()
    {
        Source = new Uri($"pack://application:,,,/素若阅读;component/assets/themes/{name}.xaml")
    };

    private static void Layout(FrameworkElement element, double width)
    {
        element.Measure(new Size(width, double.PositiveInfinity));
        element.Arrange(new Rect(0, 0, width, element.DesiredSize.Height));
        element.UpdateLayout();
    }

    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(root, i);
            if (child is T match) yield return match;
            foreach (T descendant in Descendants<T>(child)) yield return descendant;
        }
    }

    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException($"FAIL: {description}");
        _assertions++;
        Console.WriteLine($"PASS: {description}");
    }
}
