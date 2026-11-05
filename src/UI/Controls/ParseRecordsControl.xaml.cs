using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace ReadAI;

public partial class ParseRecordsControl : System.Windows.Controls.UserControl
{
    private ReaderDatabase? _database;
    private bool _clearing;
    private readonly ObservableCollection<HistoryListItem> _items = [];

    public event EventHandler<HistoryEntry>? OpenRequested;
    public event EventHandler? BackRequested;
    public event EventHandler? RecordsChanged;

    public ParseRecordsControl()
    {
        InitializeComponent();
        HistoryList.ItemsSource = _items;
    }

    public void SetDatabase(ReaderDatabase database) => _database = database;

    public void Refresh()
    {
        if (_database is null || _clearing) return;
        string? selectedUrl = (HistoryList.SelectedItem as HistoryListItem)?.Entry.Url;
        _items.Clear();
        foreach (HistoryEntry entry in _database.GetRecentHistory(500, includeContent: false))
            _items.Add(new HistoryListItem(entry));
        HistoryList.SelectedItem = _items.FirstOrDefault(item => item.Entry.Url == selectedUrl) ?? _items.FirstOrDefault();
        UpdateSummary();
        HintText.Text = _items.Count == 0 ? "暂无解析记录" : "双击记录继续阅读；选择后可复制网址或删除";
    }

    private void BackClick(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);

    private void HistoryListMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (HistoryList.SelectedItem is not HistoryListItem item || _clearing) return;
        // Do not open a selected item when the user double-clicks empty list space.
        if (ItemsControl.ContainerFromElement(HistoryList, e.OriginalSource as DependencyObject) is not ListBoxItem) return;
        HistoryEntry? entry = _database?.GetHistoryByUrl(item.Entry.Url);
        if (entry is not null) OpenRequested?.Invoke(this, entry);
    }

    private void HistoryItemLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is ListBoxItem item)
            MainWindow.AnimateListItem(item, HistoryList.ItemContainerGenerator.IndexFromContainer(item));
    }

    private void CopyUrlClick(object sender, RoutedEventArgs e)
    {
        if (HistoryList.SelectedItem is not HistoryListItem item)
        {
            HintText.Text = "请先选择一条解析记录";
            return;
        }
        try
        {
            System.Windows.Clipboard.SetText(item.Entry.Url);
            HintText.Text = "网址已复制到剪贴板";
        }
        catch (Exception exception) { HintText.Text = $"复制失败：{exception.Message}"; }
    }

    private void DeleteClick(object sender, RoutedEventArgs e)
    {
        if (_database is null || HistoryList.SelectedItem is not HistoryListItem item)
        {
            HintText.Text = "请先选择一条解析记录";
            return;
        }
        if (System.Windows.MessageBox.Show(Window.GetWindow(this),
                $"确定删除解析记录“{item.Entry.Title}”？\n已导出的 TXT 文件不会删除。", "删除解析记录",
                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        try
        {
            _database.DeleteHistory(item.Entry.Url);
            _items.Remove(item);
            UpdateSummary();
            HintText.Text = _items.Count == 0 ? "暂无解析记录" : "解析记录已删除";
            RecordsChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception exception) { HintText.Text = $"删除失败：{exception.Message}"; }
    }

    private async void ClearHistoryClick(object sender, RoutedEventArgs e)
    {
        if (_database is null || _clearing) return;
        int historyCount;
        IReadOnlyList<string> txtFiles;
        try
        {
            historyCount = _database.GetHistoryCount();
            txtFiles = TxtExporter.GetExportedFiles();
        }
        catch (Exception exception)
        {
            HintText.Text = $"无法读取待清空内容：{exception.Message}";
            return;
        }
        if (historyCount == 0 && txtFiles.Count == 0)
        {
            HintText.Text = "没有可清空的解析记录或 TXT 文件";
            UpdateSummary();
            return;
        }
        if (System.Windows.MessageBox.Show(Window.GetWindow(this),
                $"确定清空全部解析记录和 TXT 文件？\n\n解析记录：{historyCount} 条\nTXT 文件：{txtFiles.Count} 个\n\n当前阅读内容和设置不会删除，此操作不可撤销。",
                "清空解析记录", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;

        _clearing = true;
        ActionsPanel.IsEnabled = false;
        HintText.Text = "正在清空解析记录和 TXT 文件…";
        int deletedHistoryCount = 0;
        Exception? historyException = null;
        TxtCleanupResult? txtResult = null;
        Exception? txtException = null;
        await Task.Run(() =>
        {
            try { deletedHistoryCount = _database.ClearHistory(); }
            catch (Exception exception) { historyException = exception; }
            try { txtResult = TxtExporter.ClearExportedFiles(); }
            catch (Exception exception) { txtException = exception; }
        });
        _clearing = false;
        ActionsPanel.IsEnabled = true;
        Refresh();
        int deletedTxtCount = txtResult?.DeletedCount ?? 0;
        int failedTxtCount = txtResult?.FailedFiles.Count ?? 0;
        bool completed = historyException is null && txtException is null && failedTxtCount == 0;
        HintText.Text = $"已清空 {deletedHistoryCount} 条解析记录和 {deletedTxtCount} 个 TXT 文件"
            + (completed ? "" : "，部分内容清空失败");
        if (!completed)
        {
            List<string> errors = [];
            if (historyException is not null) errors.Add($"解析记录清空失败：{historyException.Message}");
            if (txtException is not null) errors.Add($"TXT 清空失败：{txtException.Message}");
            if (failedTxtCount > 0)
                errors.Add($"{failedTxtCount} 个 TXT 文件未能删除：{string.Join("、", txtResult!.FailedFiles.Take(5).Select(Path.GetFileName))}");
            System.Windows.MessageBox.Show(Window.GetWindow(this), string.Join(Environment.NewLine, errors),
                "清空未完全完成", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        RecordsChanged?.Invoke(this, EventArgs.Empty);
    }

    private void UpdateSummary()
    {
        int total = _database?.GetHistoryCount() ?? 0;
        CountText.Text = total > _items.Count ? $"最近 {_items.Count} / 共 {total} 条" : $"{total} 条";
        try { ClearHistoryButton.IsEnabled = total > 0 || TxtExporter.GetExportedFiles().Count > 0; }
        catch { ClearHistoryButton.IsEnabled = true; }
    }

    private sealed class HistoryListItem(HistoryEntry entry)
    {
        public HistoryEntry Entry { get; } = entry;
        public string Title => Entry.Title;
        public string Url => Entry.Url;
        public string FirstParsedText => $"首次解析：{Entry.CreatedUtc.ToLocalTime():yyyy-MM-dd HH:mm:ss}";
        public string LastParsedText => $"上次解析：{Entry.LastParsedUtc.ToLocalTime():yyyy-MM-dd HH:mm:ss}";
        public string ParseCountText => $"{Entry.ParseCount} 次";
    }
}
