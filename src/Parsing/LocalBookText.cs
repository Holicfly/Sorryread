using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace ReadAI;

internal static class LocalBookText
{
    private const int ChapterSize = 5000;
    private static readonly Regex ChapterHeading = new(
        @"(?m)^[^\S\n]*第[0-9一两二三四五六七八九十百千零〇壹贰叁肆伍陆柒捌玖拾]+[册卷部章回节][^\n]*$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Encoding Utf8 = new UTF8Encoding(false, true);

    public static string Decode(ReadOnlySpan<byte> bytes)
    {
        try
        {
            if (bytes.StartsWith(new byte[] { 0xef, 0xbb, 0xbf })) return Utf8.GetString(bytes[3..]);
            if (bytes.StartsWith(new byte[] { 0xff, 0xfe }))
                return new UnicodeEncoding(false, false, true).GetString(bytes[2..]);
            if (bytes.StartsWith(new byte[] { 0xfe, 0xff }))
                return new UnicodeEncoding(true, false, true).GetString(bytes[2..]);
            try { return Utf8.GetString(bytes); }
            catch (DecoderFallbackException)
            {
                Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
                return Encoding.GetEncoding(54936, EncoderFallback.ExceptionFallback,
                    DecoderFallback.ExceptionFallback).GetString(bytes);
            }
        }
        catch (DecoderFallbackException error)
        {
            throw new InvalidDataException("无法识别 TXT 编码，请转换为 UTF-8 后重试。", error);
        }
    }

    public static IReadOnlyList<LocalBookUnit> Split(string text, string address)
    {
        text = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        var units = new List<LocalBookUnit>();
        int start = 0;
        string? title = null;
        foreach (Match match in ChapterHeading.Matches(text))
        {
            string heading = match.Value.Trim();
            if (heading.Length >= 30) continue;
            AddParts(units, text, start, match.Index, title ?? "前言", address);
            title = heading;
            start = match.Index + match.Length;
            if (start < text.Length && text[start] == '\n') start++;
        }
        AddParts(units, text, start, text.Length, title, address);
        return units;
    }

    private static void AddParts(List<LocalBookUnit> units, string text, int start, int end,
        string? title, string address)
    {
        int part = 1;
        bool longChapter = end - start > ChapterSize;
        while (start < end)
        {
            int next = Math.Min(end, start + ChapterSize);
            if (next < end)
            {
                int newline = text.LastIndexOf('\n', next - 1, ChapterSize);
                if (newline >= start + ChapterSize / 2) next = newline + 1;
                else if (char.IsHighSurrogate(text[next - 1])) next--;
            }
            string content = text[start..next].Trim();
            if (content.Length != 0)
            {
                if (units.Count >= LocalBook.MaximumUnits) throw new InvalidDataException("图书目录条目过多。");
                string unitTitle = title is null ? $"第{units.Count + 1}章" :
                    longChapter ? $"{title} 第{part++}部分" : title;
                units.Add(new(unitTitle, FormattableString.Invariant($"{address}:{start}:{next}"), [new(content)]));
            }
            start = next;
        }
    }
}
