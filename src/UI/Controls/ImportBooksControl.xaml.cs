using System.IO;
using System.Windows;
using Microsoft.Data.Sqlite;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;

namespace ReadAI;

public partial class ImportBooksControl : System.Windows.Controls.UserControl
{
    private ReaderDatabase? _database;
    public event EventHandler? BackRequested;
    public event EventHandler<LibraryBookEntry>? OpenRequested;
    public event EventHandler<(string Message, bool IsError)>? ImportStatusChanged;

    public ImportBooksControl() => InitializeComponent();
    public void SetDatabase(ReaderDatabase database) => _database = database;

    internal void Refresh()
    {
        if (_database is null) return;
        var books = _database.GetLocalBooks(limit: int.MaxValue).Reverse().Select(book => new LibraryBookEntry
        {
            BookKey = LocalBook.BookKey(book.State.Sha256),
            SourceId = LocalBook.SourceId,
            DetailUrl = LocalBook.UrlPrefix + book.State.Sha256,
            Title = book.State.Title,
            SourceName = book.State.Format.ToUpperInvariant() +
                (book.HasFile ? book.State.Comic ? " · 漫画" : " · 本地书" : " · 等待同步原文件")
        }).ToArray();
        BooksList.ItemsSource = books;
        EmptyText.Visibility = books.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        CountText.Text = $"{books.Length} 本";
    }

    private void BackClick(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);
    private void BookOpenRequested(object sender, RoutedEventArgs e)
    {
        if (sender is LibraryBookCard { Book: { } book }) OpenRequested?.Invoke(this, book);
    }

    private async void BookDeleteRequested(object sender, RoutedEventArgs e)
    {
        if (_database is null || sender is not LibraryBookCard { Book: { } book } ||
            Window.GetWindow(this) is not { } owner) return;
        string? peer = App.DeviceLink?.Peer?.DeviceId;
        string? action = ThemedConfirmDialog.ChooseLocalBookRemoval(owner, book.Title, peer is not null);
        if (action is null) return;
        string sha = book.DetailUrl[LocalBook.UrlPrefix.Length..];
        try
        {
            await _database.RemoveLocalBookAsync(sha, action == "removeBoth", peer);
            App.DeviceLink?.CancelLocalBookDownloads(sha);
            Refresh();
            Report(action == "removeBoth" ? "已从此电脑移除，手机将在同步时移除。" : "已从此电脑移出。");
        }
        catch (Exception error) when (error is IOException or SqliteException or InvalidDataException)
        {
            Report($"移出失败：{error.Message}", true);
        }
    }

    private async void ChooseClick(object sender, RoutedEventArgs e)
    {
        if (_database is null) return;
        var picker = new OpenFileDialog
        {
            Title = "选择要导入的图书",
            Filter = "支持的图书 (*.txt;*.epub;*.mobi)|*.txt;*.epub;*.mobi",
            Multiselect = true, CheckFileExists = true, CheckPathExists = true
        };
        if (picker.ShowDialog(Window.GetWindow(this)) != true) return;
        ChooseButton.IsEnabled = false;
        int imported = 0, duplicates = 0;
        var failures = new List<string>();
        try
        {
            for (int index = 0; index < picker.FileNames.Length; index++)
            {
                string path = picker.FileNames[index];
                Report($"正在导入 {index + 1}/{picker.FileNames.Length} · {Path.GetFileName(path)}");
                try
                {
                    var result = await LocalBookImporter.ImportAsync(_database, path);
                    if (result.AlreadyInstalled) duplicates++;
                    else imported++;
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or SqliteException
                    or System.Xml.XmlException or System.Text.DecoderFallbackException or InvalidDataException)
                {
                    failures.Add($"{Path.GetFileName(path)} · {error.Message}");
                }
            }
            Refresh();
            string summary = $"导入 {imported} 本，重复 {duplicates} 本，失败 {failures.Count} 本";
            Report(summary, failures.Count > 0);
            if (failures.Count > 0 && IsVisible)
                System.Windows.MessageBox.Show(Window.GetWindow(this),
                    string.Join(Environment.NewLine, failures.Take(12)), summary, MessageBoxButton.OK, MessageBoxImage.Information);
        }
        finally { ChooseButton.IsEnabled = true; }
    }

    private void Report(string message, bool isError = false) => ImportStatusChanged?.Invoke(this, (message, isError));
}
