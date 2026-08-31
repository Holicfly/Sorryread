using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace ReadAI;

public partial class HistoryWindow : Window
{
    private readonly ReaderDatabase _database;
    private readonly ObservableCollection<HistoryListItem> _items;

    public HistoryEntry? SelectedEntry { get; private set; }

    public HistoryWindow(IReadOnlyList<HistoryEntry> entries, ReaderDatabase database)
    {
        InitializeComponent();
        AppThemeService.Current.ApplyWindowChrome(this);
        _database = database;
        _items = new ObservableCollection<HistoryListItem>(entries.Select(entry => new HistoryListItem(entry)));
        HistoryList.ItemsSource = _items;
        if (_items.Count > 0)
        {
            HistoryList.SelectedIndex = 0;
        }
        else
        {
            HintText.Text = "暂无历史记录";
        }

        RefreshClearHistoryButton();
    }

    private void HistoryListMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (HistoryList.SelectedItem is not HistoryListItem item) return;
        SelectedEntry = item.Entry;
        DialogResult = true;
    }

    private void HistoryItemLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is not ListBoxItem item) return;
        int index = HistoryList.ItemContainerGenerator.IndexFromContainer(item);
        MainWindow.AnimateListItem(item, index);
    }

    private void CopyUrlClick(object sender, RoutedEventArgs e)
    {
        if (HistoryList.SelectedItem is not HistoryListItem item)
        {
            HintText.Text = "请先选择一条历史记录";
            return;
        }

        try
        {
            System.Windows.Clipboard.SetText(item.Entry.Url);
            HintText.Text = "网址已复制到剪贴板";
        }
        catch (Exception exception)
        {
            HintText.Text = $"复制失败：{exception.Message}";
        }
    }

    private void DeleteClick(object sender, RoutedEventArgs e)
    {
        if (HistoryList.SelectedItem is not HistoryListItem item)
        {
            HintText.Text = "请先选择一条历史记录";
            return;
        }

        MessageBoxResult answer = System.Windows.MessageBox.Show(this,
            $"确定删除历史记录“{item.Entry.Title}”？\n已导出的 TXT 文件不会删除。",
            "删除历史记录",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);
        if (answer != MessageBoxResult.Yes) return;

        _database.DeleteHistory(item.Entry.Url);
        _items.Remove(item);
        HintText.Text = _items.Count == 0 ? "暂无历史记录" : "历史记录已删除";
        RefreshClearHistoryButton();
    }

    private async void ClearHistoryClick(object sender, RoutedEventArgs e)
    {
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
            HintText.Text = "没有可清空的历史记录或 TXT 文件";
            RefreshClearHistoryButton();
            return;
        }

        MessageBoxResult answer = System.Windows.MessageBox.Show(this,
            $"确定清空全部历史记录和 TXT 文件？\n\n历史记录：{historyCount} 条\nTXT 文件：{txtFiles.Count} 个\n\n当前阅读内容和设置不会删除，此操作不可撤销。",
            "清空历史记录",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);
        if (answer != MessageBoxResult.Yes) return;

        ClearHistoryButton.IsEnabled = false;
        HintText.Text = "正在清空历史记录和 TXT 文件…";

        int deletedHistoryCount = 0;
        Exception? historyException = null;
        TxtCleanupResult? txtResult = null;
        Exception? txtException = null;

        await Task.Run(() =>
        {
            try
            {
                deletedHistoryCount = _database.ClearHistory();
            }
            catch (Exception exception)
            {
                historyException = exception;
            }

            try
            {
                txtResult = TxtExporter.ClearExportedFiles();
            }
            catch (Exception exception)
            {
                txtException = exception;
            }
        });

        if (historyException is null)
        {
            _items.Clear();
        }

        int deletedTxtCount = txtResult?.DeletedCount ?? 0;
        int failedTxtCount = txtResult?.FailedFiles.Count ?? 0;
        bool completed = historyException is null && txtException is null && failedTxtCount == 0;
        if (completed)
        {
            HintText.Text = $"已清空 {deletedHistoryCount} 条历史记录和 {deletedTxtCount} 个 TXT 文件";
        }
        else
        {
            List<string> errors = [];
            if (historyException is not null)
            {
                errors.Add($"历史记录清空失败：{historyException.Message}");
            }
            if (txtException is not null)
            {
                errors.Add($"TXT 清空失败：{txtException.Message}");
            }
            if (failedTxtCount > 0)
            {
                string failedNames = string.Join("、", txtResult!.FailedFiles.Take(5).Select(Path.GetFileName));
                errors.Add($"{failedTxtCount} 个 TXT 文件未能删除：{failedNames}");
            }

            HintText.Text = $"已删除 {deletedHistoryCount} 条历史记录和 {deletedTxtCount} 个 TXT 文件，部分内容清空失败";
            System.Windows.MessageBox.Show(this,
                string.Join(Environment.NewLine, errors),
                "清空未完全完成",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }

        RefreshClearHistoryButton();
    }

    private void RefreshClearHistoryButton()
    {
        try
        {
            ClearHistoryButton.IsEnabled = _database.GetHistoryCount() > 0 || TxtExporter.GetExportedFiles().Count > 0;
        }
        catch
        {
            ClearHistoryButton.IsEnabled = true;
        }
    }

    private sealed class HistoryListItem
    {
        public HistoryEntry Entry { get; }
        public string Title => Entry.Title;
        public string Url => Entry.Url;
        public string FirstParsedText => ToLocalTimeText(Entry.CreatedUtc);
        public string LastParsedText => ToLocalTimeText(Entry.LastParsedUtc);
        public string ParseCountText => $"{Entry.ParseCount} 次";

        public HistoryListItem(HistoryEntry entry)
        {
            Entry = entry;
        }

        private static string ToLocalTimeText(DateTime value)
            => value.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");
    }
}
