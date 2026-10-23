using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using ReadAI;
using ReadAI.Sync;

internal static class WindowFlowProbe
{
    public static async Task RunParentAsync()
    {
        foreach (string theme in new[] { "Dark", "Light" })
        {
            string directory = Path.Combine(Path.GetTempPath(), "sorryread-window-flow-" + Guid.NewGuid().ToString("N"));
            await RunProcessAsync(theme, directory, "flow");
            await RunProcessAsync(theme, directory, "restart");
        }
    }

    private static async Task RunProcessAsync(string theme, string directory, string mode)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (string argument in new[] { "--window-flow-child", theme, directory, mode }) start.ArgumentList.Add(argument);
        using var child = Process.Start(start)!;
        Task<string> output = child.StandardOutput.ReadToEndAsync(), error = child.StandardError.ReadToEndAsync();
        try { await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(40)); }
        catch (TimeoutException)
        {
            child.Kill(entireProcessTree: true); // Only this isolated test process.
            throw new Exception("Window flow timed out: " + theme);
        }
        if (child.ExitCode != 0) throw new Exception("Window flow failed: " + theme + " " + await error + await output);
        Console.WriteLine("PASS real WPF pairing/records/reconnect " + theme + "/" + mode + ": " + (await output).Trim());
    }

    public static void RunChild(string theme, string directory, string mode)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { RunApplication(theme, directory, mode); }
            catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start(); thread.Join();
        if (failure != null) { Console.Error.WriteLine(failure); Environment.ExitCode = 1; }
    }

    private static void RunApplication(string theme, string directory, string mode)
    {
        Directory.CreateDirectory(directory);
        using var database = new ReaderDatabase(Path.Combine(directory, "synthetic.db"));
        database.Initialize();
        var application = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        application.Resources.MergedDictionaries.Add(Theme(theme));
        application.Resources.MergedDictionaries.Add(Theme("Styles"));
        var service = new DeviceLinkService(database, Path.Combine(directory, "identity"), allowLoopback: true);
        typeof(App).GetProperty("Database")!.SetValue(null, database);
        typeof(App).GetProperty("DeviceLink")!.SetValue(null, service);
        var exit = typeof(App).GetMethod("OnExit", BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.DeclaredOnly)!;
        application.Exit += (sender, args) => exit.Invoke(application, [sender, args]);
        Exception? failure = null;
        application.DispatcherUnhandledException += (_, args) =>
        {
            failure = args.Exception;
            args.Handled = true; // Report this test as failed rather than leave an unattended error dialog.
            application.Shutdown(1);
        };
        var owner = new Window { Width = 300, Height = 200, ShowInTaskbar = false, ShowActivated = false,
            WindowStartupLocation = WindowStartupLocation.Manual, Left = -10000, Top = -10000 };
        owner.Loaded += async (_, _) =>
        {
            try
            {
                if (mode == "restart") await ReconnectAsync(owner, database, service, directory);
                else await ExerciseAsync(application, owner, database, service, theme, directory);
            }
            catch (Exception error) { failure = error; }
            finally { application.Shutdown(failure == null ? 0 : 1); }
        };
        application.Run(owner);
        if (failure != null) throw failure;
    }

    private static async Task ExerciseAsync(App application, Window owner, ReaderDatabase database,
        DeviceLinkService service, string theme, string directory)
    {
        var decisions = new Queue<bool>([false, true]);
        service.ConfirmPairingAsync = name => application.Dispatcher.InvokeAsync(() =>
        {
            var dialog = ThemedConfirmDialog.ForPairing(name);
            dialog.Owner = owner;
            dialog.WindowStartupLocation = WindowStartupLocation.Manual;
            dialog.Left = dialog.Top = -10000;
            dialog.ShowActivated = false;
            dialog.ContentRendered += (_, _) => application.Dispatcher.BeginInvoke(new Action(() =>
            {
                Require(dialog.ActualWidth <= 360 && dialog.ActualHeight <= 230, "Pairing dialog is not compact");
                string action = decisions.Dequeue() ? "ConfirmButton" : "CancelButton";
                ((Button)dialog.FindName(action)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            }));
            return dialog.ShowDialog() == true;
        }).Task;
        var offer = await service.CreatePairOfferAsync();
        int cachedPort = service.Port;
        string phone = Guid.NewGuid().ToString("N");
        string credential;
        using (var client = Client(service, offer.CertificateSha256))
        {
            string request = SyncProtocol.Encode(new PairRequest(phone, "测试手机 · Android", offer.Token));
            using var denied = await client.PostAsync("/v1/pair", Json(request));
            Require(!denied.IsSuccessStatusCode && service.Peer == null, "Declined pairing changed the binding");
            using var accepted = await client.PostAsync("/v1/pair", Json(request));
            accepted.EnsureSuccessStatusCode();
            credential = JsonDocument.Parse(await accepted.Content.ReadAsStringAsync()).RootElement.GetProperty("credential").GetString()!;
        }
        Require(decisions.Count == 0 && service.Peer?.DeviceId == phone, "Pairing dialog did not commit the accepted device");
        SeedConflict(database);
        for (int index = 0; index < 205; index++) database.AddSyncLog(true, "合成同步记录 " + index);

        using (var client = Client(service, offer.CertificateSha256, credential))
        using (var cancel = new CancellationTokenSource())
        {
            Task traffic = Task.Run(async () =>
            {
                try
                {
                    while (true)
                    {
                        using var response = await client.PostAsync("/v1/complete", Json("{\"record\":true}"), cancel.Token);
                        response.EnsureSuccessStatusCode();
                        await Task.Delay(20, cancel.Token);
                    }
                }
                catch (OperationCanceledException) when (cancel.IsCancellationRequested) { }
            });
            try
            {
                var window = await OpenAsync(owner, service, database);
                try
                {
                    HoverAndRelease(window);
                    for (int index = 0; index < 5; index++) await RecordsAsync(window);
                    var panel = (StackPanel)window.FindName("DetailsPanel");
                    Require(panel.Children.OfType<Button>().Count() == 2 && panel.Children.Count >= 200,
                        "Records did not display the bounded history and conflicting positions");
                    application.Resources.MergedDictionaries[0] = Theme(theme == "Dark" ? "Light" : "Dark");
                    HoverAndRelease(window);
                    await RecordsAsync(window);
                    panel.Children.OfType<Button>().First().RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    await UntilAsync(() => !panel.Children.OfType<Button>().Any());
                    Require(database.GetSyncSnapshot().Records.All(r => r.Versions.Count == 1), "Conflict resolution was not persisted");
                    // Close while the asynchronous record read is pending, then open again.
                    ((Button)window.FindName("RecordsButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                }
                finally { window.Close(); }
                await Task.Delay(80);
                var reopened = await OpenAsync(owner, service, database);
                try { HoverAndRelease(reopened); await RecordsAsync(reopened); }
                finally { reopened.Close(); }
            }
            finally { cancel.Cancel(); await traffic; }
        }

        await service.DisposeAsync();
        var restarted = new DeviceLinkService(database, Path.Combine(directory, "identity"), allowLoopback: true);
        typeof(App).GetProperty("DeviceLink")!.SetValue(null, restarted);
        Require(restarted.Peer?.DeviceId == phone && !restarted.IsConnected, "Restart did not retain the paired device");
        await restarted.StartAsync();
        Require(restarted.Port == cachedPort, "Desktop restart invalidated the phone's cached endpoint");
        Require(restarted.CertificateSha256 == offer.CertificateSha256, "Restart changed the pinned certificate");
        using (var client = Client(restarted, offer.CertificateSha256, credential))
        using (var hello = await client.GetAsync("/v1/hello"))
        {
            hello.EnsureSuccessStatusCode();
            Require(restarted.IsConnected, "Saved credentials did not restore the connection");
        }
        var restored = await OpenAsync(owner, restarted, database);
        try { HoverAndRelease(restored); await RecordsAsync(restored); }
        finally { restored.Close(); }
        // Simulate the phone retaining its credentials between desktop processes. These are
        // generated test identities in the isolated temporary directory, never user secrets.
        File.WriteAllText(Path.Combine(directory, "synthetic-phone.json"), JsonSerializer.Serialize(new
        { phone, credential, pin = offer.CertificateSha256, port = cachedPort }));
        Console.WriteLine("decline/accept, 200 logs, concurrent sync, conflict resolution, reopen and saved-credential reconnect");
    }

    private static async Task ReconnectAsync(Window owner, ReaderDatabase database, DeviceLinkService service, string directory)
    {
        using var ticket = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "synthetic-phone.json")));
        string phone = ticket.RootElement.GetProperty("phone").GetString()!;
        string pin = ticket.RootElement.GetProperty("pin").GetString()!;
        string credential = ticket.RootElement.GetProperty("credential").GetString()!;
        Require(service.Peer?.DeviceId == phone && !service.IsConnected, "New process lost the paired device");
        Require(database.GetSyncLogs().Count == 200 && database.GetSyncSnapshot().Records.All(r => r.Versions.Count == 1),
            "New process lost records or the resolved position");
        // Open connection details before the phone has reconnected, as in the reported crash.
        var window = await OpenAsync(owner, service, database);
        try
        {
            Require(((TextBlock)window.FindName("StatusText")).Text == "未连接", "Offline status is incorrect");
            HoverAndRelease(window);
            await RecordsAsync(window);
            await service.StartAsync();
            Require(service.Port == ticket.RootElement.GetProperty("port").GetInt32(), "New process changed the cached port");
            Require(service.CertificateSha256 == pin, "New process changed the certificate");
            using var client = Client(service, pin, credential);
            using var hello = await client.GetAsync("/v1/hello");
            hello.EnsureSuccessStatusCode();
            await UntilAsync(() => ((TextBlock)window.FindName("StatusText")).Text == "已连接");
            HoverAndRelease(window);
            await RecordsAsync(window);
        }
        finally { window.Close(); }
        Console.WriteLine("new process retained pairing/data; details before reconnect and records after authenticated reconnect");
    }

    private static async Task<DeviceLinkWindow> OpenAsync(Window owner, DeviceLinkService service, ReaderDatabase database)
    {
        var window = new DeviceLinkWindow(service, database, false) { Owner = owner, ShowInTaskbar = false,
            ShowActivated = false, WindowStartupLocation = WindowStartupLocation.Manual, Left = -10000, Top = -10000 };
        window.Show();
        await UntilAsync(() => window.IsLoaded);
        await Task.Delay(25);
        return window;
    }

    private static async Task RecordsAsync(DeviceLinkWindow window)
    {
        var button = (Button)window.FindName("RecordsButton");
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await UntilAsync(() => button.IsEnabled && ((Border)window.FindName("DetailsCard")).Visibility == Visibility.Visible);
        window.UpdateLayout();
    }

    private static void HoverAndRelease(DeviceLinkWindow window)
    {
        var hover = (DependencyPropertyKey)typeof(UIElement).GetField("IsMouseOverPropertyKey", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null)!;
        var pressed = (DependencyPropertyKey)typeof(System.Windows.Controls.Primitives.ButtonBase)
            .GetField("IsPressedPropertyKey", BindingFlags.Static | BindingFlags.NonPublic)!.GetValue(null)!;
        var button = (Button)window.FindName("ForgetButton");
        foreach (bool down in new[] { false, true, false })
        {
            button.SetValue(hover, true); button.SetValue(pressed, down); window.UpdateLayout();
        }
        button.SetValue(hover, false); window.UpdateLayout();
    }

    private static void SeedConflict(ReaderDatabase database)
    {
        var payload = new SyncPayload { Kind = "book", Title = "合成冲突书籍", SourceId = "test", SourceName = "测试",
            DetailUrl = "https://example.invalid/book", ChapterUrl = "https://example.invalid/chapter",
            ChapterTitle = "测试章节", Progress = .2, UpdatedUtc = DateTime.UtcNow.ToString("O") };
        string entity = "book:" + LibraryBookEntry.CreateBookKey(payload.SourceId, payload.DetailUrl);
        foreach (double progress in new[] { .2, .7 })
        {
            string origin = Guid.NewGuid().ToString("N");
            database.ApplySyncChanges(origin, [new SyncChange(entity, "position", origin, "1", new() { [origin] = "1" }, payload with { Progress = progress })]);
        }
    }

    private static HttpClient Client(DeviceLinkService service, string pin, string? credential = null)
    {
        var client = new HttpClient(new HttpClientHandler { ServerCertificateCustomValidationCallback = (_, cert, _, _) =>
            cert != null && Convert.ToHexString(SHA256.HashData(cert.RawData)).ToLowerInvariant() == pin })
        { BaseAddress = new Uri($"https://127.0.0.1:{service.Port}"), Timeout = TimeSpan.FromSeconds(10) };
        if (credential != null) client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", credential);
        return client;
    }

    private static StringContent Json(string value) => new(value, Encoding.UTF8, "application/json");
    private static ResourceDictionary Theme(string name) => new()
    { Source = new Uri($"pack://application:,,,/素若阅读;component/assets/themes/{name}.xaml") };
    private static void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static async Task UntilAsync(Func<bool> condition)
    {
        var elapsed = Stopwatch.StartNew();
        while (!condition())
        {
            if (elapsed.Elapsed > TimeSpan.FromSeconds(5)) throw new TimeoutException("Window operation did not finish");
            await Task.Delay(10);
        }
    }
}
