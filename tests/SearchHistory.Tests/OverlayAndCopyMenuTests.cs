using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using ReadAI;

internal static partial class Program
{
    // Raise both phases with the same handled state, including WPF's button-specific event promotion.
    private static MouseButtonEventArgs RaiseMouse(UIElement target, bool down, MouseButton button = MouseButton.Left)
    {
        MouseButtonEventArgs e = new(Mouse.PrimaryDevice, Environment.TickCount, button)
        {
            RoutedEvent = down ? Mouse.PreviewMouseDownEvent : Mouse.PreviewMouseUpEvent
        };
        target.RaiseEvent(e);
        e.RoutedEvent = down ? Mouse.MouseDownEvent : Mouse.MouseUpEvent;
        target.RaiseEvent(e);
        return e;
    }

    private static void FinishFade(SearchOverlayControl overlay)
        => Invoke(overlay, "CompleteClose", Field<int>(overlay, "_transitionVersion"));

    private static void TestOverlayMouseGuard()
    {
        Grid scene = new();
        Border underlying = new() { Background = Brushes.Gray };
        SearchOverlayControl overlay = new();
        scene.Children.Add(underlying);
        scene.Children.Add(overlay);
        Window host = new() { Content = scene };
        int activations = 0;
        underlying.MouseLeftButtonUp += (_, _) => activations++;
        Border backdrop = (Border)overlay.FindName("Backdrop");
        overlay.Open("聚合搜索", animate: false);
        scene.Measure(new Size(640, 300));
        scene.Arrange(new Rect(0, 0, 640, 300));
        scene.UpdateLayout();
        RaiseMouse((StackPanel)overlay.FindName("SearchCard"), true);
        RaiseMouse((StackPanel)overlay.FindName("SearchCard"), false);
        Check(overlay.IsOpen, "clicking inside the search card never dismisses the overlay");

        RaiseMouse(backdrop, true);
        Check(!overlay.IsOpen && overlay.IsHitTestVisible && overlay.Visibility == Visibility.Visible && backdrop.ActualWidth == 640,
            "dismissal keeps the backdrop hit-testable throughout the fade");
        Check(RaiseMouse(underlying, false).Handled && activations == 0,
            "release during the fade is consumed before the underlying MouseLeftButtonUp");
        FinishFade(overlay);
        Check(overlay.Visibility == Visibility.Collapsed && !overlay.IsHitTestVisible && Field<UIElement?>(overlay, "_inputGuardHost") is null,
            "completed short click releases all input guards after the fade");
        RaiseMouse(underlying, true);
        RaiseMouse(underlying, false);
        Check(activations == 1, "the next complete click activates the underlying item normally");

        overlay.Open("聚合搜索", animate: false);
        RaiseMouse(backdrop, true);
        FinishFade(overlay);
        Check(RaiseMouse(underlying, false).Handled && activations == 1,
            "a held click released after fade completion cannot fall through");
        RaiseMouse(underlying, true);
        RaiseMouse(underlying, false);
        Check(activations == 2, "the held-click guard consumes exactly one release");

        overlay.Open("聚合搜索", animate: false);
        RaiseMouse(backdrop, true);
        RaiseMouse(backdrop, false);
        Check(RaiseMouse(underlying, true).Handled, "extra mouse presses during dismissal are blocked");
        FinishFade(overlay);
        Check(RaiseMouse(underlying, false).Handled && activations == 2,
            "extra fade-time clicks retain their own release guard beyond the fade");

        overlay.Open("聚合搜索", animate: false);
        overlay.Close(); // Escape/Enter use this same closing path without an initial mouse press.
        Check(RaiseMouse(underlying, true, MouseButton.Right).Handled, "right clicks are blocked during the fade too");
        FinishFade(overlay);
        Check(RaiseMouse(underlying, false, MouseButton.Right).Handled, "a fade-time right click cannot open an underlying context menu");
        RaiseMouse(underlying, true);
        RaiseMouse(underlying, false);
        Check(activations == 3, "keyboard dismissal does not suppress the next unrelated click");

        overlay.Open("聚合搜索", animate: false);
        RaiseMouse(backdrop, true);
        FinishFade(overlay); // Simulate a release outside the window, which never enters WPF's event route.
        Check(!RaiseMouse(underlying, true).Handled && !RaiseMouse(underlying, false).Handled && activations == 4,
            "a lost outside release cannot poison the next fresh click");

        overlay.Open("聚合搜索", animate: false);
        RaiseMouse(backdrop, true);
        int oldVersion = Field<int>(overlay, "_transitionVersion");
        overlay.Open("18mh", animate: false);
        Invoke(overlay, "CompleteClose", oldVersion);
        Check(overlay.IsOpen && overlay.IsHitTestVisible && overlay.Visibility == Visibility.Visible,
            "a stale fade completion cannot collapse a reopened overlay");
        Check(RaiseMouse(backdrop, false).Handled, "reopening does not leak the previous dismissal release");

        overlay.SearchText = "保留草稿";
        string? submitted = null;
        overlay.SearchRequested += (_, keyword) => submitted = keyword;
        KeyEventArgs enter = new(Keyboard.PrimaryDevice, new TestPresentationSource(), Environment.TickCount, Key.Enter)
            { RoutedEvent = Keyboard.PreviewKeyDownEvent };
        overlay.RaiseEvent(enter);
        Check(enter.Handled && submitted == "保留草稿", "Enter still submits the focused search draft");
        KeyEventArgs escape = new(Keyboard.PrimaryDevice, new TestPresentationSource(), Environment.TickCount, Key.Escape)
            { RoutedEvent = Keyboard.PreviewKeyDownEvent };
        overlay.RaiseEvent(escape);
        Check(escape.Handled && !overlay.IsOpen && overlay.SearchText.Length == 0, "Escape consumes its key and clears the draft");
        FinishFade(overlay);
        RaiseMouse(underlying, true);
        RaiseMouse(underlying, false);
        Check(activations == 5, "Escape leaves subsequent normal clicking intact");

        overlay.Open("聚合搜索", animate: false);
        RaiseMouse(backdrop, true);
        overlay.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
        Check(Field<UIElement?>(overlay, "_inputGuardHost") is null, "unloading the overlay removes any remaining window input guard");
        host.Close();
    }

    private sealed class TestPresentationSource : PresentationSource
    {
        public override Visual RootVisual { get; set; } = null!;
        public override bool IsDisposed => false;
        protected override CompositionTarget GetCompositionTargetCore() => null!;
    }

    private static void TestReaderCopyMenus(string directory)
    {
        using ReaderDatabase database = new(Path.Combine(directory, "copy-menu.db"));
        database.Initialize();
        MainWindow main = (MainWindow)Activator.CreateInstance(typeof(MainWindow), PrivateInstance, null, [database, false], null)!;
        TransparentReaderWindow transparent = new();
        RichTextBox normalReader = (RichTextBox)main.FindName("ReaderBox");
        RichTextBox transparentReader = (RichTextBox)transparent.FindName("TransparentReaderBox");
        Check(!ReferenceEquals(normalReader.ContextMenu, transparentReader.ContextMenu), "each reader has its own context menu instance");

        foreach ((string name, RichTextBox reader) in new[] { ("normal", normalReader), ("transparent", transparentReader) })
        {
            reader.Visibility = Visibility.Visible;
            reader.Document = new FlowDocument(new Paragraph(new Run("选中文字用于复制验证")));
            ContextMenu menu = reader.ContextMenu;
            menu.PlacementTarget = reader;
            menu.Visibility = Visibility.Visible;
            menu.ApplyTemplate();
            menu.Measure(new Size(300, 100));
            menu.Arrange(new Rect(new Point(), menu.DesiredSize));
            menu.UpdateLayout();
            MenuItem copy = (MenuItem)menu.Items[0];
            MenuItem search = (MenuItem)menu.Items[2];
            Check(menu.Items.Count == 3 && copy.Header.ToString() == "复制" && copy.Tag?.ToString() == "Copy" &&
                search.Header.ToString() == "在浏览器中搜索" && search.Tag?.ToString() == "Search" &&
                copy.Command == ApplicationCommands.Copy && ReferenceEquals(copy.CommandTarget, reader),
                $"{name} reader exposes Copy and browser search actions");
            reader.Selection.Select(reader.Document.ContentStart, reader.Document.ContentStart);
            menu.RaiseEvent(new RoutedEventArgs(ContextMenu.OpenedEvent));
            RefreshCommandState();
            Check(!copy.IsEnabled && !search.IsEnabled && !ApplicationCommands.Copy.CanExecute(null, reader), $"{name}: copy and search are unavailable without a selection");
            reader.SelectAll();
            menu.RaiseEvent(new RoutedEventArgs(ContextMenu.OpenedEvent));
            RefreshCommandState();
            Check(copy.IsEnabled && search.IsEnabled && ApplicationCommands.Copy.CanExecute(null, reader), $"{name}: copy and search become available for a selection");
            string selected = reader.Selection.Text;
            string? copied = null;
            // Verify menu command dispatch without overwriting the user's real clipboard.
            reader.CommandBindings.Add(new CommandBinding(ApplicationCommands.Copy,
                (_, e) => { copied = reader.Selection.Text; e.Handled = true; },
                (_, e) => { e.CanExecute = !reader.Selection.IsEmpty; e.Handled = true; }));
            typeof(MenuItem).GetMethod("OnClick", PrivateInstance)!.Invoke(copy, null);
            RefreshCommandState();
            Check(copied == selected && reader.Selection.Text == selected, $"{name}: Copy dispatch preserves the original selection");

            foreach (string theme in new[] { "Dark", "Light" })
            {
                Application.Current.Resources.MergedDictionaries[0] = Theme(theme);
                // A closed ContextMenu has no presentation source. Supply its theme locally for offscreen rendering.
                menu.Resources.MergedDictionaries.Clear();
                menu.Resources.MergedDictionaries.Add(Theme(theme));
                menu.UpdateLayout();
                Check(((SolidColorBrush)menu.Background).Color == ((SolidColorBrush)Application.Current.FindResource("SurfaceBrush")).Color,
                    $"{name}: context menu follows the {theme} theme");
                Check(menu.Template.FindName("ContextMenuSurface", menu) is Border { CornerRadius.TopLeft: 8 },
                    $"{name}: custom rounded context menu template replaces native chrome");
                RenderToFile(menu, 210, 70, Path.Combine(directory, $"copy-menu-{name}-{theme.ToLowerInvariant()}.png"));
            }
        }
        Application.Current.Resources.MergedDictionaries[0] = Theme("Dark");
        transparent.CloseForShutdown();
        SetField(main, "_allowExit", true);
        main.Close();
        ((IDisposable)Field<object>(main, "_notifyIcon")).Dispose();
        ((IDisposable)Field<object>(main, "_hotKeyService")).Dispose();
        ((IDisposable)Field<object>(main, "_aggregatedSearchService")).Dispose();
    }

    private static void RefreshCommandState()
    {
        CommandManager.InvalidateRequerySuggested();
        DispatcherFrame frame = new();
        DispatcherTimer deadline = new(DispatcherPriority.Send) { Interval = TimeSpan.FromMilliseconds(50) };
        deadline.Tick += (_, _) => frame.Continue = false;
        deadline.Start();
        try { Dispatcher.PushFrame(frame); }
        finally { deadline.Stop(); }
    }
}
