using System.Windows;

namespace ReadAI;

public partial class MainWindow
{
    private (double Height, double Top, double ExpandedHeight, double ExpandedTop)? _utilityWindowBounds;

    private void CloseUtilityPanels(bool restoreWindow = true)
    {
        CloseParseRecordsPanelShell();
        ImportBooksPanel.Visibility = Visibility.Collapsed;
        CloseDeviceLinkPanel();
        if (restoreWindow) RestoreUtilityWindowSize();
    }

    private bool OpenUtilityPanel(ReaderView view, FrameworkElement panel)
    {
        if (_isLoading && !_searchOperationActive) return false;
        if (panel.Visibility == Visibility.Visible) return true;
        StopSearchForNavigation();
        CaptureViewPosition();
        SearchOverlay.Close(restoreFocus: false);
        CloseLibraryPanelShell();
        CloseUtilityPanels(restoreWindow: view != ReaderView.DeviceLink);
        _viewNavigation.Navigate(view);
        if (view == ReaderView.ImportBooks) ExpandImportWindow();
        InputPanel.Visibility = ReaderBox.Visibility = SearchResultsPanel.Visibility = Visibility.Collapsed;
        BookSourceSelectorPanel.Visibility = SearchResultsList.Visibility = EmptyText.Visibility = Visibility.Collapsed;
        panel.Visibility = Visibility.Visible;
        UpdateReturnToReadingButton();
        UpdateLibraryActions();
        RunViewTransition();
        return true;
    }

    private void ImportBooksClick(object sender, RoutedEventArgs e) => ShowImportBooksPanel();
    private void ShowImportBooksPanel()
    {
        if (!OpenUtilityPanel(ReaderView.ImportBooks, ImportBooksPanel)) return;
        ImportBooksPanel.Refresh();
        SetStatus("选择本地文件导入，或打开已导入的书籍。");
    }

    private async void ImportBookOpenRequested(object? sender, LibraryBookEntry book) => await OpenLibraryBookAsync(book);

    private void ExpandImportWindow()
    {
        if (!IsLoaded || WindowState != WindowState.Normal) return;
        Rect area = SystemParameters.WorkArea;
        double expandedHeight = Math.Min(340, area.Height);
        if (Height >= expandedHeight) return;
        bool onPrimary = Left >= area.Left && Left < area.Right && Top >= area.Top && Top < area.Bottom;
        double expandedTop = onPrimary ? Math.Min(Top, area.Bottom - expandedHeight) : Top;
        _utilityWindowBounds = (Height, Top, expandedHeight, expandedTop);
        Height = expandedHeight;
        Top = expandedTop;
    }

    private void RestoreUtilityWindowSize()
    {
        if (_utilityWindowBounds is not { } bounds) return;
        _utilityWindowBounds = null;
        if (WindowState != WindowState.Normal || Math.Abs(Height - bounds.ExpandedHeight) > 1) return;
        Height = bounds.Height;
        if (Math.Abs(Top - bounds.ExpandedTop) <= 1) Top = bounds.Top;
    }
}
