using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Documents;
using System.Windows.Threading;
using System.Runtime.CompilerServices;
using WpfRichTextBox = System.Windows.Controls.RichTextBox;

namespace ReadAI;

public static class ReaderScrollController
{
    private const int WheelDeltaPerNotch = 120;
    private const int LinesPerWheelNotch = 3;
    private const double BottomTolerance = 0.5;
    private const double LayoutTolerance = 0.001;
    private static readonly ConditionalWeakTable<WpfRichTextBox, AlignmentState> AlignmentStates = new();

    private sealed class AlignmentState
    {
        public bool Pending;
    }

    // WPF offsets and LineHeight both use device-independent pixels; no DPI conversion is needed.
    private static double GetLineHeight(WpfRichTextBox readerBox)
    {
        double height = readerBox.Document.LineHeight;
        if (double.IsFinite(height) && height > 0) return height;
        foreach (Paragraph paragraph in readerBox.Document.Blocks.OfType<Paragraph>())
            if (double.IsFinite(paragraph.LineHeight) && paragraph.LineHeight > 0) return paragraph.LineHeight;
        return Math.Max(1, readerBox.FontSize);
    }

    public static void UpdateFontSize(WpfRichTextBox readerBox, double fontSize)
    {
        FlowDocument document = readerBox.Document;
        double ratio = GetLineHeight(readerBox) / document.FontSize;
        readerBox.FontSize = fontSize;
        document.FontSize = fontSize;
        document.LineHeight = fontSize * ratio;
        foreach (Paragraph paragraph in document.Blocks.OfType<Paragraph>())
            paragraph.LineHeight = document.LineHeight;
        QueueAlignViewport(readerBox);
    }

    public static void QueueAlignViewport(WpfRichTextBox readerBox)
    {
        AlignmentState state = AlignmentStates.GetOrCreateValue(readerBox);
        if (state.Pending) return;
        state.Pending = true;
        readerBox.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            state.Pending = false;
            AlignViewport(readerBox);
        }));
    }

    public static void AlignViewport(WpfRichTextBox readerBox)
    {
        if (!readerBox.IsVisible || readerBox.ActualHeight <= 0) return;
        readerBox.ApplyTemplate();
        ScrollViewer? viewer = FindScrollViewer(readerBox);
        if (viewer is null) return;

        // Keep horizontal typography, but remove scrolling vertical padding so offset zero
        // and the document end share the same line grid. The outer reader margin is retained.
        Thickness padding = readerBox.Document.PagePadding;
        readerBox.Document.PagePadding = new Thickness(padding.Left, 0, padding.Right, 0);
        padding = readerBox.Padding;
        readerBox.Padding = new Thickness(padding.Left, 0, padding.Right, 0);
        double lineHeight = GetLineHeight(readerBox);
        double available = Math.Max(0, readerBox.ActualHeight
            - readerBox.BorderThickness.Top - readerBox.BorderThickness.Bottom);
        double height = Math.Max(lineHeight, Math.Floor(available / lineHeight) * lineHeight);
        // Resize only the inner viewport, leaving the menu, status bar and outer layout intact.
        viewer.VerticalAlignment = VerticalAlignment.Top;
        if (!double.IsFinite(viewer.Height) || Math.Abs(viewer.Height - height) > LayoutTolerance)
            viewer.Height = height;
        readerBox.UpdateLayout();
        viewer.ScrollToVerticalOffset(SnapOffset(viewer.VerticalOffset, viewer.ScrollableHeight, lineHeight));
    }

    private static double SnapOffset(double offset, double maximum, double lineHeight)
        => Math.Clamp(Math.Round(offset / lineHeight) * lineHeight, 0, Math.Max(0, maximum));

    public static void RestoreAlignedProgress(WpfRichTextBox readerBox, double progress)
    {
        AlignViewport(readerBox);
        ScrollViewer? viewer = FindScrollViewer(readerBox);
        if (viewer is null) return;
        double maximum = Math.Max(0, viewer.ScrollableHeight);
        viewer.ScrollToVerticalOffset(SnapOffset(Math.Clamp(progress, 0, 1) * maximum, maximum, GetLineHeight(readerBox)));
    }

    /// <summary>在发出滚动命令前判断，避免把“本次滚动刚到底”当作再次向下翻章。</summary>
    public static bool IsAtBottom(WpfRichTextBox readerBox)
    {
        ScrollViewer? scrollViewer = FindScrollViewer(readerBox);
        return scrollViewer is { ViewportHeight: > 0 } &&
            scrollViewer.VerticalOffset >= scrollViewer.ScrollableHeight - BottomTolerance;
    }

    public static bool HandleNavigationKey(WpfRichTextBox readerBox, Key key,
        int scrollLines = ReaderSettings.DefaultScrollDistance)
    {
        ScrollViewer? scrollViewer = FindScrollViewer(readerBox);
        if (scrollViewer is null) return false;

        switch (key)
        {
            case Key.Up:
            case Key.VolumeDown:
                ScrollExactLines(readerBox, scrollViewer, -ReaderSettings.NormalizeScrollDistance(scrollLines));
                return true;
            case Key.PageUp:
                scrollViewer.PageUp();
                return true;
            case Key.Down:
            case Key.VolumeUp:
                ScrollExactLines(readerBox, scrollViewer, ReaderSettings.NormalizeScrollDistance(scrollLines));
                return true;
            case Key.PageDown:
                scrollViewer.PageDown();
                return true;
            default:
                return false;
        }
    }

    private static void ScrollExactLines(WpfRichTextBox readerBox, ScrollViewer viewer, int lines)
    {
        double lineHeight = GetLineHeight(readerBox);
        double origin = SnapOffset(viewer.VerticalOffset, viewer.ScrollableHeight, lineHeight);
        viewer.ScrollToVerticalOffset(Math.Clamp(origin + lines * lineHeight, 0, Math.Max(0, viewer.ScrollableHeight)));
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
