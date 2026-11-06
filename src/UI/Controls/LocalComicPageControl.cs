using System.IO;
using System.IO.Compression;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ReadAI.Sync;
using Image = System.Windows.Controls.Image;

namespace ReadAI;

internal sealed record ComicPageSource(ReaderDatabase Database, LocalBookState Book, int Index);

public sealed class LocalComicPageControl : StackPanel
{
    private readonly TextBlock _message = new()
    {
        HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center
    };
    private int _generation;

    public LocalComicPageControl()
    {
        _message.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        Loaded += (_, _) => LoadImage();
        Unloaded += (_, _) => { _generation++; Children.Clear(); };
        DataContextChanged += (_, _) => { if (IsLoaded) LoadImage(); };
    }

    private async void LoadImage()
    {
        int generation = ++_generation;
        Children.Clear();
        MinHeight = 180;
        if (DataContext is not ComicPageSource page) return;
        _message.Text = $"正在加载第 {page.Index + 1} 页…";
        Children.Add(_message);
        try
        {
            var blocks = await Task.Run(() => ReadBlocks(page.Database, page.Book, page.Index));
            if (generation != _generation) return;
            Children.Clear();
            foreach (var block in blocks)
            {
                if (block.Image is { } bitmap) Children.Add(new Image { Source = bitmap, Stretch = Stretch.Uniform });
                else Children.Add(new TextBlock
                {
                    Text = block.HasImage ? "〔图片无法读取〕" : block.Text, TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(6), FontSize = 15
                });
            }
            MinHeight = 0;
        }
        catch (Exception error) when (IsImageError(error) || error is Microsoft.Data.Sqlite.SqliteException)
        {
            if (generation == _generation) _message.Text = $"第 {page.Index + 1} 页图片无法读取";
        }
    }

    internal static bool IsImageError(Exception error) => error is IOException or UnauthorizedAccessException
        or InvalidDataException or NotSupportedException or ArgumentException or System.Runtime.InteropServices.COMException;

    internal sealed record RenderedBlock(string Text, bool HasImage, BitmapSource? Image = null);

    internal static List<RenderedBlock> ReadBlocks(ReaderDatabase database, LocalBookState state, int index)
    {
        var result = new List<RenderedBlock>();
        var blocks = database.GetLocalBookBlocks(state.Sha256, index);
        using var archive = blocks.Any(block => block.ImagePath is not null)
            ? new ZipArchive(new FileStream(database.LocalBookFilePath(state), FileMode.Open, FileAccess.Read,
                FileShare.Read | FileShare.Delete), ZipArchiveMode.Read) : null;
        int imageCount = 0;
        foreach (var block in blocks)
        {
            if (block.ImagePath is null) result.Add(new(block.Text, false));
            else
            {
                BitmapSource? image = null;
                try
                {
                    if (++imageCount <= 64) image = DecodeImage(archive!, block.ImagePath);
                }
                catch (Exception error) when (IsImageError(error)) { }
                result.Add(new("", true, image));
            }
        }
        return result;
    }

    private static BitmapSource DecodeImage(ZipArchive archive, string path)
    {
        var entry = archive.GetEntry(path) ?? throw new InvalidDataException("EPUB 图片资源缺失。");
        using var input = LocalBookEpub.OpenEntry(entry);
        using var bytes = new MemoryStream((int)entry.Length);
        input.CopyTo(bytes);
        bytes.Position = 0;
        var metadata = BitmapDecoder.Create(bytes, BitmapCreateOptions.DelayCreation, BitmapCacheOption.OnDemand).Frames[0];
        if (metadata.PixelWidth <= 0 || metadata.PixelHeight <= 0 || metadata.PixelWidth > 16_384 ||
            metadata.PixelHeight > 32_768 || (long)metadata.PixelWidth * metadata.PixelHeight > 80_000_000)
            throw new InvalidDataException("EPUB 图片尺寸超出上限。");
        bytes.Position = 0;
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        double scale = Math.Min(1500d / metadata.PixelWidth,
            Math.Sqrt(4_000_000d / ((long)metadata.PixelWidth * metadata.PixelHeight)));
        if (scale < 1) image.DecodePixelWidth = Math.Max(1, (int)(metadata.PixelWidth * scale));
        image.StreamSource = bytes;
        image.EndInit();
        image.Freeze();
        return image;
    }
}
