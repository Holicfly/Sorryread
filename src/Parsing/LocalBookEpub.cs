using System.IO;
using System.IO.Compression;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;

namespace ReadAI;

internal static class LocalBookEpub
{
    private const int MaximumEntrySize = 24 * 1024 * 1024;
    private sealed record ManifestItem(string Path, string MediaType, string Properties);

    public static ParsedLocalBook Parse(string path, string fallbackTitle)
    {
        using var archive = ZipFile.OpenRead(path);
        if (archive.Entries.Count > 50_000 || archive.Entries.Sum(entry => entry.Length) > 512L * 1024 * 1024)
            throw new InvalidDataException("EPUB 解压后的资源超出上限。");
        if (archive.GetEntry("META-INF/encryption.xml") is { } encryption &&
            ReadXml(encryption).Descendants().Any(element => element.Name.LocalName == "EncryptionMethod" &&
                (string?)element.Attribute("Algorithm") is not
                    ("http://www.idpf.org/2008/embedding" or "http://ns.adobe.com/pdf/enc#RC")))
            throw new InvalidDataException("此 EPUB 含加密正文或图片。");

        string packagePath = ReadXml(RequireEntry(archive, "META-INF/container.xml"))
            .Descendants().FirstOrDefault(element => element.Name.LocalName == "rootfile")?
            .Attribute("full-path")?.Value ?? "";
        packagePath = Resolve("", packagePath) ?? throw new InvalidDataException("EPUB 缺少有效的出版清单。");
        var package = ReadXml(RequireEntry(archive, packagePath));
        string title = package.Descendants().FirstOrDefault(element => element.Name.LocalName == "title")?.Value
            ?? fallbackTitle;
        var manifest = new Dictionary<string, ManifestItem>(StringComparer.Ordinal);
        foreach (var element in package.Descendants().Where(element => element.Name.LocalName == "item"))
        {
            string? id = (string?)element.Attribute("id");
            string? entryPath = Resolve(packagePath, (string?)element.Attribute("href"));
            if (!string.IsNullOrEmpty(id) && entryPath is not null)
                manifest.TryAdd(id, new(entryPath, (string?)element.Attribute("media-type") ?? "",
                    (string?)element.Attribute("properties") ?? ""));
        }

        var spine = package.Descendants().FirstOrDefault(element => element.Name.LocalName == "spine") ??
            throw new InvalidDataException("EPUB 缺少阅读顺序。");
        var parser = new HtmlParser();
        var titles = ReadTitles(archive, manifest, (string?)spine.Attribute("toc"), parser);
        var units = new List<LocalBookUnit>();
        int imagePages = 0, textUnits = 0;
        bool fixedLayout = package.Descendants().Any(element =>
            element.Name.LocalName == "meta" && (string?)element.Attribute("property") == "rendition:layout" &&
            element.Value.Trim() == "pre-paginated");
        long textSize = 0;
        int spineIndex = -1;
        foreach (var reference in spine.Elements().Where(element => element.Name.LocalName == "itemref"))
        {
            spineIndex++;
            string id = (string?)reference.Attribute("idref") ?? "";
            if ((string?)reference.Attribute("linear") == "no") continue;
            if (!manifest.TryGetValue(id, out var item))
                throw new InvalidDataException("EPUB 阅读顺序引用了缺失的资源。");
            var entry = RequireEntry(archive, item.Path);
            string? unitTitle = titles.GetValueOrDefault(item.Path);
            var blocks = new List<LocalBookBlock>();
            if (IsImage(item.Path)) blocks.Add(new("", item.Path));
            else if (item.MediaType is "application/xhtml+xml" or "text/html" or "image/svg+xml")
            {
                using var input = OpenEntry(entry);
                using var document = parser.ParseDocument(input);
                unitTitle ??= document.QuerySelector("h1,h2,h3,title")?.TextContent;
                var text = new StringBuilder();
                if (document.Body is not null) Append(document.Body, item.Path, archive, blocks, text);
                FlushText(blocks, text);
            }

            if (blocks.Count == 0) continue;
            string address = FormattableString.Invariant($"epub:{spineIndex}");
            if (blocks.All(block => block.ImagePath is not null))
            {
                for (int index = 0; index < blocks.Count; index++)
                    units.Add(new($"第 {units.Count + 1} 页",
                        FormattableString.Invariant($"{address}:image:{index}:{Uri.EscapeDataString(blocks[index].ImagePath!)}"),
                        [blocks[index]]));
                imagePages += blocks.Count;
            }
            else
            {
                textUnits++;
                textSize += blocks.Sum(block => (long)block.Text.Length);
                units.Add(new(LocalBook.LimitTitle(unitTitle ?? "", $"第 {units.Count + 1} 节"), address, blocks));
            }
            if (units.Count > LocalBook.MaximumUnits || textSize > 60_000_000)
                throw new InvalidDataException("EPUB 正文或目录超出上限。");
        }
        bool comic = imagePages > 0 && (textUnits == 0 || fixedLayout || imagePages >= textUnits * 3);
        return new(title, comic, units);
    }

    private static Dictionary<string, string> ReadTitles(ZipArchive archive,
        Dictionary<string, ManifestItem> manifest, string? tocId, HtmlParser parser)
    {
        var titles = new Dictionary<string, string>(StringComparer.Ordinal);
        var nav = manifest.Values.FirstOrDefault(item => item.Properties.Split(' ').Contains("nav"));
        if (nav is not null && archive.GetEntry(nav.Path) is { } navEntry)
        {
            using var input = OpenEntry(navEntry);
            using var document = parser.ParseDocument(input);
            var toc = document.QuerySelector("nav[epub\\:type~=toc]") ?? document.QuerySelector("nav");
            if (toc is not null)
            {
                foreach (var link in toc.QuerySelectorAll("a[href]"))
                    AddTitle(nav.Path, link.GetAttribute("href"), link.TextContent, titles);
            }
        }
        if (tocId is not null && manifest.TryGetValue(tocId, out var ncx) &&
            archive.GetEntry(ncx.Path) is { } ncxEntry)
        {
            foreach (var point in ReadXml(ncxEntry).Descendants().Where(element => element.Name.LocalName == "navPoint"))
            {
                var content = point.Elements().FirstOrDefault(element => element.Name.LocalName == "content");
                var label = point.Elements().FirstOrDefault(element => element.Name.LocalName == "navLabel");
                AddTitle(ncx.Path, (string?)content?.Attribute("src"), label?.Value, titles);
            }
        }
        return titles;
    }

    private static void AddTitle(string parent, string? href, string? title, Dictionary<string, string> titles)
    {
        string? entryPath = Resolve(parent, href);
        if (entryPath is not null && !string.IsNullOrWhiteSpace(title))
            titles.TryAdd(entryPath, title.Trim());
    }

    private static void Append(INode node, string parent, ZipArchive archive,
        List<LocalBookBlock> blocks, StringBuilder text, int depth = 0)
    {
        if (depth > 256) throw new InvalidDataException("EPUB 页面结构过深。");
        if (node is IText literal)
        {
            text.Append(literal.Data);
            return;
        }
        if (node is not IElement element || element.LocalName is "script" or "style" or "template" or "head")
            return;
        if (element.LocalName is "img" or "image")
        {
            string? href = element.GetAttribute("src") ?? element.GetAttribute("href") ??
                element.Attributes.FirstOrDefault(attribute => attribute.LocalName == "href")?.Value ??
                element.GetAttribute("xlink:href");
            string? imagePath = Resolve(parent, href);
            if (imagePath is not null && IsImage(imagePath) && archive.GetEntry(imagePath) is { } image &&
                image.Length is > 0 and <= MaximumEntrySize)
            {
                FlushText(blocks, text);
                blocks.Add(new("", imagePath));
            }
            return;
        }
        bool paragraph = element.LocalName is "p" or "div" or "section" or "article" or "li" or
            "blockquote" or "pre" or "tr" or "h1" or "h2" or "h3" or "h4" or "h5" or "h6";
        if (paragraph) text.Append("\n\n");
        if (element.LocalName is "br" or "hr") text.Append('\n');
        foreach (var child in element.ChildNodes) Append(child, parent, archive, blocks, text, depth + 1);
        if (paragraph) text.Append("\n\n");
    }

    private static void FlushText(List<LocalBookBlock> blocks, StringBuilder text)
    {
        string value = text.ToString().Trim();
        text.Clear();
        if (value.Length != 0) blocks.Add(new(value));
    }

    private static bool IsImage(string path) => Path.GetExtension(path).ToLowerInvariant() is
        ".jpg" or ".jpeg" or ".png" or ".gif" or ".bmp" or ".tif" or ".tiff";

    private static ZipArchiveEntry RequireEntry(ZipArchive archive, string path) =>
        archive.GetEntry(path) ?? throw new InvalidDataException("EPUB 缺少清单或正文资源。");

    internal static Stream OpenEntry(ZipArchiveEntry entry) =>
        entry.Length is > 0 and <= MaximumEntrySize ? entry.Open() :
            throw new InvalidDataException("EPUB 资源为空或超过单项大小上限。");

    private static XDocument ReadXml(ZipArchiveEntry entry)
    {
        using var stream = OpenEntry(entry);
        using var reader = XmlReader.Create(stream, new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Ignore, XmlResolver = null, MaxCharactersInDocument = MaximumEntrySize
        });
        return XDocument.Load(reader);
    }

    private static string? Resolve(string parent, string? href)
    {
        if (string.IsNullOrWhiteSpace(href)) return null;
        string relative = href.Split('#', '?')[0];
        if (relative.Length == 0) return parent.Length == 0 ? null : parent;
        if (relative.StartsWith('/') || relative.Contains(':') || relative.Contains('\\')) return null;
        int slash = parent.LastIndexOf('/');
        List<string> segments = slash < 0 ? [] : [.. parent[..slash].Split('/')];
        foreach (string raw in relative.Split('/'))
        {
            string segment = Uri.UnescapeDataString(raw);
            if (segment.Length == 0 || segment == ".") continue;
            if (segment is "..")
            {
                if (segments.Count == 0) return null;
                segments.RemoveAt(segments.Count - 1);
            }
            else
            {
                if (segment.IndexOfAny(['/', '\\', '\0', ':']) >= 0) return null;
                segments.Add(segment);
            }
        }
        return segments.Count == 0 ? null : string.Join('/', segments);
    }
}
