using System.Windows;
using Button = System.Windows.Controls.Button;
using UserControl = System.Windows.Controls.UserControl;

namespace ReadAI;

public partial class SearchHistoryControl : UserControl
{
    public static readonly DependencyProperty IsManagingProperty = DependencyProperty.Register(
        nameof(IsManaging), typeof(bool), typeof(SearchHistoryControl), new PropertyMetadata(false));
    public static readonly DependencyProperty CanSearchProperty = DependencyProperty.Register(
        nameof(CanSearch), typeof(bool), typeof(SearchHistoryControl), new PropertyMetadata(true));

    public bool IsManaging
    {
        get => (bool)GetValue(IsManagingProperty);
        set => SetValue(IsManagingProperty, value);
    }

    public bool CanSearch
    {
        get => (bool)GetValue(CanSearchProperty);
        set => SetValue(CanSearchProperty, value);
    }

    public string Mode { get; private set; } = SearchHistoryModes.Aggregated;

    public event EventHandler<SearchHistoryEntry>? SearchRequested;
    public event EventHandler<SearchHistoryEntry>? DeleteRequested;
    public event EventHandler? ClearRequested;

    public SearchHistoryControl() => InitializeComponent();

    public void SetEntries(string mode, IReadOnlyList<SearchHistoryEntry> entries)
    {
        SearchHistoryModes.Validate(mode);
        if (Mode != mode || entries.Count == 0) IsManaging = false;
        Mode = mode;
        HistoryTitle.Text = mode == SearchHistoryModes.Aggregated ? "搜索记录 · 聚合" : "搜索记录 · 18mh";
        HistoryItems.ItemsSource = entries;
        Visibility = entries.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ManageClick(object sender, RoutedEventArgs e) => IsManaging = !IsManaging;

    private void KeywordClick(object sender, RoutedEventArgs e)
    {
        if (!IsManaging && CanSearch && sender is Button { Tag: SearchHistoryEntry entry } && entry.Mode == Mode)
        {
            SearchRequested?.Invoke(this, entry);
        }
    }

    private void DeleteClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (IsManaging && sender is Button { Tag: SearchHistoryEntry entry } && entry.Mode == Mode)
        {
            DeleteRequested?.Invoke(this, entry);
        }
    }

    private void ClearClick(object sender, RoutedEventArgs e)
    {
        if (IsManaging) ClearRequested?.Invoke(this, EventArgs.Empty);
    }
}
