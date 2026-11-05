using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace ReadAI;

public partial class LibraryBookCard : System.Windows.Controls.UserControl
{
    public static readonly DependencyProperty BookProperty = DependencyProperty.Register(
        nameof(Book),
        typeof(LibraryBookEntry),
        typeof(LibraryBookCard),
        new PropertyMetadata(null));

    public static readonly RoutedEvent OpenRequestedEvent = EventManager.RegisterRoutedEvent(
        nameof(OpenRequested),
        RoutingStrategy.Bubble,
        typeof(RoutedEventHandler),
        typeof(LibraryBookCard));

    public static readonly RoutedEvent DeleteRequestedEvent = EventManager.RegisterRoutedEvent(
        nameof(DeleteRequested),
        RoutingStrategy.Bubble,
        typeof(RoutedEventHandler),
        typeof(LibraryBookCard));

    public LibraryBookEntry? Book
    {
        get => (LibraryBookEntry?)GetValue(BookProperty);
        set => SetValue(BookProperty, value);
    }

    public event RoutedEventHandler OpenRequested
    {
        add => AddHandler(OpenRequestedEvent, value);
        remove => RemoveHandler(OpenRequestedEvent, value);
    }

    public event RoutedEventHandler DeleteRequested
    {
        add => AddHandler(DeleteRequestedEvent, value);
        remove => RemoveHandler(DeleteRequestedEvent, value);
    }

    public LibraryBookCard()
    {
        InitializeComponent();
    }

    private void OpenButtonClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (Book is null) return;
        RaiseEvent(new RoutedEventArgs(OpenRequestedEvent, this));
    }

    private void DeleteButtonClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (Book is null) return;
        RaiseEvent(new RoutedEventArgs(DeleteRequestedEvent, this));
    }

    private void DeleteHoverZoneMouseEnter(object sender, System.Windows.Input.MouseEventArgs e)
        => SetDeleteHover(true);

    private void DeleteHoverZoneMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
        => SetDeleteHover(false);

    private void CardTextSizeChanged(object sender, SizeChangedEventArgs e)
    {
        double width = Math.Max(1, e.NewSize.Width);
        TextFadeStart.Offset = Math.Max(0, 1 - 56 / width);
        TextFadeEnd.Offset = Math.Max(TextFadeStart.Offset, 1 - 18 / width);
    }

    private void SetDeleteHover(bool active)
    {
        TitleText.IsPaused = SourceText.IsPaused = active;
        DeleteButton.IsHitTestVisible = active;
        TimeSpan duration = TimeSpan.FromMilliseconds(160);
        DeleteButton.BeginAnimation(OpacityProperty, new DoubleAnimation(active ? 1 : 0, duration));
        TextFadeEnd.BeginAnimation(GradientStop.ColorProperty,
            new ColorAnimation(active ? Colors.Transparent : Colors.Black, duration));
    }
}
