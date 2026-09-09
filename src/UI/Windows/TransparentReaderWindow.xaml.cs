using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace ReadAI;

public partial class TransparentReaderWindow : Window
{
    private const int ChapterHintFadeMilliseconds = 150;
    private const int ChapterHintMaximumMilliseconds = 2000;
    private const double ChapterHintWidthRatio = 0.75;
    private const double ChapterHintReferenceWidth = 520;
    private const double ChapterHintReferenceHeight = 180;
    private const double ChapterHintBaseFontSize = 14;
    private const double ChapterHintMinimumFontSize = 9;
    private bool _allowClose;
    private ReaderSettings? _readerSettings;
    private double _requestedViewportHeight;
    private double _pendingProgress;
    private readonly DispatcherTimer _chapterHintTimer = new();
    private string _chapterPositionInfo = string.Empty;
    private bool _f1Held;
    private int _chapterHintVersion;

    public event EventHandler? ReturnToNormalRequested;
    public event EventHandler? NextChapterRequested;
    public event EventHandler? PreviousChapterRequested;
    public event EventHandler<double>? ReadingProgressChanged;

    public TransparentReaderWindow()
    {
        InitializeComponent();
        _chapterHintTimer.Interval = TimeSpan.FromMilliseconds(ChapterHintMaximumMilliseconds);
        _chapterHintTimer.Tick += (_, _) => HideChapterPositionHint();
        Deactivated += (_, _) => ResetChapterPositionHint();
        IsVisibleChanged += (_, _) =>
        {
            if (!IsVisible) ResetChapterPositionHint();
        };
        SizeChanged += (_, _) => UpdateChapterHintSize();
        SizeChanged += (_, _) => ResizeReaderViewport();
    }

    /// <summary>只接受主窗口从当前目录匹配出的序号；无匹配时传入 0 清除提示。</summary>
    public void SetChapterPositionInfo(int position, int total, string? title)
    {
        string info = position > 0 && position <= total
            ? $"当前第 {position}/{total} 章" + (string.IsNullOrWhiteSpace(title) ? string.Empty : $"：{title.Trim()}")
            : string.Empty;
        if (_chapterPositionInfo == info) return;
        HideChapterPositionHint(animate: false);
        _chapterPositionInfo = info;
        ChapterPositionText.Text = info;
        UpdateChapterHintSize();
    }

    private void UpdateChapterHintSize()
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        double scale = Math.Min(1, Math.Min(ActualWidth / ChapterHintReferenceWidth,
            ActualHeight / ChapterHintReferenceHeight));
        double maxWidth = Math.Max(1, ActualWidth * ChapterHintWidthRatio);
        ChapterPositionHint.MaxWidth = maxWidth;
        ChapterPositionHint.Padding = new Thickness(16 * scale, 10 * scale, 16 * scale, 10 * scale);
        ChapterPositionHint.CornerRadius = new CornerRadius(23 * scale);
        double fontSize = Math.Clamp(Math.Floor(ChapterHintBaseFontSize * scale),
            ChapterHintMinimumFontSize, ChapterHintBaseFontSize);
        double textWidth = Math.Max(1, maxWidth - ChapterPositionHint.Padding.Left
            - ChapterPositionHint.Padding.Right - ChapterPositionHint.BorderThickness.Left
            - ChapterPositionHint.BorderThickness.Right);
        // Fit the actual chapter title before falling back to the existing ellipsis.
        while (fontSize > ChapterHintMinimumFontSize)
        {
            FormattedText measured = new(ChapterPositionText.Text,
                System.Globalization.CultureInfo.CurrentUICulture, ChapterPositionText.FlowDirection,
                new Typeface(ChapterPositionText.FontFamily, ChapterPositionText.FontStyle,
                    ChapterPositionText.FontWeight, ChapterPositionText.FontStretch),
                fontSize, ChapterPositionText.Foreground, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            if (measured.WidthIncludingTrailingWhitespace <= textWidth) break;
            fontSize--;
        }
        ChapterPositionText.FontSize = fontSize;
    }

    private void ShowChapterPositionHint()
    {
        if (!IsActive || !IsVisible || _chapterPositionInfo.Length == 0) return;
        _chapterHintVersion++;
        UpdateChapterHintSize();
        ChapterPositionHint.Visibility = Visibility.Visible;
        ChapterPositionHint.BeginAnimation(OpacityProperty,
            new DoubleAnimation(1, TimeSpan.FromMilliseconds(ChapterHintFadeMilliseconds)));
        _chapterHintTimer.Stop();
        _chapterHintTimer.Start();
    }

    private void HideChapterPositionHint(bool animate = true)
    {
        _chapterHintTimer.Stop();
        int version = ++_chapterHintVersion;
        if (!animate || ChapterPositionHint.Visibility != Visibility.Visible)
        {
            ChapterPositionHint.BeginAnimation(OpacityProperty, null);
            ChapterPositionHint.Opacity = 0;
            ChapterPositionHint.Visibility = Visibility.Collapsed;
            return;
        }
        DoubleAnimation fade = new(0, TimeSpan.FromMilliseconds(ChapterHintFadeMilliseconds));
        fade.Completed += (_, _) =>
        {
            if (version == _chapterHintVersion) ChapterPositionHint.Visibility = Visibility.Collapsed;
        };
        ChapterPositionHint.BeginAnimation(OpacityProperty, fade);
    }

    private void ResetChapterPositionHint()
    {
        _f1Held = false;
        HideChapterPositionHint(animate: false);
    }

    public void ShowArticle(HistoryEntry entry, ReaderSettings settings, System.Windows.Media.Brush foreground, double progress)
    {
        // Keep the shared settings reference so changes take effect without resetting reading progress.
        _readerSettings = settings;
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
            _requestedViewportHeight = height;
            ResizeReaderViewport();
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
        ReaderScrollController.RestoreAlignedProgress(TransparentReaderBox, progress);
    }

    public void UpdateReaderFontSize(double fontSize)
        => ReaderScrollController.UpdateFontSize(TransparentReaderBox, fontSize);

    private void ReaderViewportSizeChanged(object sender, SizeChangedEventArgs e)
        => ReaderScrollController.QueueAlignViewport(TransparentReaderBox);

    private void ResizeReaderViewport()
    {
        if (_requestedViewportHeight <= 0) return;
        double top = Canvas.GetTop(TransparentReaderBox);
        double available = Math.Max(1, TransparentCanvas.ActualHeight - (double.IsFinite(top) ? top : 0));
        TransparentReaderBox.Height = Math.Min(_requestedViewportHeight, available);
        ReaderScrollController.QueueAlignViewport(TransparentReaderBox);
    }

    private void ReaderScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        ReadingProgressChanged?.Invoke(this, GetReadingProgress());
    }

    private void TransparentWindowPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.F1)
        {
            e.Handled = true;
            // 超时只隐藏提示，不解除按住状态；必须松开再按，避免自动重复导致粘住。
            if (!_f1Held && !e.IsRepeat)
            {
                _f1Held = true;
                ShowChapterPositionHint();
            }
            return;
        }
        if (e.Key == Key.F12)
        {
            e.Handled = true;
            ReturnToNormalRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        if (TransparentReaderBox.ContextMenu?.IsOpen == true) return;

        if (e.Key is Key.Down or Key.PageDown && ReaderScrollController.IsAtBottom(TransparentReaderBox))
        {
            e.Handled = true;
            // 不再排队 PageDown，防止新章节加载后继承滚动；主窗口负责加载/下一章可用性检查。
            if (!e.IsRepeat) NextChapterRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        if (ReaderScrollController.HandleNavigationKey(TransparentReaderBox, e.Key,
            _readerSettings?.ScrollDistance ?? ReaderSettings.DefaultScrollDistance))
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

    private void TransparentWindowPreviewKeyUp(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != Key.F1) return;
        e.Handled = true;
        _f1Held = false;
        HideChapterPositionHint();
    }

    private void TransparentWindowPreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        TransparentReaderBox.Focus();
        if (e.ClickCount == 2)
        {
            // 在正文处理双击选词前拦截，按整个窗口的中线划分；加载/章节检查由主窗口复用。
            e.Handled = true;
            if (e.GetPosition(this).X < ActualWidth / 2)
                PreviousChapterRequested?.Invoke(this, EventArgs.Empty);
            else
                NextChapterRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        // 正文单击只交给阅读控件处理焦点和选择；空白边缘保留拖动窗口的能力。
        if (TransparentReaderBox.IsMouseOver) return;
        e.Handled = true;
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
        ResetChapterPositionHint();
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
