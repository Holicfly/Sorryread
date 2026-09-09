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
        Unloaded += (_, _) => TextTranslate.BeginAnimation(TranslateTransform.XProperty, null);
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
        TextTranslate.BeginAnimation(TranslateTransform.XProperty, null);
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
        TextTranslate.BeginAnimation(
            TranslateTransform.XProperty,
            animation,
            HandoffBehavior.SnapshotAndReplace);
    }
}
