using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace ReadAI;

public partial class TransparentReaderWindow : Window
{
    private bool _allowClose;
    private double _pendingProgress;

    public event EventHandler? ReturnToNormalRequested;
    public event EventHandler? NextChapterRequested;
    public event EventHandler? PreviousChapterRequested;
    public event EventHandler<double>? ReadingProgressChanged;

    public TransparentReaderWindow()
    {
        InitializeComponent();
    }

    public void ShowArticle(HistoryEntry entry, ReaderSettings settings, System.Windows.Media.Brush foreground, double progress)
    {
        Title = entry.Title;
        TransparentReaderBox.Foreground = foreground;
        TransparentReaderBox.FontFamily = new System.Windows.Media.FontFamily(settings.FontFamily);
        TransparentReaderBox.FontSize = settings.FontSize;
        TransparentReaderBox.Document = ArticleDocumentFactory.Create(entry.Content, settings.FontFamily, settings.FontSize, foreground);
        _pendingProgress = progress;
        if (IsLoaded)
        {
            Dispatcher.BeginInvoke(DispatcherPriority.Render, new Action(() => RestoreProgress(_pendingProgress)));
        }
    }

    public void MatchReaderViewport(Rect viewportScreenBounds)
    {
        void ApplyViewport()
        {
            System.Windows.Point canvasScreenOrigin = TransparentCanvas.PointToScreen(new System.Windows.Point(0, 0));
            DpiScale dpi = VisualTreeHelper.GetDpi(TransparentCanvas);
            double width = Math.Max(1, viewportScreenBounds.Width / dpi.DpiScaleX);
            double height = Math.Max(1, viewportScreenBounds.Height / dpi.DpiScaleY);

            Canvas.SetLeft(TransparentReaderBox, (viewportScreenBounds.Left - canvasScreenOrigin.X) / dpi.DpiScaleX);
            Canvas.SetTop(TransparentReaderBox, (viewportScreenBounds.Top - canvasScreenOrigin.Y) / dpi.DpiScaleY);
            TransparentReaderBox.Width = width;
            TransparentReaderBox.Height = height;
            TransparentReaderBox.UpdateLayout();
            Dispatcher.BeginInvoke(DispatcherPriority.Render, new Action(() => RestoreProgress(_pendingProgress)));
        }

        if (IsLoaded)
        {
            ApplyViewport();
        }
        else
        {
            RoutedEventHandler? loaded = null;
            loaded = (_, _) =>
            {
                Loaded -= loaded;
                ApplyViewport();
            };
            Loaded += loaded;
        }
    }

    public void FocusReader()
    {
        Activate();
        Focus();
        TransparentReaderBox.Focus();
    }

    public double GetReadingProgress()
    {
        ScrollViewer? scrollViewer = FindVisualChild<ScrollViewer>(TransparentReaderBox);
        if (scrollViewer is null) return 0;
        double maximum = Math.Max(0, scrollViewer.ExtentHeight - scrollViewer.ViewportHeight);
        return maximum <= 0 ? 0 : Math.Clamp(scrollViewer.VerticalOffset / maximum, 0, 1);
    }

    public void CloseForShutdown()
    {
        _allowClose = true;
        Close();
    }

    private void RestoreProgress(double progress)
    {
        ScrollViewer? scrollViewer = FindVisualChild<ScrollViewer>(TransparentReaderBox);
        if (scrollViewer is null) return;
        double maximum = Math.Max(0, scrollViewer.ExtentHeight - scrollViewer.ViewportHeight);
        scrollViewer.ScrollToVerticalOffset(Math.Clamp(progress, 0, 1) * maximum);
    }

    private void ReaderScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        ReadingProgressChanged?.Invoke(this, GetReadingProgress());
    }

    private void TransparentWindowPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.F12)
        {
            e.Handled = true;
            ReturnToNormalRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        if (ReaderScrollController.HandleNavigationKey(TransparentReaderBox, e.Key))
        {
            e.Handled = true;
            return;
        }

        if (e.Key == Key.Left)
        {
            e.Handled = true;
            PreviousChapterRequested?.Invoke(this, EventArgs.Empty);
        }
        else if (e.Key == Key.Right)
        {
            e.Handled = true;
            NextChapterRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void TransparentWindowPreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        TransparentReaderBox.Focus();
        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
        }
    }

    private void TransparentWindowPreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (ReaderScrollController.HandleMouseWheel(TransparentReaderBox, e.Delta))
        {
            e.Handled = true;
        }
    }

    private void TransparentWindowClosing(object? sender, CancelEventArgs e)
    {
        if (_allowClose) return;
        e.Cancel = true;
        ReturnToNormalRequested?.Invoke(this, EventArgs.Empty);
    }

    private static T? FindVisualChild<T>(DependencyObject? parent) where T : DependencyObject
    {
        if (parent is null) return null;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(parent, index);
            if (child is T result) return result;
            T? descendant = FindVisualChild<T>(child);
            if (descendant is not null) return descendant;
        }
        return null;
    }
}
