using System.Threading;
using System.IO;
using System.Windows;

namespace ReadAI;

public partial class App : System.Windows.Application
{
    private Mutex? _singleInstanceMutex;
    private MainWindow? _mainWindow;
    private bool _ownsMutex;

    public static string DataDirectory { get; private set; } = string.Empty;
    public static ReaderDatabase Database { get; private set; } = null!;
    public static ReadAI.Sync.DeviceLinkService? DeviceLink { get; private set; }
    public static string? DeviceLinkError { get; private set; }

    private void OnStartup(object sender, StartupEventArgs e)
    {
        const string mutexName = "ReadAI-Desktop-Reader-8B6A0E5D";
        _singleInstanceMutex = new Mutex(true, mutexName, out bool createdNew);
        _ownsMutex = createdNew;
        if (!createdNew)
        {
            System.Windows.MessageBox.Show("素若阅读已经在运行中。", "素若阅读", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        try
        {
            DataDirectory = AppPaths.ResolveDataDirectory();
            Database = new ReaderDatabase(AppPaths.DatabasePath);
            Database.Initialize();
            AppThemeService.Current.Initialize(Database.LoadSettings().AppTheme);
        }
        catch (Exception exception)
        {
            string dataDirectory = string.IsNullOrWhiteSpace(DataDirectory)
                ? System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Sorryread")
                : DataDirectory;
            System.Windows.MessageBox.Show(
                $"数据目录或数据文件初始化失败：{exception.Message}\n\n路径：{dataDirectory}",
                "素若阅读", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        try
        {
            DeviceLink = new ReadAI.Sync.DeviceLinkService(Database, Path.Combine(DataDirectory, "DeviceLink"));
        }
        catch (Exception exception) { DeviceLinkError = "设备互联初始化失败：" + exception.Message; }
        _mainWindow = new MainWindow();
        MainWindow = _mainWindow;
        _mainWindow.Show();
    }

    private void OnExit(object sender, ExitEventArgs e)
    {
        try { if (DeviceLink != null) DeviceLink.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
        catch { /* A network shutdown failure must not prevent database and mutex cleanup. */ }
        AppThemeService.Current.Dispose();
        Database?.Dispose();
        if (_ownsMutex)
        {
            _singleInstanceMutex?.ReleaseMutex();
        }
        _singleInstanceMutex?.Dispose();
    }
}
