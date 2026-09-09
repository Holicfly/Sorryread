using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using WpfRichTextBox = System.Windows.Controls.RichTextBox;

namespace ReadAI;

public static class ReaderBrowserSearch
{
    public static readonly DependencyProperty IsEnabledProperty = DependencyProperty.RegisterAttached(
        "IsEnabled", typeof(bool), typeof(ReaderBrowserSearch), new PropertyMetadata(false, EnabledChanged));
    public static bool GetIsEnabled(DependencyObject target) => (bool)target.GetValue(IsEnabledProperty);
    public static void SetIsEnabled(DependencyObject target, bool value) => target.SetValue(IsEnabledProperty, value);

    private static void EnabledChanged(DependencyObject target, DependencyPropertyChangedEventArgs e)
    {
        if (target is not ContextMenu menu) return;
        if ((bool)e.OldValue)
        {
            menu.Opened -= MenuOpened;
            menu.Closed -= MenuClosed;
            menu.RemoveHandler(MenuItem.ClickEvent, new RoutedEventHandler(MenuItemClick));
        }
        if ((bool)e.NewValue)
        {
            menu.Opened += MenuOpened;
            menu.Closed += MenuClosed;
            menu.AddHandler(MenuItem.ClickEvent, new RoutedEventHandler(MenuItemClick));
        }
    }

    private static void MenuOpened(object sender, RoutedEventArgs e)
    {
        if (sender is not ContextMenu menu) return;
        // Read once per opening, never from CommandManager requery.
        string text = menu.PlacementTarget is WpfRichTextBox reader ? reader.Selection.Text : string.Empty;
        SetItemsEnabled(menu, !string.IsNullOrWhiteSpace(text));
    }

    private static void MenuClosed(object sender, RoutedEventArgs e)
    {
        if (sender is ContextMenu menu) SetItemsEnabled(menu, false);
    }

    private static void SetItemsEnabled(ContextMenu menu, bool enabled)
    {
        foreach (MenuItem item in menu.Items.OfType<MenuItem>()) item.IsEnabled = enabled;
    }

    private static void MenuItemClick(object sender, RoutedEventArgs e)
    {
        if (sender is not ContextMenu menu || menu.PlacementTarget is not WpfRichTextBox reader
            || e.OriginalSource is not MenuItem item) return;
        string text = reader.Selection.Text.Trim();
        if (text.Length == 0) return;
        e.Handled = true;
        if (item.Tag is "Copy") reader.Copy();
        else if (item.Tag is "Search") OpenSearch(text);
    }

    private static void OpenSearch(string text)
        {
            try
            {
                Process.Start(new ProcessStartInfo("https://www.bing.com/search?q=" + Uri.EscapeDataString(text))
                {
                    UseShellExecute = true
                });
            }
            catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
            {
                // A missing browser association must not close the reader or discard its selection.
                Trace.TraceError("Unable to open browser search: {0}", exception.Message);
            }
        }
}
