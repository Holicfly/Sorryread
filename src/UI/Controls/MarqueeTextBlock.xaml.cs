using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace ReadAI;

public partial class MarqueeTextBlock : System.Windows.Controls.UserControl
{
    private const double ScrollPixelsPerSecond = 28;
    private static readonly TimeSpan HoldDuration = TimeSpan.FromSeconds(1.2);

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
    }

    private static void TextChanged(DependencyObject sender, DependencyPropertyChangedEventArgs e)
        => ((MarqueeTextBlock)sender).QueueAnimationRefresh();

    private void QueueAnimationRefresh()
    {
        if (!IsLoaded) return;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(UpdateAnimation));
    }

    private void UpdateAnimation()
    {
        TextTranslate.BeginAnimation(TranslateTransform.XProperty, null);
        TextTranslate.X = 0;
        if (!IsVisible || ActualWidth <= 0 || string.IsNullOrEmpty(Text)) return;

        TextElement.Measure(new System.Windows.Size(double.PositiveInfinity, Math.Max(ActualHeight, 1)));
        double overflow = TextElement.DesiredSize.Width - ActualWidth;
        if (overflow <= 1) return;

        TimeSpan scrollDuration = TimeSpan.FromSeconds(Math.Max(2, overflow / ScrollPixelsPerSecond));
        TimeSpan reachedEnd = HoldDuration + scrollDuration;
        TimeSpan resetAt = reachedEnd + HoldDuration;
        DoubleAnimationUsingKeyFrames animation = new()
        {
            Duration = new Duration(resetAt + TimeSpan.FromMilliseconds(1)),
            RepeatBehavior = RepeatBehavior.Forever
        };
        animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        animation.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(HoldDuration)));
        animation.KeyFrames.Add(new LinearDoubleKeyFrame(-overflow, KeyTime.FromTimeSpan(reachedEnd)));
        animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(-overflow, KeyTime.FromTimeSpan(resetAt)));
        animation.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(resetAt + TimeSpan.FromMilliseconds(1))));
        TextTranslate.BeginAnimation(
            TranslateTransform.XProperty,
            animation,
            HandoffBehavior.SnapshotAndReplace);
    }
}
