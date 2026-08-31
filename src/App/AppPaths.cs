using System.IO;

namespace ReadAI;

public static class AppPaths
{
    private const string DataDirectoryName = "Sorryread";
    private const string DatabaseFileName = "sorryread.db";
    private const string LegacyDatabaseFileName = "readai.db";
    private const string LegacyProgramDataDirectoryName = "UserData";
    private const string LegacyFallbackDataDirectoryName = "ReadAI";

    public static string ResolveDataDirectory()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("Windows local application data directory is unavailable.");
        }

        string dataDirectory = Path.Combine(localAppData, DataDirectoryName);
        Directory.CreateDirectory(dataDirectory);
        MigrateLegacyDataIfNeeded(dataDirectory, localAppData);

        return dataDirectory;
    }

    public static string DatabasePath => Path.Combine(App.DataDirectory, DatabaseFileName);
    public static string WebViewDataDirectory => Path.Combine(App.DataDirectory, "WebView2");
    public static string ExportDirectory => Path.Combine(App.DataDirectory, "txt");

    private static void MigrateLegacyDataIfNeeded(string destinationDirectory, string localAppData)
    {
        string destinationDatabase = Path.Combine(destinationDirectory, DatabaseFileName);
        if (File.Exists(destinationDatabase))
        {
            return;
        }

        string? sourceDirectory = FindLegacyDataDirectory(localAppData);
        if (sourceDirectory is null)
        {
            return;
        }

        CopyDirectoryIfExists(
            Path.Combine(sourceDirectory, "WebView2"),
            Path.Combine(destinationDirectory, "WebView2"));
        CopyDirectoryIfExists(
            Path.Combine(sourceDirectory, "txt"),
            Path.Combine(destinationDirectory, "txt"));

        string sourceDatabaseName = File.Exists(Path.Combine(sourceDirectory, DatabaseFileName))
            ? DatabaseFileName
            : LegacyDatabaseFileName;
        CopyFileIfExists(
            Path.Combine(sourceDirectory, sourceDatabaseName + "-shm"),
            destinationDatabase + "-shm");
        CopyFileIfExists(
            Path.Combine(sourceDirectory, sourceDatabaseName + "-wal"),
            destinationDatabase + "-wal");
        CopyFileIfExists(
            Path.Combine(sourceDirectory, sourceDatabaseName),
            destinationDatabase);
    }

    private static string? FindLegacyDataDirectory(string localAppData)
    {
        string[] candidates =
        [
            Path.Combine(AppContext.BaseDirectory, LegacyProgramDataDirectoryName),
            Path.Combine(localAppData, LegacyFallbackDataDirectoryName)
        ];

        string? selectedDirectory = null;
        DateTime selectedDatabaseTimestamp = DateTime.MinValue;
        foreach (string candidate in candidates)
        {
            string currentDatabase = Path.Combine(candidate, DatabaseFileName);
            string legacyDatabase = Path.Combine(candidate, LegacyDatabaseFileName);
            string? databasePath = File.Exists(currentDatabase)
                ? currentDatabase
                : File.Exists(legacyDatabase) ? legacyDatabase : null;
            if (databasePath is null)
            {
                continue;
            }

            DateTime databaseTimestamp = File.GetLastWriteTimeUtc(databasePath);
            if (selectedDirectory is null || databaseTimestamp > selectedDatabaseTimestamp)
            {
                selectedDirectory = candidate;
                selectedDatabaseTimestamp = databaseTimestamp;
            }
        }

        return selectedDirectory;
    }

    private static void CopyDirectoryIfExists(string sourceDirectory, string destinationDirectory)
    {
        if (!Directory.Exists(sourceDirectory))
        {
            return;
        }

        Directory.CreateDirectory(destinationDirectory);
        foreach (string sourceSubdirectory in Directory.EnumerateDirectories(
                     sourceDirectory, "*", SearchOption.AllDirectories))
        {
            string relativePath = Path.GetRelativePath(sourceDirectory, sourceSubdirectory);
            Directory.CreateDirectory(Path.Combine(destinationDirectory, relativePath));
        }

        foreach (string sourceFile in Directory.EnumerateFiles(
                     sourceDirectory, "*", SearchOption.AllDirectories))
        {
            string relativePath = Path.GetRelativePath(sourceDirectory, sourceFile);
            string destinationFile = Path.Combine(destinationDirectory, relativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(destinationFile)!);
            if (!File.Exists(destinationFile))
            {
                File.Copy(sourceFile, destinationFile, overwrite: false);
            }
        }
    }

    private static void CopyFileIfExists(string sourceFile, string destinationFile)
    {
        if (File.Exists(sourceFile))
        {
            File.Copy(sourceFile, destinationFile, overwrite: true);
        }
    }

    public static string IconPath => Path.Combine(AppContext.BaseDirectory, "app.ico");
}
