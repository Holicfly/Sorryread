using System.Buffers.Binary;
using System.IO;
using System.Text;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;

namespace ReadAI;

internal static class LocalBookMobi
{
    public static ParsedLocalBook Parse(string path, string fallbackTitle)
    {
        byte[] file = File.ReadAllBytes(path);
        if (file.Length < 86 || !file.AsSpan(60, 8).SequenceEqual("BOOKMOBI"u8))
            throw BadBook();
        int recordCount = U16(file, 76);
        int tableEnd = 78 + 8 * recordCount;
        if (recordCount < 2 || tableEnd > file.Length) throw BadBook();
        var offsets = new int[recordCount + 1];
        offsets[^1] = file.Length;
        for (int index = 0; index < recordCount; index++)
        {
            int offset = Integer(file, 78 + index * 8);
            if (offset < tableEnd || offset > file.Length || (index > 0 && offset < offsets[index - 1]))
                throw BadBook();
            offsets[index] = offset;
        }
        ReadOnlyMemory<byte> Record(int index) => index >= 0 && index < recordCount
            ? file.AsMemory(offsets[index], offsets[index + 1] - offsets[index]) : throw BadBook();

        var header = Record(0).Span;
        if (header.Length < 16) throw BadBook();
        if (U16(header, 12) != 0) throw new InvalidDataException("此 MOBI 受 DRM 保护。");
        if (header.Length < 40 || !header.Slice(16, 4).SequenceEqual("MOBI"u8)) throw BadBook();
        if (U32(header, 36) == 8)
            throw new InvalidDataException("此文件是 KF8 图书，请转换为 EPUB 后导入。");
        int length = Integer(header, 4);
        int textRecords = U16(header, 8);
        if (length is <= 0 or > 80_000_000 || textRecords <= 0 || textRecords >= recordCount) throw BadBook();
        int compression = U16(header, 0);
        if (compression is not (1 or 2 or 17480)) throw new InvalidDataException("此 MOBI 使用不支持的压缩格式。");
        int headerLength = Integer(header, 20);
        int flags = headerLength >= 228 && header.Length >= 244 ? U16(header, 242) : 0;
        var dictionary = compression == 17480 ? new HuffDictionary(
            Integer(header, 112), Integer(header, 116), Record) : null;
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var encoding = U32(header, 28) switch
        {
            65001 => new UTF8Encoding(false, true),
            1252 => Encoding.GetEncoding(1252),
            _ => throw new InvalidDataException("此 MOBI 使用不支持的正文编码。")
        };
        string title = fallbackTitle;
        if (header.Length >= 92)
        {
            int titleOffset = Integer(header, 84);
            int titleLength = Integer(header, 88);
            if (titleOffset > 0 && titleOffset <= header.Length && titleLength <= header.Length - titleOffset)
                title = encoding.GetString(header.Slice(titleOffset, Math.Min(2048, titleLength))).TrimEnd('\0');
        }

        using var content = new MemoryStream(length);
        int capacity = Math.Max(4096, (int)U16(header, 10));
        byte[] buffer = new byte[capacity];
        for (int index = 1; index <= textRecords && content.Length < length; index++)
        {
            var record = RemoveTrailer(Record(index).Span, flags);
            if (compression == 1) content.Write(record[..Math.Min(record.Length, length - (int)content.Length)]);
            else
            {
                int expanded = compression == 2 ? ExpandPalmDoc(record, buffer) : dictionary!.Expand(record, buffer);
                content.Write(buffer, 0, Math.Min(expanded, length - (int)content.Length));
            }
        }
        if (content.Length != length) throw BadBook();

        string html;
        try { html = encoding.GetString(content.GetBuffer(), 0, length); }
        catch (DecoderFallbackException error) { throw new InvalidDataException("MOBI 正文编码无效。", error); }
        using var document = new HtmlParser().ParseDocument(html);
        var text = new StringBuilder();
        if (document.Body is not null) AppendText(document.Body, text);
        return new(title, false, LocalBookText.Split(text.ToString(), "mobi"));
    }

    private static void AppendText(INode node, StringBuilder text, int depth = 0)
    {
        if (depth > 256) throw BadBook();
        if (node is IText literal) { text.Append(literal.Data); return; }
        if (node is not IElement element || element.LocalName is "script" or "style" or "head" or "template") return;
        bool block = element.LocalName is "p" or "div" or "blockquote" or "section" or "li" or "h1" or "h2"
            or "h3" or "h4" or "h5" or "h6" or "mbp:pagebreak" or "hr";
        if (block) text.Append("\n\n");
        if (element.LocalName == "br") text.Append('\n');
        foreach (var child in element.ChildNodes) AppendText(child, text, depth + 1);
        if (block) text.Append("\n\n");
    }

    private static ReadOnlySpan<byte> RemoveTrailer(ReadOnlySpan<byte> bytes, int flags)
    {
        for (int mask = 1 << 15; mask > 1; mask >>= 1)
        {
            if ((flags & mask) == 0) continue;
            int length = 0;
            int count = 0;
            byte value;
            do
            {
                if (count >= 4 || count >= bytes.Length) throw BadBook();
                value = bytes[^(count + 1)];
                length |= (value & 127) << (7 * count++);
            } while ((value & 128) == 0);
            if (length < count || length > bytes.Length) throw BadBook();
            bytes = bytes[..^length];
        }
        if ((flags & 1) != 0)
        {
            if (bytes.IsEmpty) throw BadBook();
            int count = (bytes[^1] & 3) + 1;
            if (count > bytes.Length) throw BadBook();
            bytes = bytes[..^count];
        }
        return bytes;
    }

    private static int ExpandPalmDoc(ReadOnlySpan<byte> bytes, Span<byte> output)
    {
        int written = 0;
        for (int index = 0; index < bytes.Length; index++)
        {
            byte value = bytes[index];
            if (value is >= 1 and <= 8)
            {
                if (index + value >= bytes.Length || written + value > output.Length) throw BadBook();
                bytes.Slice(index + 1, value).CopyTo(output[written..]);
                index += value;
                written += value;
            }
            else if (value is >= 128 and <= 191)
            {
                if (++index >= bytes.Length) throw BadBook();
                int pair = (value << 8) | bytes[index];
                int distance = (pair >> 3) & 2047;
                int count = (pair & 7) + 3;
                if (distance == 0 || distance > written || written + count > output.Length) throw BadBook();
                for (int i = 0; i < count; i++)
                {
                    output[written] = output[written - distance];
                    written++;
                }
            }
            else
            {
                if (written == output.Length) throw BadBook();
                if (value >= 192)
                {
                    if (written + 2 > output.Length) throw BadBook();
                    output[written++] = (byte)' ';
                    value ^= 128;
                }
                output[written++] = value;
            }
        }
        return written;
    }

    private static int Integer(ReadOnlySpan<byte> bytes, int offset)
    {
        uint value = U32(bytes, offset);
        return value <= int.MaxValue ? (int)value : throw BadBook();
    }

    private static ushort U16(ReadOnlySpan<byte> bytes, int offset) =>
        offset >= 0 && offset <= bytes.Length - 2 ? BinaryPrimitives.ReadUInt16BigEndian(bytes[offset..]) : throw BadBook();
    private static uint U32(ReadOnlySpan<byte> bytes, int offset) =>
        offset >= 0 && offset <= bytes.Length - 4 ? BinaryPrimitives.ReadUInt32BigEndian(bytes[offset..]) : throw BadBook();
    private static InvalidDataException BadBook() => new("MOBI 文件损坏或正文不完整。");

    private sealed class HuffDictionary
    {
        private readonly uint[] _lookup = new uint[256];
        private readonly uint[] _lower = new uint[33];
        private readonly uint[] _upper = new uint[33];
        private readonly List<(ReadOnlyMemory<byte> Data, bool Literal)> _phrases = [];

        public HuffDictionary(int first, int count, Func<int, ReadOnlyMemory<byte>> record)
        {
            if (count is < 2 or > 1024 || first > int.MaxValue - count) throw BadBook();
            var table = record(first).Span;
            if (!table.StartsWith("HUFF"u8)) throw BadBook();
            int quickTable = Integer(table, 8);
            int bounds = Integer(table, 12);
            if (quickTable > table.Length - 1024 || bounds > table.Length - 256) throw BadBook();
            for (int index = 0; index < 256; index++) _lookup[index] = U32(table, quickTable + index * 4);
            for (int bits = 1; bits <= 32; bits++)
            {
                int offset = bounds + (bits - 1) * 8;
                _lower[bits] = U32(table, offset) << (32 - bits);
                _upper[bits] = ((U32(table, offset + 4) + 1) << (32 - bits)) - 1;
            }
            int expected = 0;
            int phraseBits = 0;
            for (int index = 1; index < count; index++)
            {
                var dictionary = record(first + index);
                var data = dictionary.Span;
                if (!data.StartsWith("CDIC"u8)) throw BadBook();
                int total = Integer(data, 8);
                int bits = Integer(data, 12);
                if (total is <= 0 or > 1_000_000 || bits is < 1 or > 16 ||
                    (index > 1 && (expected != total || phraseBits != bits))) throw BadBook();
                expected = total;
                phraseBits = bits;
                int phraseCount = Math.Min(1 << bits, total - _phrases.Count);
                for (int phrase = 0; phrase < phraseCount; phrase++)
                {
                    int position = 16 + U16(data, 16 + phrase * 2);
                    int size = U16(data, position);
                    int length = size & 0x7fff;
                    if (length > data.Length - position - 2) throw BadBook();
                    _phrases.Add((dictionary.Slice(position + 2, length), (size & 0x8000) != 0));
                }
            }
            if (_phrases.Count != expected) throw BadBook();
        }

        public int Expand(ReadOnlySpan<byte> input, Span<byte> output, int depth = 0)
        {
            if (depth > 20 || input.Length > 1_000_000) throw BadBook();
            int written = 0;
            int end = input.Length * 8;
            for (int position = 0; position < end;)
            {
                ulong window = 0;
                int start = position / 8;
                for (int index = 0; index < 5; index++)
                    window = (window << 8) | (start + index < input.Length ? input[start + index] : 0U);
                uint code = (uint)(window >> (8 - position % 8));
                uint quick = _lookup[code >> 24];
                int bits = (int)(quick & 31);
                if (bits == 0) throw BadBook();
                uint upper;
                if ((quick & 128) == 0)
                {
                    while (bits <= 32 && code < _lower[bits]) bits++;
                    if (bits > 32) throw BadBook();
                    upper = _upper[bits];
                }
                else upper = (((quick >> 8) + 1) << (32 - bits)) - 1;
                position += bits;
                if (position > end) break;
                if (code > upper) throw BadBook();
                uint indexOfPhrase = (upper - code) >> (32 - bits);
                if (indexOfPhrase >= _phrases.Count) throw BadBook();
                var phrase = _phrases[(int)indexOfPhrase];
                if (!phrase.Literal) written += Expand(phrase.Data.Span, output[written..], depth + 1);
                else
                {
                    if (phrase.Data.Length > output.Length - written) throw BadBook();
                    phrase.Data.Span.CopyTo(output[written..]);
                    written += phrase.Data.Length;
                }
            }
            return written;
        }
    }
}
