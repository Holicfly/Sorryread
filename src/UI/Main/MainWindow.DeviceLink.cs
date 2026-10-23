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
        // Incoming positions are persisted for the next open; never move the active document.
    }));
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
