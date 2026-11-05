using System.Windows;

namespace ReadAI;

public partial class MainWindow
{
    private bool _parseRecordsActive;

    private void OpenParseRecordsClick(object sender, RoutedEventArgs e) => ShowParseRecordsPanel();

    private void ShowParseRecordsPanel()
    {
        if (_parseRecordsActive || (_isLoading && !_searchOperationActive)) return;
        StopSearchForNavigation();
        CaptureViewPosition();
        CloseLibraryPanelShell();
        _viewNavigation.Navigate(ReaderView.ParseRecords);
        _parseRecordsActive = true;
        InputPanel.Visibility = ReaderBox.Visibility = SearchResultsPanel.Visibility = Visibility.Collapsed;
        BookSourceSelectorPanel.Visibility = SearchResultsList.Visibility = EmptyText.Visibility = Visibility.Collapsed;
        ParseRecordsPanel.Refresh();
        ParseRecordsPanel.Visibility = Visibility.Visible;
        UpdateStatusNavigationButtons();
        UpdateReturnToReadingButton();
        UpdateLibraryActions();
        RunViewTransition();
        SetStatus("解析记录：双击继续阅读，或选择记录进行管理。");
    }

    private void CloseParseRecordsPanelShell()
    {
        _parseRecordsActive = false;
        ParseRecordsPanel.Visibility = Visibility.Collapsed;
    }

    private void RefreshParseRecordsIfVisible()
    {
        if (_parseRecordsActive) ParseRecordsPanel.Refresh();
    }

    private async void ParseRecordOpenRequested(object? sender, HistoryEntry entry)
        => await OpenHistoryEntryAsync(entry);

    private void ParseRecordsBackRequested(object? sender, EventArgs e) => NavigateBack();

    private void ParseRecordsChanged(object? sender, EventArgs e) => RefreshHomePreview();
}
