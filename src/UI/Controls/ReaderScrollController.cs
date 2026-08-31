using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using WpfRichTextBox = System.Windows.Controls.RichTextBox;

namespace ReadAI;

public static class ReaderScrollController
{
    private const int WheelDeltaPerNotch = 120;
    private const int LinesPerWheelNotch = 3;

    public static bool HandleNavigationKey(WpfRichTextBox readerBox, Key key)
    {
        ScrollViewer? scrollViewer = FindScrollViewer(readerBox);
        if (scrollViewer is null) return false;

        switch (key)
        {
            case Key.Up:
            case Key.PageUp:
                scrollViewer.PageUp();
                return true;
            case Key.Down:
            case Key.PageDown:
                scrollViewer.PageDown();
                return true;
            default:
                return false;
        }
    }

    public static bool HandleMouseWheel(WpfRichTextBox readerBox, int delta)
    {
        ScrollViewer? scrollViewer = FindScrollViewer(readerBox);
        if (scrollViewer is null || delta == 0) return false;

        int lineCount = Math.Max(1, Math.Abs(delta) / WheelDeltaPerNotch) * LinesPerWheelNotch;
        for (int index = 0; index < lineCount; index++)
        {
            if (delta > 0)
            {
                scrollViewer.LineUp();
            }
            else
            {
                scrollViewer.LineDown();
            }
        }
        return true;
    }

    private static ScrollViewer? FindScrollViewer(DependencyObject? parent)
    {
        if (parent is null) return null;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(parent, index);
            if (child is ScrollViewer scrollViewer) return scrollViewer;
            ScrollViewer? descendant = FindScrollViewer(child);
            if (descendant is not null) return descendant;
        }
        return null;
    }
}
