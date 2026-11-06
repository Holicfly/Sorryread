using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using ReadAI.Sync;
using Button = System.Windows.Controls.Button;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Point = System.Windows.Point;

namespace ReadAI;

public partial class DeviceLinkControl : System.Windows.Controls.UserControl
{
    private readonly DeviceLinkService? _service;
    private readonly ReaderDatabase _database;
    private readonly string? _initializationError;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private const double PreferredCodeSize = 150;
    private const double QrCardPadding = 5;
    private PairOffer? _offer;
    private string? _windowError;
    private int _codeCells;
    private bool _active, _generating;

    public DeviceLinkControl(DeviceLinkService? service, ReaderDatabase database, string? initializationError = null)
    {
        InitializeComponent();
        _service = service;
        _database = database;
        _initializationError = initializationError;
        _timer.Tick += (_, _) => { RefreshStatus(); RefreshFileStatus(); };
        SizeChanged += (_, args) => ArrangeOverview(args.NewSize.Width);
        Unloaded += (_, _) => Deactivate();
        RefreshStatus();
        RefreshFileStatus();
    }

    public event EventHandler? BackRequested;

    public async void Activate(bool showCode = false)
    {
        bool wasActive = _active;
        _active = true;
        _timer.Start();
        RefreshStatus();
        RefreshFileStatus();
        await Dispatcher.Yield(DispatcherPriority.Background);
        if (_active && _service is not null && (showCode || (!wasActive && _service.Peer is null)))
            await DisplayCodeAsync();
    }

    public void Deactivate()
    {
        if (!_active) return;
        _active = false;
        _timer.Stop();
        _offer = null;
        _service?.ClosePairing();
    }

    internal void RefreshFileStatus()
    {
        var (ready, waiting) = _database.GetLocalBookCounts();
        FileStatusText.Text = waiting == 0 ? $"{ready} 本原文件可同步" : $"{ready} 本已就绪 · {waiting} 本等待接收";
        var (sending, receiving, received) = _service?.GetLocalBookTransfers() ?? default;
        var status = new List<string>();
        if (sending > 0) status.Add($"正在发送 {sending} 个文件");
        if (receiving > 0) status.Add($"{receiving} 个文件已暂存 {received / (1024d * 1024):0.##} MB");
        FileTransferText.Text = status.Count > 0 ? string.Join(" · ", status) :
            waiting > 0 ? "手机连接后可继续传输未完成的文件。" : "支持本地书同步的手机连接后自动传输缺失文件。";
    }

    private void ArrangeOverview(double width)
    {
        bool wide = width >= 474;
        Grid.SetRow(QrColumn, wide ? 0 : 1);
        Grid.SetColumn(QrColumn, wide ? 1 : 0);
        Grid.SetRowSpan(QrColumn, wide ? 3 : 1);
        Grid.SetRow(FileCard, wide ? 1 : 2);
        Grid.SetRow(RecordsCard, wide ? 2 : 3);
        QrColumn.Margin = wide ? new Thickness(12, 0, 0, 0) : new Thickness(0, 10, 0, 0);
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        ApplyCodeSize();
    }

    private void RefreshStatus() => RenderStatus(_service?.Peer, _service?.IsConnected == true);

    private void RenderStatus(PairedDevice? peer, bool connected)
    {
        bool paired = peer != null;
        StatusText.Text = connected ? "已连接" : "未连接";
        string color = connected ? "SuccessBrush" : "ErrorBrush";
        StatusText.SetResourceReference(TextBlock.ForegroundProperty, color);
        StatusDot.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, color);
        StatusDot.Fill = System.Windows.Media.Brushes.Transparent;
        DeviceCard.Visibility = paired ? Visibility.Visible : Visibility.Collapsed;
        QrColumn.Visibility = paired || _service is null ? Visibility.Collapsed : Visibility.Visible;
        QrCard.Visibility = paired ? Visibility.Collapsed : Visibility.Visible;
        QrCountdownText.Visibility = paired ? Visibility.Collapsed : Visibility.Visible;
        ForgetButton.Visibility = paired ? Visibility.Visible : Visibility.Collapsed;
        RefreshButton.Visibility = paired ? Visibility.Collapsed : Visibility.Visible;
        RefreshButton.IsEnabled = !_generating && _service is not null;

        if (paired)
        {
            DeviceNameText.Text = "已配对设备：" + peer!.Name;
            DescriptionText.Text = connected
                ? "已与手机端建立配对，阅读数据将在局域网内自动同步。"
                : "已与手机端配对，正在等待手机在同一局域网内连接。";
        }
        else
        {
            bool valid = _offer != null && ExpiresAt(_offer) > DateTime.UtcNow;
            QrBackground.Visibility = valid ? Visibility.Visible : Visibility.Collapsed;
            QrHintText.Visibility = valid ? Visibility.Collapsed : Visibility.Visible;
            QrHintText.Text = _generating ? "正在生成配对二维码…" :
                _offer == null ? "点击下方按钮生成配对二维码" : "二维码已过期，请刷新后重新扫描";
            QrCountdownText.Text = valid ? RemainingText() : string.Empty;
            DescriptionText.Text = "在手机上打开设备互联，扫描二维码，再在电脑上确认连接。";
        }

        ErrorText.Text = string.Join("\n", new[] { _windowError, _service?.Error, _initializationError }
            .Where(s => !string.IsNullOrWhiteSpace(s)).Distinct());
        ErrorText.Visibility = ErrorText.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private static DateTime ExpiresAt(PairOffer offer) => DateTime.TryParse(offer.ExpiresUtc,
        CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out DateTime expires)
        ? expires.ToUniversalTime() : DateTime.MinValue;

    // Both the module size and its origin must land on device pixels. WPF can round padding
    // and border thickness differently at fractional DPI, so size the image independently
    // and calculate the surrounding chrome in the same pixel coordinate system.
    private void ApplyCodeSize()
    {
        if (_codeCells <= 0) return;
        double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        int perModule = Math.Max(2, (int)Math.Round(PreferredCodeSize * scale / _codeCells));
        double codeSize = _codeCells * perModule / scale;
        double border = Math.Max(1, Math.Round(scale)) / scale;
        double padding = Math.Round(QrCardPadding * scale) / scale;
        QrCard.BorderThickness = new Thickness(border);
        QrCard.Padding = new Thickness(padding);
        QrImage.Width = QrImage.Height = codeSize;
        QrHost.Width = QrHost.Height = codeSize + 2 * (border + padding);
    }

    private string RemainingText()
    {
        TimeSpan remaining = ExpiresAt(_offer!) - DateTime.UtcNow;
        if (remaining <= TimeSpan.Zero) return "二维码已失效";
        int seconds = Math.Max(1, (int)Math.Ceiling(remaining.TotalSeconds));
        return $"{(seconds / 60):00}:{(seconds % 60):00} 后失效";
    }

    internal async Task DisplayCodeAsync()
    {
        if (_generating || !_active || _service is null) return;
        _generating = true;
        _windowError = null;
        RefreshStatus();
        try
        {
            if (_service.Peer != null) return;
            var (offer, code) = await Task.Run(async () =>
            {
                var nextOffer = await _service.CreatePairOfferAsync().ConfigureAwait(false);
                if (nextOffer.Endpoints.Count == 0)
                    throw new InvalidOperationException("未找到可用的局域网地址，请先连接 Wi-Fi、网线或热点。");
                return (nextOffer, PairingQrCode.Create(SyncProtocol.Encode(nextOffer)));
            });
            if (!_active) { _service.ClosePairing(); return; }
            _offer = offer;
            _codeCells = code.GridSize;
            QrImage.Source = code.Image;
            ApplyCodeSize();
        }
        catch (Exception error)
        {
            _offer = null;
            _service.ClosePairing();
            _windowError = error.Message;
        }
        finally
        {
            _generating = false;
            if (_active) RefreshStatus();
        }
    }

    private async void RefreshClick(object sender, RoutedEventArgs e) => await DisplayCodeAsync();

    private async void ForgetClick(object sender, RoutedEventArgs e)
    {
        if (_service is null || Window.GetWindow(this) is not { } owner ||
            !ThemedConfirmDialog.Show(owner, "解除当前配对", "解除配对后可连接新手机。两端已有阅读数据将保留。", "解除配对")) return;
        try
        {
            _service.ForgetPeer();
            _offer = null;
            DetailsCard.Visibility = Visibility.Collapsed;
            await DisplayCodeAsync();
        }
        catch
        {
            _windowError = "解除配对失败，请重试。";
            RefreshStatus();
        }
    }

    private async void RecordsClick(object sender, RoutedEventArgs e)
    {
        RecordsButton.IsEnabled = false;
        try
        {
            await RefreshDetailsAsync();
            if (!_active) return;
            DetailsCard.Visibility = Visibility.Visible;
            UpdateLayout();
            double top = DetailsCard.TransformToAncestor(BodyScroll).Transform(new Point()).Y;
            BodyScroll.ScrollToVerticalOffset(BodyScroll.VerticalOffset + top - 16);
        }
        catch
        {
            _windowError = "同步记录暂时无法加载，请重试。";
            RefreshStatus();
        }
        finally { RecordsButton.IsEnabled = true; }
    }

    private async Task RefreshDetailsAsync()
    {
        var (logs, conflicts) = await Task.Run(() => (_database.GetSyncLogs(),
            _database.GetSyncSnapshot().Records.Where(r => r.HasPositionConflict).Take(50).ToList()));
        if (!_active) return;
        DetailsPanel.Children.Clear();
        foreach (var conflict in conflicts)
        {
            AddDetailText("进度冲突：" + conflict.Positions[0].Payload.Title, heading: true);
            foreach (var choice in conflict.Positions)
            {
                var button = new Button
                {
                    Content = new TextBlock
                    {
                        Text = $"{(choice.Origin == _database.SyncDeviceId ? "此电脑" : "其他设备")}：{choice.Payload.ChapterTitle} · {choice.Payload.Progress:P0} · 选择此位置",
                        TextWrapping = TextWrapping.Wrap
                    },
                    Style = (Style)FindResource("LinkActionButton"),
                    FontSize = 14,
                    Margin = new Thickness(0, 6, 0, 6),
                    HorizontalContentAlignment = HorizontalAlignment.Left
                };
                button.Click += async (_, _) =>
                {
                    try { _database.ResolveSyncPosition(conflict.EntityId, choice.Origin, choice.Seq); await RefreshDetailsAsync(); }
                    catch { System.Windows.MessageBox.Show(Window.GetWindow(this), "候选位置已更新，请重新加载后选择。", "选择阅读位置"); }
                };
                DetailsPanel.Children.Add(button);
            }
        }
        AddDetailText("同步记录", heading: true);
        if (logs.Count == 0) AddDetailText("暂无同步记录");
        foreach (var entry in logs.Take(200))
            AddDetailText($"{DateTime.Parse(entry.TimeUtc).ToLocalTime():MM-dd HH:mm:ss} · {entry.Message}");
    }

    private void AddDetailText(string text, bool heading = false)
    {
        var block = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            FontSize = heading ? 16 : 14,
            FontWeight = heading ? FontWeights.SemiBold : FontWeights.Normal,
            Margin = new Thickness(0, heading ? 10 : 6, 0, 6)
        };
        block.SetResourceReference(TextBlock.ForegroundProperty, heading ? "TextPrimaryBrush" : "TextSecondaryBrush");
        DetailsPanel.Children.Add(block);
    }

    private void BackClick(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);
}
