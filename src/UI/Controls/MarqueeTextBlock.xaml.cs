using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace ReadAI;

public partial class MarqueeTextBlock : System.Windows.Controls.UserControl
{
    private const double ScrollPixelsPerSecond = 28;
    private bool _refreshPending;
    private AnimationClock? _scrollClock;

    public static readonly DependencyProperty IsPausedProperty = DependencyProperty.Register(
        nameof(IsPaused), typeof(bool), typeof(MarqueeTextBlock),
        new PropertyMetadata(false, (sender, _) => ((MarqueeTextBlock)sender).UpdatePauseState()));

    public bool IsPaused
    {
        get => (bool)GetValue(IsPausedProperty);
        set => SetValue(IsPausedProperty, value);
    }

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text),
        typeof(string),
        typeof(MarqueeTextBlock),
        new PropertyMetadata(string.Empty, TextChanged));

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public MarqueeTextBlock()
    {
        InitializeComponent();
        Loaded += (_, _) => QueueAnimationRefresh();
        SizeChanged += (_, _) => QueueAnimationRefresh();
        IsVisibleChanged += (_, _) => QueueAnimationRefresh();
        Unloaded += (_, _) => StopAnimation();
    }

    protected override void OnPropertyChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.Property == FontFamilyProperty || e.Property == FontSizeProperty
            || e.Property == FontWeightProperty || e.Property == FontStyleProperty)
            QueueAnimationRefresh();
    }

    private static void TextChanged(DependencyObject sender, DependencyPropertyChangedEventArgs e)
        => ((MarqueeTextBlock)sender).QueueAnimationRefresh();

    private void QueueAnimationRefresh()
    {
        if (!IsLoaded || _refreshPending) return;
        _refreshPending = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            _refreshPending = false;
            UpdateAnimation();
        }));
    }

    private void UpdateAnimation()
    {
        StopAnimation();
        TextTranslate.X = 0;
        TextCopy.Visibility = Visibility.Collapsed;
        if (!IsLoaded || !IsVisible || ActualWidth <= 0 || string.IsNullOrEmpty(Text)) return;

        TextElement.Measure(new System.Windows.Size(double.PositiveInfinity, Math.Max(ActualHeight, 1)));
        double textWidth = TextElement.DesiredSize.Width;
        double top = Math.Max(0, (ActualHeight - TextElement.DesiredSize.Height) / 2);
        Canvas.SetTop(TextElement, top);
        Canvas.SetTop(TextCopy, top);
        if (textWidth <= ActualWidth) return;

        // At -textWidth the second copy occupies the first copy's starting position.
        // Repeating the animation is therefore visually identical, with no gap or reset flash.
        Canvas.SetLeft(TextCopy, textWidth);
        TextCopy.Visibility = Visibility.Visible;
        DoubleAnimation animation = new(0, -textWidth, TimeSpan.FromSeconds(textWidth / ScrollPixelsPerSecond))
        {
            RepeatBehavior = RepeatBehavior.Forever
        };
        _scrollClock = (AnimationClock)animation.CreateClock(true);
        TextTranslate.ApplyAnimationClock(TranslateTransform.XProperty, _scrollClock);
        UpdatePauseState();
    }

    private void UpdatePauseState()
    {
        if (IsPaused) _scrollClock?.Controller?.Pause();
        else _scrollClock?.Controller?.Resume();
    }

    private void StopAnimation()
    {
        _scrollClock?.Controller?.Remove();
        _scrollClock = null;
        TextTranslate.ApplyAnimationClock(TranslateTransform.XProperty, null);
    }
}
