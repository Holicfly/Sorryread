using Microsoft.Data.Sqlite;
using System.Windows;

namespace ReadAI;

public partial class MainWindow
{
    private string CurrentSearchHistoryMode => _aggregatedSearchMode
        ? SearchHistoryModes.Aggregated
        : SearchHistoryModes.Legacy18Mh;

    private void RefreshSearchHistory()
    {
        if (!_searchModeActive || _viewNavigation.Current != ReaderView.Home)
        {
            SearchHistoryPanel.Visibility = Visibility.Collapsed;
            return;
        }

        try
        {
            SearchHistoryPanel.SetEntries(CurrentSearchHistoryMode, _database.GetSearchHistory(CurrentSearchHistoryMode));
        }
        catch (SqliteException)
        {
            SearchHistoryPanel.Visibility = Visibility.Collapsed;
            ShowTransientNotice("搜索记录暂时无法读取，不影响继续搜索。", isWarning: true);
        }
    }

    private void RecordSearchHistory(string keyword)
    {
        if (!_settings.SearchHistoryEnabled) return;
        try
        {
            _database.AddSearchHistory(CurrentSearchHistoryMode, keyword);
            SearchHistoryPanel.IsManaging = false;
            RefreshSearchHistory();
        }
        catch (SqliteException)
        {
            // A history write failure must not cancel an otherwise valid network search.
            ShowTransientNotice("本次搜索记录未能保存，不影响继续搜索。", isWarning: true);
        }
    }

    private async void SearchHistorySearchRequested(object? sender, SearchHistoryEntry entry)
    {
        if (_isLoading || !_searchModeActive || entry.Mode != CurrentSearchHistoryMode) return;
        UrlBox.Text = entry.Keyword;
        await SearchFromInputAsync();
    }

    private void SearchHistoryDeleteRequested(object? sender, SearchHistoryEntry entry)
    {
        if (!_searchModeActive || entry.Mode != CurrentSearchHistoryMode) return;
        try
        {
            _database.DeleteSearchHistory(entry.Mode, entry.Keyword);
            RefreshSearchHistory();
        }
        catch (SqliteException)
        {
            ShowTransientNotice("删除搜索记录失败，请稍后重试。", isWarning: true);
        }
    }

    private void SearchHistoryClearRequested(object? sender, EventArgs e)
    {
        if (!_searchModeActive || SearchHistoryPanel.Mode != CurrentSearchHistoryMode) return;
        try
        {
            _database.ClearSearchHistory(CurrentSearchHistoryMode);
            RefreshSearchHistory();
        }
        catch (SqliteException)
        {
            ShowTransientNotice("清空搜索记录失败，请稍后重试。", isWarning: true);
        }
    }

    private void UpdateSearchHistorySettingChecks()
    {
        EnableSearchHistoryMenuItem.IsChecked = _settings.SearchHistoryEnabled;
        DisableSearchHistoryMenuItem.IsChecked = !_settings.SearchHistoryEnabled;
    }

    private void SearchHistorySettingClick(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.MenuItem { Tag: string value } || !bool.TryParse(value, out bool enabled)) return;
        try
        {
            _database.SetSetting("SearchHistoryEnabled", enabled.ToString());
            _settings.SearchHistoryEnabled = enabled;
            SetStatus(enabled ? "已开启搜索记录。" : "已关闭搜索记录，已有记录保留。");
        }
        catch (SqliteException)
        {
            ShowTransientNotice("搜索记录设置保存失败，请稍后重试。", isWarning: true);
        }
        finally
        {
            UpdateSearchHistorySettingChecks();
        }
    }

    private void ClearAllSearchHistoryClick(object sender, RoutedEventArgs e)
    {
        try
        {
            _database.ClearAllSearchHistory();
            RefreshSearchHistory();
            SetStatus("已清除聚合与 18mh 的全部搜索记录。");
        }
        catch (SqliteException)
        {
            ShowTransientNotice("清除搜索记录失败，请稍后重试。", isWarning: true);
        }
    }

}
