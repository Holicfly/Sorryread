using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ReadAI;
using ReadAI.Sync;

internal static partial class Program
{
    private static void TestDeviceLinkWindow(string outputDirectory)
    {
        using var database = new ReaderDatabase(Path.Combine(outputDirectory, "device-window-only.db"));
        database.Initialize();
        var service = new DeviceLinkService(database, Path.Combine(outputDirectory, "device-window-identity"));
        var window = new DeviceLinkWindow(service, database, false);
        try
        {
            var guide = new InformationDialog(InformationDialogPage.Guide);
            Check(window.Width < guide.Width - 24 && window.Height < guide.Height - 24,
                "device window: default frame is smaller than the visible usage dialog");
            guide.Close();
            var root = (FrameworkElement)window.Content;
            var qr = (Border)window.FindName("QrCard");
            var device = (Border)window.FindName("DeviceCard");
            var refresh = (Button)window.FindName("RefreshButton");
            var forget = (Button)window.FindName("ForgetButton");
            var records = (Button)window.FindName("RecordsButton");
            var scroll = (ScrollViewer)window.FindName("BodyScroll");
            var hint = (TextBlock)window.FindName("QrHintText");
            var countdown = (TextBlock)window.FindName("QrCountdownText");
            var qrImage = (System.Windows.Controls.Image)window.FindName("QrImage");
            var offer = new PairOffer("sorryread-preview", 1, new string('a', 32), "布局测试",
                ["https://192.0.2.1:12345"], new string('b', 64), new string('c', 64), DateTime.UtcNow.AddMinutes(1).ToString("O"));
            var offerField = typeof(DeviceLinkWindow).GetField("_offer", BindingFlags.Instance | BindingFlags.NonPublic)!;
            var render = typeof(DeviceLinkWindow).GetMethod("RenderStatus", BindingFlags.Instance | BindingFlags.NonPublic)!;
            var code = PairingQrCode.Create(SyncProtocol.Encode(offer));
            qrImage.Source = code.Image;
            offerField.SetValue(window, offer);
            typeof(DeviceLinkWindow).GetField("_codeCells", BindingFlags.Instance | BindingFlags.NonPublic)!
                .SetValue(window, code.GridSize);
            typeof(DeviceLinkWindow).GetMethod("ApplyCodeSize", BindingFlags.Instance | BindingFlags.NonPublic)!
                .Invoke(window, null);
            var paired = new PairedDevice(new string('1', 32), "素若阅读 · Android", "synthetic-not-a-credential");

            Check(code.QuietZone == 4 && code.GridSize % 4 == 1 && code.GridSize >= 73,
                "pairing code: version-sized grid keeps the standard four-module quiet zone");
            Check(code.Image.IsFrozen, "pairing code: frozen drawing can cross from the worker to the UI thread");
            bool[] sampled = SamplePairingCode(code, 8);
            Check(DataModulesMatch(code, sampled),
                "pairing code: every data module keeps its exact cell and quiet zone");
            Check(FinderScansMatch(code, sampled),
                "pairing code: rounded finder patterns keep their 1:1:3:1:1 scan lines");

            foreach (string theme in new[] { "Dark", "Light" })
            {
                System.Windows.Application.Current.Resources.MergedDictionaries[0] = Theme(theme);
                foreach (bool connected in new[] { false, true })
                {
                    render.Invoke(window, [connected ? paired : null, connected]);
                    double width = window.Width, height = window.Height;
                    // The window is never shown, so the test drives layout itself and has to
                    // invalidate the scroll viewer before it picks up a state change.
                    scroll.InvalidateMeasure();
                    root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout();
                    Check(qr.Visibility == (connected ? Visibility.Collapsed : Visibility.Visible) &&
                        device.Visibility == (connected ? Visibility.Visible : Visibility.Collapsed),
                        $"device window {theme}: QR and paired device are mutually exclusive");
                    Check(refresh.Visibility == (connected ? Visibility.Collapsed : Visibility.Visible) &&
                        forget.Visibility == (connected ? Visibility.Visible : Visibility.Collapsed),
                        $"device window {theme}: the correct pairing action is visible");
                    Check(!Descendants<TextBlock>(root).Any(text => text.Text.Contains("同步范围") || text.Text.Contains("不同步：")),
                        $"device window {theme}: sync scope section is removed");
                    double buttonsBottom = records.TranslatePoint(new Point(0, records.ActualHeight), scroll).Y;
                    Check(records.ActualWidth > 120 && buttonsBottom <= scroll.ViewportHeight + 1 &&
                        scroll.ExtentWidth <= scroll.ViewportWidth + 1,
                        $"device window {theme}: compact QR and actions fit without clipping");
                    Check(((SolidColorBrush)((TextBlock)window.FindName("DescriptionText")).Foreground).Color ==
                        ((SolidColorBrush)System.Windows.Application.Current.FindResource("TextSecondaryBrush")).Color,
                        $"device window {theme}: existing window updates its theme");
                    double modulePixels = qrImage.ActualWidth * VisualTreeHelper.GetDpi(qrImage).DpiScaleX / code.GridSize;
                    Check(((SolidColorBrush)qr.Background).Color == Colors.White &&
                        qrImage.ActualWidth is >= 130 and <= 176 &&
                        Math.Abs(modulePixels - Math.Round(modulePixels)) < 0.01 && modulePixels >= 2,
                        $"device window {theme}: pairing code stays white, compact and pixel-snapped");
                    Check(connected
                            ? countdown.Visibility == Visibility.Collapsed &&
                                ((FrameworkElement)window.FindName("QrColumn")).Visibility == Visibility.Collapsed &&
                                device.ActualWidth > width - 40
                            : countdown.Visibility == Visibility.Visible && countdown.Text.Contains("后失效"),
                        $"device window {theme}: validity countdown follows the pairing state");
                    Check(scroll.ComputedVerticalScrollBarVisibility == Visibility.Collapsed,
                        $"device window {theme}: default frame needs no scroll bar");
                    TestLinkButtonStates(root, theme);
                    var preview = new RenderTargetBitmap((int)width, (int)height, 96, 96, PixelFormats.Pbgra32);
                    preview.Render(root);
                    var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(preview));
                    using var file = File.Create(Path.Combine(outputDirectory,
                        $"device-link-{theme.ToLowerInvariant()}-{(connected ? "connected" : "unpaired")}.png"));
                    encoder.Save(file);
                }
            }
            TestPairingConfirmation(outputDirectory);
            TestPairingDpi(service, database, offer, outputDirectory);
            render.Invoke(window, [paired, false]);
            Check(device.Visibility == Visibility.Visible && forget.Visibility == Visibility.Visible && qr.Visibility == Visibility.Collapsed,
                "device window: paired offline retains the device card and unpair action");
            render.Invoke(window, [null, false]);
            offerField.SetValue(window, offer with { ExpiresUtc = DateTime.UtcNow.AddMinutes(-1).ToString("O") });
            render.Invoke(window, [null, false]);
            Check(hint.Visibility == Visibility.Visible && hint.Text.Contains("已过期"),
                "device window: expired QR is hidden and refresh remains available");
            Check(countdown.Text.Length == 0,
                "device window: expired pairing code shows no countdown");
            root.Measure(new Size(380, 220)); root.Arrange(new Rect(0, 0, 380, 220)); root.UpdateLayout();
            Check(scroll.ExtentHeight > scroll.ViewportHeight && scroll.ExtentWidth <= scroll.ViewportWidth + 1,
                "device window: compact layout scrolls vertically without horizontal clipping");
        }
        finally
        {
            window.Close();
            service.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
    }

    private static void TestLinkButtonStates(FrameworkElement root, string theme)
    {
        var mouseOver = (DependencyPropertyKey)typeof(UIElement).GetField("IsMouseOverPropertyKey", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null)!;
        var pressed = (DependencyPropertyKey)typeof(System.Windows.Controls.Primitives.ButtonBase)
            .GetField("IsPressedPropertyKey", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null)!;
        foreach (Button button in Descendants<Button>(root).Where(b => b.IsVisible || b.Visibility == Visibility.Visible))
        {
            button.ApplyTemplate();
            var border = (button.Template.FindName("ActionBorder", button) ?? button.Template.FindName("ButtonBorder", button)) as Border;
            if (border == null) continue;
            foreach (bool enabled in new[] { true, false, true })
                foreach (bool hover in new[] { false, true })
                    foreach (bool down in new[] { false, true })
                    {
                        button.SetValue(mouseOver, hover);
                        button.SetValue(pressed, down);
                        button.IsEnabled = enabled;
                        root.UpdateLayout();
                        Check(border.Background is SolidColorBrush,
                            $"device button {theme}/{button.Name}: background resolves enabled={enabled}, hover={hover}, pressed={down}");
                    }
            button.SetValue(mouseOver, false); button.SetValue(pressed, false);
        }
    }

    private static void TestPairingConfirmation(string outputDirectory)
    {
        foreach (string theme in new[] { "Dark", "Light" })
        {
            System.Windows.Application.Current.Resources.MergedDictionaries[0] = Theme(theme);
            var dialog = ThemedConfirmDialog.ForPairing("素若阅读 · Android");
            try
            {
                var root = (FrameworkElement)dialog.Content;
                root.Measure(new Size(dialog.Width, double.PositiveInfinity));
                double height = Math.Ceiling(root.DesiredSize.Height);
                root.Arrange(new Rect(0, 0, dialog.Width, height)); root.UpdateLayout();
                var confirm = (Button)dialog.FindName("ConfirmButton");
                var cancel = (Button)dialog.FindName("CancelButton");
                Check(dialog.Width == 360 && height <= 230 && dialog.WindowStyle == WindowStyle.None && !dialog.ShowInTaskbar,
                    $"pairing dialog {theme}: compact themed frame replaces the native message box");
                Check((string)confirm.Content == "允许连接" && (string)cancel.Content == "暂不连接" && cancel.IsCancel &&
                    confirm.Style == (Style)dialog.FindResource("AccentButtonStyle"),
                    $"pairing dialog {theme}: clear accept/decline actions with a primary accent");
                Check(((TextBlock)dialog.FindName("MessageText")).Text.Contains("素若阅读 · Android") &&
                    ((TextBlock)dialog.FindName("MessageText")).Text.Contains("全部阅读进度"),
                    $"pairing dialog {theme}: device identity and sync scope remain visible");
                TestLinkButtonStates(root, theme);
                var image = new RenderTargetBitmap(360, (int)height, 96, 96, PixelFormats.Pbgra32);
                image.Render(root);
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
                using var file = File.Create(Path.Combine(outputDirectory, $"pairing-confirm-{theme.ToLowerInvariant()}.png"));
                encoder.Save(file);
            }
            finally { dialog.Close(); }
        }
    }

    private static void TestPairingDpi(DeviceLinkService service, ReaderDatabase database, PairOffer offer, string outputDirectory)
    {
        // .NET 8 exposes this helper internally. It propagates real WPF DPI flags to the
        // unshown visual tree, so padding/borders and layout rounding are exercised too.
        var setDpi = typeof(VisualTreeHelper).GetMethod("SetRootDpi", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public)!;
        foreach (int addresses in new[] { 1, 3 })
        {
            var ticket = offer with { Type = "sorryread-pair", Name = "DESKTOP-PREVIEW", Endpoints = addresses == 1
                ? ["https://192.168.100.123:54321"]
                : ["https://192.168.100.123:54321", "https://172.16.100.123:54321", "https://10.100.100.123:54321"] };
            string payload = SyncProtocol.Encode(ticket);
            var code = PairingQrCode.Create(payload);
            File.WriteAllText(Path.Combine(outputDirectory, $"pairing-{addresses}.json"), payload);
            foreach (double scale in new[] { 1d, 1.25, 1.5, 1.75, 2, 2.5, 3 })
            {
                var preview = new DeviceLinkWindow(service, database, false);
                try
                {
                    setDpi.Invoke(null, [preview, new DpiScale(scale, scale)]);
                    var root = (FrameworkElement)preview.Content;
                    root.Measure(new Size(preview.Width, preview.Height));
                    root.Arrange(new Rect(0, 0, preview.Width, preview.Height)); root.UpdateLayout();
                    setDpi.Invoke(null, [root, new DpiScale(scale, scale)]);
                    foreach (FrameworkElement element in Descendants<FrameworkElement>(root))
                    {
                        element.InvalidateMeasure(); element.InvalidateArrange();
                    }
                    root.InvalidateMeasure(); root.InvalidateArrange();
                    var image = (System.Windows.Controls.Image)preview.FindName("QrImage");
                    image.Source = code.Image;
                    typeof(DeviceLinkWindow).GetField("_offer", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(preview, ticket);
                    typeof(DeviceLinkWindow).GetField("_codeCells", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(preview, code.GridSize);
                    typeof(DeviceLinkWindow).GetMethod("ApplyCodeSize", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(preview, null);
                    typeof(DeviceLinkWindow).GetMethod("RenderStatus", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(preview, [null, false]);
                    root.Measure(new Size(preview.Width, preview.Height));
                    root.Arrange(new Rect(0, 0, preview.Width, preview.Height)); root.UpdateLayout();
                    double module = image.ActualWidth * scale / code.GridSize;
                    Point origin = image.TranslatePoint(new Point(), root);
                    Console.WriteLine($"DPI {scale:P0}, {addresses} addresses: grid={code.GridSize}, module={module:F6}px, origin={origin.X * scale:F6},{origin.Y * scale:F6}");
                    Check(Math.Abs(module - Math.Round(module)) < 0.001 && module >= 2 &&
                        Math.Abs(origin.X * scale - Math.Round(origin.X * scale)) < 0.001 &&
                        Math.Abs(origin.Y * scale - Math.Round(origin.Y * scale)) < 0.001,
                        $"pairing DPI {scale:P0}/{addresses}: actual image size and origin align to device pixels");
                    var bitmap = new RenderTargetBitmap((int)Math.Ceiling(preview.Width * scale),
                        (int)Math.Ceiling(preview.Height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
                    bitmap.Render(root);
                    int pixels = (int)Math.Round(image.ActualWidth * scale);
                    var cropped = new CroppedBitmap(bitmap, new Int32Rect((int)Math.Round(origin.X * scale),
                        (int)Math.Round(origin.Y * scale), pixels, pixels));
                    Check(PairingPixelsMatch(code, cropped, (int)Math.Round(module)),
                        $"pairing DPI {scale:P0}/{addresses}: data pixels match the matrix without grey edges");
                    var qrEncoder = new PngBitmapEncoder(); qrEncoder.Frames.Add(BitmapFrame.Create(cropped));
                    using (var qrFile = File.Create(Path.Combine(outputDirectory, $"code-{addresses}-{scale:0.##}.png")))
                        qrEncoder.Save(qrFile);
                    var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    using var file = File.Create(Path.Combine(outputDirectory, $"pairing-{addresses}-{scale:0.##}.png"));
                    encoder.Save(file);
                }
                finally { preview.Close(); }
            }
        }
    }

    private static bool PairingPixelsMatch(PairingQrCode.Code code, BitmapSource bitmap, int module)
    {
        int pixels = bitmap.PixelWidth;
        var buffer = new byte[pixels * pixels * 4];
        bitmap.CopyPixels(buffer, pixels * 4, 0);
        for (int y = 0; y < pixels; y++)
            for (int x = 0; x < pixels; x++)
            {
                int column = x / module, row = y / module;
                // The rounded white card can tint its outermost quiet-zone corners; only
                // the active symbol's square data modules must be exactly ink or white.
                if (column < code.QuietZone || row < code.QuietZone ||
                    column >= code.GridSize - code.QuietZone || row >= code.GridSize - code.QuietZone ||
                    InFinderPattern(column, row, code)) continue;
                byte expected = code.Has(column, row) ? (byte)0x11 : (byte)0xff;
                int offset = (y * pixels + x) * 4;
                if (buffer[offset] != expected || buffer[offset + 1] != expected || buffer[offset + 2] != expected)
                {
                    Console.WriteLine($"QR pixel mismatch ({x},{y}) cell({column},{row}) expected={expected}, actual={buffer[offset]},{buffer[offset + 1]},{buffer[offset + 2]}");
                    return false;
                }
            }
        return true;
    }

    /// <summary>Rasterises the pairing drawing and samples the centre of every module.</summary>
    private static bool[] SamplePairingCode(PairingQrCode.Code code, int scale)
    {
        int pixels = code.GridSize * scale;
        var visual = new DrawingVisual();
        using (DrawingContext context = visual.RenderOpen())
            context.DrawImage(code.Image, new Rect(0, 0, pixels, pixels));
        var target = new RenderTargetBitmap(pixels, pixels, 96, 96, PixelFormats.Pbgra32);
        target.Render(visual);
        var buffer = new byte[pixels * pixels * 4];
        target.CopyPixels(buffer, pixels * 4, 0);
        var dark = new bool[code.GridSize * code.GridSize];
        for (int row = 0; row < code.GridSize; row++)
            for (int column = 0; column < code.GridSize; column++)
            {
                int offset = ((row * scale + scale / 2) * pixels + column * scale + scale / 2) * 4;
                dark[row * code.GridSize + column] = buffer[offset] < 128;
            }
        return dark;
    }

    private static bool DataModulesMatch(PairingQrCode.Code code, bool[] sampled)
    {
        for (int row = 0; row < code.GridSize; row++)
            for (int column = 0; column < code.GridSize; column++)
                if (!InFinderPattern(column, row, code) &&
                    sampled[row * code.GridSize + column] != code.Has(column, row))
                    return false;
        return true;
    }

    /// <summary>Decoders locate a QR code from the middle row and column of each finder pattern.</summary>
    private static bool FinderScansMatch(PairingQrCode.Code code, bool[] sampled)
    {
        int quiet = code.QuietZone, far = code.GridSize - quiet - 7;
        foreach ((int x, int y) in new[] { (quiet, quiet), (far, quiet), (quiet, far) })
            for (int index = 0; index < 7; index++)
            {
                if (sampled[(y + 3) * code.GridSize + x + index] != code.Has(x + index, y + 3)) return false;
                if (sampled[(y + index) * code.GridSize + x + 3] != code.Has(x + 3, y + index)) return false;
            }
        return true;
    }

    private static bool InFinderPattern(int column, int row, PairingQrCode.Code code)
    {
        int quiet = code.QuietZone, far = code.GridSize - quiet - 7;
        bool Inside(int x, int y) => column >= x && column < x + 7 && row >= y && row < y + 7;
        return Inside(quiet, quiet) || Inside(far, quiet) || Inside(quiet, far);
    }
}
