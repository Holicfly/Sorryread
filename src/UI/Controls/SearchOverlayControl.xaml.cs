using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using UserControl = System.Windows.Controls.UserControl;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace ReadAI;

public partial class SearchOverlayControl : UserControl
{
    private const int FadeMilliseconds = 150;
    private const double WidthRatio = 0.68;
    private int _transitionVersion;
    private IInputElement? _previousFocus;

    public bool IsOpen { get; private set; }
    public string SearchText { get => SearchTextBox.Text; set => SearchTextBox.Text = value; }
    public event EventHandler<string>? SearchRequested;
    public event EventHandler? OpenStateChanged;

    public SearchOverlayControl() => InitializeComponent();

    public void Open(string modeHint, bool animate = true)
    {
        if (!IsOpen) _previousFocus = Keyboard.FocusedElement;
        _transitionVersion++;
        IsOpen = true;
        Visibility = Visibility.Visible;
        IsHitTestVisible = true;
        ModeHintText.Text = modeHint;
        ModeHintText.SetResourceReference(System.Windows.Controls.TextBlock.ForegroundProperty, "TextSecondaryBrush");
        ResizeCard();
        if (animate)
            BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(FadeMilliseconds)));
        else
        {
            BeginAnimation(OpacityProperty, null);
            Opacity = 1;
        }
        OpenStateChanged?.Invoke(this, EventArgs.Empty);
        Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() =>
        {
            if (!IsOpen) return;
            SearchTextBox.Focus();
            Keyboard.Focus(SearchTextBox);
            SearchTextBox.CaretIndex = SearchTextBox.Text.Length;
        }));
    }

    public void Close(bool animate = true, bool restoreFocus = true)
    {
        if (!IsOpen) return;
        int version = ++_transitionVersion;
        IsOpen = false;
        IsHitTestVisible = false;
        if (animate)
        {
            DoubleAnimation fade = new(0, TimeSpan.FromMilliseconds(FadeMilliseconds));
            fade.Completed += (_, _) =>
            {
                if (version == _transitionVersion && !IsOpen) Visibility = Visibility.Collapsed;
            };
            BeginAnimation(OpacityProperty, fade);
        }
        else
        {
            BeginAnimation(OpacityProperty, null);
            Opacity = 0;
            Visibility = Visibility.Collapsed;
        }
        if (restoreFocus && _previousFocus is UIElement { IsVisible: true, IsEnabled: true } previous)
            Keyboard.Focus(previous);
        OpenStateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void ShowError(string message)
    {
        ModeHintText.Text = message;
        ModeHintText.SetResourceReference(System.Windows.Controls.TextBlock.ForegroundProperty, "ErrorBrush");
        SearchTextBox.Focus();
    }

    private void SubmitClick(object sender, RoutedEventArgs e) => Submit();

    private void Submit()
    {
        if (!IsOpen) return;
        string keyword = SearchText.Trim();
        if (keyword.Length == 0)
        {
            ShowError("请输入书名、作者或关键词");
            return;
        }
        SearchRequested?.Invoke(this, keyword);
    }

    private void OverlayPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { e.Handled = true; Close(); }
        else if (e.Key == Key.Enter) { e.Handled = true; Submit(); }
    }

    private void BackdropMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        Close();
    }

    private void OverlaySizeChanged(object sender, SizeChangedEventArgs e) => ResizeCard();

    private void ResizeCard() => SearchCard.Width = Math.Max(1, ActualWidth * WidthRatio);
}
