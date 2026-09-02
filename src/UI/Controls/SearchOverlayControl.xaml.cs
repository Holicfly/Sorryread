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
    private bool _isClosing;
    private readonly HashSet<MouseButton> _suppressedReleases = [];
    private UIElement? _inputGuardHost;

    public bool IsOpen { get; private set; }
    public string SearchText { get => SearchTextBox.Text; set => SearchTextBox.Text = value; }
    public event EventHandler<string>? SearchRequested;
    public event EventHandler? OpenStateChanged;

    public SearchOverlayControl() => InitializeComponent();

    public void Open(string modeHint, bool animate = true)
    {
        if (!IsOpen) _previousFocus = Keyboard.FocusedElement;
        _transitionVersion++;
        _isClosing = false;
        ReleaseInputGuardIfIdle();
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
        _isClosing = true;
        AttachInputGuard();
        // Keep hit testing for the entire fade; later releases are guarded at the window root.
        if (animate)
        {
            DoubleAnimation fade = new(0, TimeSpan.FromMilliseconds(FadeMilliseconds));
            fade.Completed += (_, _) => CompleteClose(version);
            BeginAnimation(OpacityProperty, fade);
        }
        else
        {
            BeginAnimation(OpacityProperty, null);
            Opacity = 0;
            CompleteClose(version);
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
        _suppressedReleases.Add(e.ChangedButton);
        Close();
    }

    private void CompleteClose(int version)
    {
        if (version != _transitionVersion || IsOpen) return;
        _isClosing = false;
        Visibility = Visibility.Collapsed;
        IsHitTestVisible = false;
        ReleaseInputGuardIfIdle();
    }

    private void AttachInputGuard()
    {
        if (_inputGuardHost is not null) return;
        _inputGuardHost = (UIElement?)Window.GetWindow(this) ?? this;
        _inputGuardHost.AddHandler(PreviewMouseDownEvent, new MouseButtonEventHandler(GuardPreviewMouseDown), true);
        _inputGuardHost.AddHandler(PreviewMouseUpEvent, new MouseButtonEventHandler(GuardPreviewMouseUp), true);
    }

    private void GuardPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (_isClosing)
        {
            // Additional clicks during the fade also own their corresponding release.
            _suppressedReleases.Add(e.ChangedButton);
            e.Handled = true;
        }
        else
        {
            // A new press means a previous release was lost outside this window. Do not eat the new click.
            _suppressedReleases.Remove(e.ChangedButton);
            ReleaseInputGuardIfIdle();
        }
    }

    private void GuardPreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        bool suppress = _suppressedReleases.Remove(e.ChangedButton);
        if (_isClosing || suppress) e.Handled = true;
        ReleaseInputGuardIfIdle();
    }

    private void ReleaseInputGuardIfIdle()
    {
        if (_isClosing || _suppressedReleases.Count > 0 || _inputGuardHost is null) return;
        _inputGuardHost.RemoveHandler(PreviewMouseDownEvent, new MouseButtonEventHandler(GuardPreviewMouseDown));
        _inputGuardHost.RemoveHandler(PreviewMouseUpEvent, new MouseButtonEventHandler(GuardPreviewMouseUp));
        _inputGuardHost = null;
    }

    private void OverlayUnloaded(object sender, RoutedEventArgs e)
    {
        _suppressedReleases.Clear();
        _isClosing = false;
        ReleaseInputGuardIfIdle();
    }

    private void OverlaySizeChanged(object sender, SizeChangedEventArgs e) => ResizeCard();

    private void ResizeCard() => SearchCard.Width = Math.Max(1, ActualWidth * WidthRatio);
}
