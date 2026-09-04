using System.IO;
using System.Security;

namespace ReadAI;

public static class AppPaths
{
    private const string InstalledDataDirectoryName = "Data";
    private const string FallbackDataDirectoryName = "Sorryread";
    private const string DatabaseFileName = "sorryread.db";

    public static string ResolveDataDirectory()
    {
        string preferred = Path.Combine(AppContext.BaseDirectory, InstalledDataDirectoryName);
        Exception preferredError;
        try
        {
            EnsureWritableDirectory(preferred);
            return preferred;
        }
        catch (Exception exception) when (IsDirectoryAccessFailure(exception))
        {
            preferredError = exception;
        }

        // 这里只选择回退路径，不复制、合并或移动任何旧数据；迁移只由安装器执行。
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
            throw new IOException($"数据目录不可写：{preferred}；LOCALAPPDATA 也不可用。", preferredError);

        string fallback = Path.Combine(localAppData, FallbackDataDirectoryName);
        try
        {
            EnsureWritableDirectory(fallback);
            return fallback;
        }
        catch (Exception exception) when (IsDirectoryAccessFailure(exception))
        {
            throw new IOException($"数据目录均不可写：{preferred}；{fallback}。",
                new AggregateException(preferredError, exception));
        }
    }

    private static bool IsDirectoryAccessFailure(Exception exception)
        => exception is IOException or UnauthorizedAccessException or SecurityException;

    private static void EnsureWritableDirectory(string directory)
    {
        Directory.CreateDirectory(directory);
        // 创建成功不代表可写：实际创建、写入并关闭自动删除的独占探针，不接触数据库或缓存。
        string probePath = Path.Combine(directory, $".write-probe-{Guid.NewGuid():N}");
        using FileStream probe = new(probePath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            bufferSize: 1, FileOptions.DeleteOnClose);
        probe.WriteByte(0);
        probe.Flush(flushToDisk: true);
    }

    public static string DatabasePath => Path.Combine(App.DataDirectory, DatabaseFileName);
    public static string WebViewDataDirectory => Path.Combine(App.DataDirectory, "WebView2");
    public static string ExportDirectory => Path.Combine(App.DataDirectory, "txt");
    public static string IconPath => Path.Combine(AppContext.BaseDirectory, "app.ico");
}
