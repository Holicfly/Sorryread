using System.Windows;
using System.Windows.Media;
using System.Windows.Shapes;
using Color = System.Windows.Media.Color;

namespace ReadAI;

public partial class MainWindow
{
    private DeviceLinkWindow? _deviceLinkWindow;
    private void InitializeDeviceLink()
    {
        if (App.DeviceLink == null) return;
        var service = App.DeviceLink;
        service.ConfirmPairingAsync = name => Dispatcher.InvokeAsync(() =>
        {
            if (_allowExit || Dispatcher.HasShutdownStarted) return false;
            var dialog = ThemedConfirmDialog.ForPairing(name);
            dialog.Owner = _deviceLinkWindow is { IsVisible: true } ? _deviceLinkWindow : this;
            return dialog.ShowDialog() == true;
        }).Task;
        service.StateChanged += DeviceLinkStateChanged;
        _database.SyncDataChanged += DeviceLinkDataChanged;
        Loaded += async (_, _) =>
        {
            if (service.Peer == null) return;
            try { await service.StartAsync(); }
            catch (Exception) { UpdateDeviceLinkStatus(); }
        };
        Closed += (_, _) =>
        {
            service.StateChanged -= DeviceLinkStateChanged;
            _database.SyncDataChanged -= DeviceLinkDataChanged;
            _deviceLinkWindow?.Close();
        };
    }

    private void DeviceLinkStateChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(new Action(UpdateDeviceLinkStatus));
    private void DeviceLinkDataChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(new Action(() =>
    {
        if (_libraryPanelActive) RefreshLibraryPanel();
        RefreshParseRecordsIfVisible();
        if (InputPanel.Visibility == Visibility.Visible) RefreshHomePreview();
        // Reader movement is driven only by committed remote advances, not local saves.
    }));
    private ReadAI.Sync.SyncChange? _pendingRemotePosition;
    private bool _applyingRemotePosition;

    private void RemotePositionAdvanced(object? sender, ReadAI.Sync.SyncChange change)
        => Dispatcher.BeginInvoke(new Action(() =>
        {
            if (_currentLibraryBook == null || change.EntityId !=
                ReadAI.Sync.SyncProtocol.BookId(_currentLibraryBook.BookKey) || _allowExit) return;
            _pendingRemotePosition = change;
            _ = ApplyRemotePositionAsync();
        }));

    private async Task ApplyRemotePositionAsync()
    {
        if (_applyingRemotePosition) return;
        _applyingRemotePosition = true;
        UpdateDesktopReading();
        try
        {
            while (_pendingRemotePosition is { } change && !_allowExit)
            {
                if (_isLoading) { await Task.Delay(100); continue; }
                _pendingRemotePosition = null;
                var currentBook = _currentLibraryBook;
                if (currentBook == null || _currentEntry == null || change.EntityId !=
                    ReadAI.Sync.SyncProtocol.BookId(currentBook.BookKey)) continue;
                int index = _chapterCatalog.FindIndex(c => c.Url == _currentUrl);
                var current = new ReadAI.Sync.SyncPayload {
                    ChapterUrl = _currentUrl,
                    Progress = _transparentModeActive && _transparentWindow != null
                        ? _transparentWindow.GetReadingProgress() : GetCurrentReaderProgress(),
                    ChapterIndex = index >= 0 ? index : null,
                    ChapterCount = index >= 0 ? _chapterCatalog.Count : null,
                    BookProgressChapterUrl = index >= 0 ? _currentUrl : null,
                };
                if (!(ReadAI.Sync.SyncProtocol.CompareBookPositions(change.Payload, current) > 0)) continue;
                _progressTimer.Stop();
                if (change.Payload.ChapterUrl == _currentUrl)
                {
                    double progress = change.Payload.Progress;
                    _currentEntry.Progress = progress;
                    _readingReturnProgress = progress;
                    _currentLibraryBook = _database.GetLibraryBook(currentBook.BookKey) ?? currentBook;
                    RestoreProgress(progress);
                    if (_transparentModeActive && _transparentWindow != null)
                        _transparentWindow.ShowArticle(_currentEntry, _settings, GetReadingForeground(), progress);
                    await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ContextIdle);
                }
                else
                {
                    var saved = _database.GetLibraryBook(currentBook.BookKey);
                    if (saved != null) await OpenLibraryBookAsync(saved);
                }
                SetStatus("已同步到另一台设备的最远阅读位置。");
            }
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"应用远端阅读位置失败：{error}");
            SetStatus("最远进度已保存，重新打开书籍可恢复。", isError: true);
        }
        finally
        {
            _applyingRemotePosition = false;
            UpdateDesktopReading();
        }
    }

    private void UpdateDeviceLinkStatus()
    {
        bool connected = App.DeviceLink?.IsConnected == true;
        DeviceLinkStatusMenuItem.Header = connected ? "已连接" : "未连接";
        DeviceLinkStatusMenuItem.Icon = new Ellipse { Width = 8, Height = 8,
            Fill = new SolidColorBrush(connected ? Color.FromRgb(40, 143, 93) : Color.FromRgb(207, 88, 88)) };
        DeviceLinkStatusMenuItem.ToolTip = App.DeviceLink?.Error ?? App.DeviceLinkError ??
            (App.DeviceLink?.Peer is { } peer ? $"已配对：{peer.Name}" : "尚未配对设备");
    }
    private void DeviceLinkSubmenuOpened(object sender, RoutedEventArgs e) => UpdateDeviceLinkStatus();
    private void DeviceLinkStatusClick(object sender, RoutedEventArgs e) => ShowDeviceLink(false);
    private void DeviceLinkQrClick(object sender, RoutedEventArgs e) => ShowDeviceLink(true);
    private void ShowDeviceLink(bool showCode)
    {
        if (App.DeviceLink == null)
        {
            System.Windows.MessageBox.Show(this, App.DeviceLinkError ?? "设备互联尚未初始化。", "设备互联");
            return;
        }
        if (_deviceLinkWindow is { IsVisible: true })
        {
            _deviceLinkWindow.Activate();
            if (showCode) _ = _deviceLinkWindow.DisplayCodeAsync();
            return;
        }
        _deviceLinkWindow = new DeviceLinkWindow(App.DeviceLink, _database, showCode) { Owner = this };
        _deviceLinkWindow.Show();
    }
}
