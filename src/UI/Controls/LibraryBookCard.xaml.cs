using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

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
        => DeleteButton.Visibility = Visibility.Visible;

    private void DeleteHoverZoneMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
        => DeleteButton.Visibility = Visibility.Collapsed;
}
