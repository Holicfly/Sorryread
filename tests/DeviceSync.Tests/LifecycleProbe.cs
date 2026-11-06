using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using ReadAI;
using ReadAI.Sync;

internal static class LifecycleProbe
{
    public static async Task RunParentAsync()
    {
        string mutexName = "Sorryread.Sync.Lifecycle.Tests." + Guid.NewGuid().ToString("N");
        string root = Path.Combine(Path.GetTempPath(), "sorryread-sync-lifecycle-" + Guid.NewGuid().ToString("N"));
        foreach (string mode in new[] { "ready", "starting", "pending", "mdns", "ready" })
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!)
            {
                UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            foreach (string argument in new[] { "--lifecycle-child", mode, mutexName, Path.Combine(root, Guid.NewGuid().ToString("N")) })
                start.ArgumentList.Add(argument);
            using var child = Process.Start(start)!;
            Task<string> output = child.StandardOutput.ReadToEndAsync(), error = child.StandardError.ReadToEndAsync();
            try { await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(25)); }
            catch (TimeoutException)
            {
                child.Kill(entireProcessTree: true); // Only this isolated test child, never the user's application.
                throw new Exception("Device popup shutdown left a process running: " + mode);
            }
            if (child.ExitCode != 0) throw new Exception("Lifecycle failed: " + mode + " " + await error + await output);
            using var mutex = new Mutex(false, mutexName);
            if (!mutex.WaitOne(0)) throw new Exception("Shutdown retained its single-instance mutex");
            mutex.ReleaseMutex();
            Console.WriteLine("PASS real WPF Application.Exit, process exit and mutex reuse: " + mode + " " + (await output).Trim());
        }
        await WindowFlowProbe.RunParentAsync();
    }

    public static void RunChild(string mode, string mutexName, string directory)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { RunApplication(mode, mutexName, directory); }
            catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure != null) { Console.Error.WriteLine(failure); Environment.ExitCode = 1; }
    }

    private static void RunApplication(string mode, string mutexName, string directory)
    {
        Directory.CreateDirectory(directory);
        using var database = new ReaderDatabase(Path.Combine(directory, "synthetic.db"));
        database.Initialize();
        var service = new DeviceLinkService(database, Path.Combine(directory, "identity"), allowLoopback: mode != "mdns");
        using var mutex = new Mutex(true, mutexName, out bool created);
        if (!created) throw new Exception("Previous instance still owns the test mutex");
        // Initialize the real application without its production Startup handler or user database.
        var application = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        foreach (string name in new[] { "Light", "Styles" })
            application.Resources.MergedDictionaries.Add(new ResourceDictionary
            { Source = new Uri($"pack://application:,,,/素若阅读;component/assets/themes/{name}.xaml") });
        typeof(App).GetProperty("Database")!.SetValue(null, database);
        typeof(App).GetProperty("DeviceLink")!.SetValue(null, service);
        typeof(App).GetField("_singleInstanceMutex", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(application, mutex);
        typeof(App).GetField("_ownsMutex", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(application, true);
        var exit = typeof(App).GetMethod("OnExit", BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.DeclaredOnly)!;
        application.Exit += (sender, args) => exit.Invoke(application, [sender, args]);
        var elapsed = Stopwatch.StartNew();
        var window = new DeviceLinkProbeWindow(service, database, true)
        {
            ShowInTaskbar = false, ShowActivated = false,
            WindowStartupLocation = WindowStartupLocation.Manual, Left = -10000, Top = -10000
        };
        var confirmationEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var holdConfirmation = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        service.ConfirmPairingAsync = _ => { confirmationEntered.TrySetResult(); return holdConfirmation.Task; };
        HttpClient? client = null;
        Task? pendingPair = null;
        int ticks = 0;
        long paintMilliseconds = -1;
        bool requesting = false;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(15) };
        window.ContentRendered += (_, _) => paintMilliseconds = elapsed.ElapsedMilliseconds;
        window.Loaded += (_, _) =>
        {
            if (mode == "starting")
            {
                // Deliberately race server initialization with the real Exit callback.
                _ = StartIgnoringShutdownAsync(service);
                application.Dispatcher.BeginInvoke(new Action(application.Shutdown), DispatcherPriority.Background);
            }
            else timer.Start();
        };
        timer.Tick += async (_, _) =>
        {
            ticks++;
            if (requesting || ((System.Windows.Controls.Image)window.FindName("QrImage")).Source == null) return;
            requesting = true;
            if (mode == "pending")
            {
                var offer = await service.CreatePairOfferAsync();
                client = new HttpClient(new HttpClientHandler
                { ServerCertificateCustomValidationCallback = (_, cert, _, _) => cert != null &&
                    Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(cert.RawData)).ToLowerInvariant() == offer.CertificateSha256 })
                { BaseAddress = new Uri($"https://127.0.0.1:{service.Port}") };
                pendingPair = client.PostAsync("/v1/pair", new StringContent(SyncProtocol.Encode(
                    new PairRequest(Guid.NewGuid().ToString("N"), "Pending test phone", offer.Token)), Encoding.UTF8, "application/json"));
                await confirmationEntered.Task.WaitAsync(TimeSpan.FromSeconds(8));
            }
            timer.Stop();
            application.Shutdown();
        };
        application.Run(window);
        timer.Stop();
        client?.Dispose();
        if (pendingPair != null) _ = pendingPair.ContinueWith(task => _ = task.Exception, TaskContinuationOptions.OnlyOnFaulted);
        Console.WriteLine($"paint={paintMilliseconds}ms, heartbeat={ticks}, shutdown returned");
    }

    private static async Task StartIgnoringShutdownAsync(DeviceLinkService service)
    {
        try { await service.StartAsync().ConfigureAwait(false); }
        catch (ObjectDisposedException) { }
    }
}
