using System.Text;
using System.IO;

namespace ReadAI;

public static class TxtExporter
{
    public static string Export(HistoryEntry entry)
    {
        Directory.CreateDirectory(AppPaths.ExportDirectory);
        string fileName = SanitizeFileName(entry.Title);
        if (string.IsNullOrWhiteSpace(fileName))
        {
            fileName = "未命名章节";
        }

        string path = Path.Combine(AppPaths.ExportDirectory, fileName + ".txt");
        File.WriteAllText(path, entry.Content.Trim() + Environment.NewLine, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        return path;
    }

    public static IReadOnlyList<string> GetExportedFiles()
    {
        if (!Directory.Exists(AppPaths.ExportDirectory))
        {
            return [];
        }

        return Directory
            .EnumerateFiles(AppPaths.ExportDirectory, "*", SearchOption.TopDirectoryOnly)
            .Where(path => string.Equals(Path.GetExtension(path), ".txt", StringComparison.OrdinalIgnoreCase))
            .ToArray();
    }

    public static TxtCleanupResult ClearExportedFiles()
    {
        int deletedCount = 0;
        List<string> failedFiles = [];

        foreach (string path in GetExportedFiles())
        {
            try
            {
                File.Delete(path);
                deletedCount++;
            }
            catch
            {
                failedFiles.Add(path);
            }
        }

        return new TxtCleanupResult(deletedCount, failedFiles);
    }

    private static string SanitizeFileName(string value)
    {
        StringBuilder builder = new();
        foreach (char character in value.Trim())
        {
            if (!Path.GetInvalidFileNameChars().Contains(character))
            {
                builder.Append(character);
            }
        }
        string result = builder.ToString().Trim();
        return result.Length > 120 ? result[..120] : result;
    }
}

public sealed record TxtCleanupResult(int DeletedCount, IReadOnlyList<string> FailedFiles);
