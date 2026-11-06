part of 'local_book_parser.dart';

Never _badMobi() => throw const FormatException('MOBI 文件损坏或正文不完整');

bool _magic(Uint8List data, int offset, String magic) =>
    offset >= 0 &&
    offset + magic.length <= data.length &&
    List.generate(
      magic.length,
      (i) => data[offset + i] == magic.codeUnitAt(i),
    ).every((x) => x);
int _u16(Uint8List data, int offset) => offset >= 0 && offset + 2 <= data.length
    ? ByteData.sublistView(data).getUint16(offset)
    : _badMobi();
int _u32(Uint8List data, int offset) => offset >= 0 && offset + 4 <= data.length
    ? ByteData.sublistView(data).getUint32(offset)
    : _badMobi();

ParsedBook _parseMobi(Uint8List data, String fallback) {
  if (data.length < 86 || !_magic(data, 60, 'BOOKMOBI')) _badMobi();
  final count = _u16(data, 76), tableEnd = 78 + _u16(data, 76) * 8;
  if (count < 2 || tableEnd > data.length) _badMobi();
  final offsets = <int>[];
  for (var i = 0; i < count; i++) {
    final offset = _u32(data, 78 + i * 8);
    if (offset < tableEnd ||
        offset > data.length ||
        offsets.isNotEmpty && offset < offsets.last)
      _badMobi();
    offsets.add(offset);
  }
  offsets.add(data.length);
  Uint8List record(int index) => index >= 0 && index < count
      ? Uint8List.sublistView(data, offsets[index], offsets[index + 1])
      : _badMobi();
  final header = record(0);
  if (header.length < 16) _badMobi();
  if (_u16(header, 12) != 0) throw const FormatException('此 MOBI 受 DRM 保护');
  if (header.length < 40 || !_magic(header, 16, 'MOBI')) _badMobi();
  if (_u32(header, 36) == 8)
    throw const FormatException('此文件是 KF8 图书，请转换为 EPUB');
  final length = _u32(header, 4), textRecords = _u16(header, 8);
  if (length <= 0 ||
      length > 80000000 ||
      textRecords <= 0 ||
      textRecords >= count)
    _badMobi();
  final compression = _u16(header, 0);
  if (!const {1, 2, 17480}.contains(compression))
    throw const FormatException('MOBI 压缩格式不受支持');
  final headerLength = _u32(header, 20);
  final flags = headerLength >= 228 && header.length >= 244
      ? _u16(header, 242)
      : 0;
  final dictionary = compression == 17480
      ? _HuffDictionary(_u32(header, 112), _u32(header, 116), record)
      : null;
  final String Function(List<int>) decode = switch (_u32(header, 28)) {
    65001 => utf8.decode,
    1252 => _cp1252,
    _ => throw const FormatException('MOBI 正文编码不受支持'),
  };
  var title = fallback;
  if (header.length >= 92) {
    final offset = _u32(header, 84), size = _u32(header, 88);
    if (offset > 0 &&
        offset <= header.length &&
        size <= header.length - offset) {
      title = decode(
        Uint8List.sublistView(header, offset, offset + min(2048, size)),
      ).replaceFirst(RegExp(r'\x00+$'), '');
    }
  }
  final content = Uint8List(length);
  final buffer = Uint8List(max(4096, _u16(header, 10)));
  var offset = 0;
  for (var index = 1; index <= textRecords && offset < length; index++) {
    final input = _removeMobiTrailer(record(index), flags);
    final expanded = switch (compression) {
      1 => input.length,
      2 => _expandPalmDoc(input, buffer),
      _ => dictionary!.expand(input, buffer, 0),
    };
    final size = min(expanded, length - offset);
    content.setRange(offset, offset + size, compression == 1 ? input : buffer);
    offset += size;
  }
  if (offset != length) _badMobi();
  final doc = html.parse(decode(content));
  final text = StringBuffer();
  void visit(dom.Node node, int depth) {
    if (depth > 256) _badMobi();
    if (node is dom.Text) {
      text.write(node.data);
      return;
    }
    if (node is! dom.Element ||
        const {'script', 'style', 'head', 'template'}.contains(node.localName))
      return;
    final block = const {
      'p',
      'div',
      'blockquote',
      'section',
      'li',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'mbp:pagebreak',
      'hr',
    }.contains(node.localName);
    if (block) text.write('\n\n');
    if (node.localName == 'br') text.write('\n');
    for (final child in node.nodes) {
      visit(child, depth + 1);
    }
    if (block) text.write('\n\n');
  }

  if (doc.body != null) visit(doc.body!, 0);
  final cover = _mobiCover(header, headerLength, count, record);
  return _validBook(
    title,
    false,
    splitBookText(text.toString(), 'mobi'),
    fallback,
    cover,
  );
}

String _cp1252(List<int> bytes) {
  const high = [
    0x20ac,
    0x81,
    0x201a,
    0x0192,
    0x201e,
    0x2026,
    0x2020,
    0x2021,
    0x02c6,
    0x2030,
    0x0160,
    0x2039,
    0x0152,
    0x8d,
    0x017d,
    0x8f,
    0x90,
    0x2018,
    0x2019,
    0x201c,
    0x201d,
    0x2022,
    0x2013,
    0x2014,
    0x02dc,
    0x2122,
    0x0161,
    0x203a,
    0x0153,
    0x9d,
    0x017e,
    0x0178,
  ];
  return String.fromCharCodes(
    bytes.map((byte) => byte >= 128 && byte < 160 ? high[byte - 128] : byte),
  );
}

Uint8List? _mobiCover(
  Uint8List header,
  int length,
  int count,
  Uint8List Function(int) record,
) {
  final exth = 16 + length;
  if (!_magic(header, exth, 'EXTH') ||
      exth + 12 > header.length ||
      header.length < 112)
    return null;
  final end = min(header.length, exth + _u32(header, exth + 4));
  for (var offset = exth + 12; offset + 8 <= end;) {
    final type = _u32(header, offset), size = _u32(header, offset + 4);
    if (size < 8 || offset + size > end) return null;
    if (type == 201 && size >= 12) {
      final index = _u32(header, 108) + _u32(header, offset + 8);
      if (index >= count) return null;
      final image = record(index);
      if (image.length > 6 * 1024 * 1024) return null;
      if (_magic(image, 1, 'PNG') ||
          _magic(image, 0, 'GIF') ||
          _magic(image, 0, 'BM') ||
          image.length >= 2 && image[0] == 0xff && image[1] == 0xd8) {
        return image;
      }
      return null;
    }
    offset += size;
  }
  return null;
}

Uint8List _removeMobiTrailer(Uint8List data, int flags) {
  var end = data.length;
  for (var mask = 1 << 15; mask > 1; mask >>= 1) {
    if (flags & mask == 0) continue;
    var size = 0, count = 0;
    int value;
    do {
      if (count >= 4 || count >= end) _badMobi();
      value = data[end - 1 - count];
      size |= (value & 127) << (7 * count++);
    } while (value & 128 == 0);
    if (size < count || size > end) _badMobi();
    end -= size;
  }
  if (flags & 1 != 0) {
    if (end == 0) _badMobi();
    end -= (data[end - 1] & 3) + 1;
    if (end < 0) _badMobi();
  }
  return Uint8List.sublistView(data, 0, end);
}

int _expandPalmDoc(Uint8List input, Uint8List output) {
  var written = 0;
  for (var index = 0; index < input.length; index++) {
    var value = input[index];
    if (value >= 1 && value <= 8) {
      if (index + value >= input.length || written + value > output.length)
        _badMobi();
      output.setRange(written, written + value, input, index + 1);
      index += value;
      written += value;
    } else if (value >= 128 && value <= 191) {
      if (++index >= input.length) _badMobi();
      final pair = (value << 8) | input[index];
      final distance = (pair >> 3) & 2047, count = (pair & 7) + 3;
      if (distance == 0 ||
          distance > written ||
          written + count > output.length)
        _badMobi();
      for (var i = 0; i < count; i++) {
        output[written] = output[written - distance];
        written++;
      }
    } else {
      if (written == output.length) _badMobi();
      if (value >= 192) {
        if (written + 2 > output.length) _badMobi();
        output[written++] = 32;
        value ^= 128;
      }
      output[written++] = value;
    }
  }
  return written;
}

class _HuffDictionary {
  _HuffDictionary(int first, int count, Uint8List Function(int) record) {
    if (count < 2 || count > 1024) _badMobi();
    final table = record(first);
    if (!_magic(table, 0, 'HUFF')) _badMobi();
    final quick = _u32(table, 8), bounds = _u32(table, 12);
    if (quick > table.length - 1024 || bounds > table.length - 256) _badMobi();
    for (var i = 0; i < 256; i++) {
      lookup[i] = _u32(table, quick + i * 4);
    }
    for (var bits = 1; bits <= 32; bits++) {
      final offset = bounds + (bits - 1) * 8;
      lower[bits] = (_u32(table, offset) << (32 - bits)) & 0xffffffff;
      upper[bits] =
          (((_u32(table, offset + 4) + 1) << (32 - bits)) - 1) & 0xffffffff;
    }
    var expected = 0, phraseBits = 0;
    for (var index = 1; index < count; index++) {
      final data = record(first + index);
      if (!_magic(data, 0, 'CDIC')) _badMobi();
      final total = _u32(data, 8), bits = _u32(data, 12);
      if (total <= 0 ||
          total > 1000000 ||
          bits < 1 ||
          bits > 16 ||
          index > 1 && (expected != total || phraseBits != bits)) {
        _badMobi();
      }
      expected = total;
      phraseBits = bits;
      final n = min(1 << bits, total - phrases.length);
      for (var phrase = 0; phrase < n; phrase++) {
        final start = 16 + _u16(data, 16 + phrase * 2);
        final size = _u16(data, start), length = size & 0x7fff;
        if (length > data.length - start - 2) _badMobi();
        phrases.add((
          Uint8List.sublistView(data, start + 2, start + 2 + length),
          size & 0x8000 != 0,
        ));
      }
    }
    if (phrases.length != expected) _badMobi();
  }
  final lookup = Uint32List(256),
      lower = Uint32List(33),
      upper = Uint32List(33);
  final phrases = <(Uint8List, bool)>[];

  int expand(Uint8List input, Uint8List output, int depth) {
    if (depth > 20 || input.length > 1000000) _badMobi();
    var written = 0;
    final end = input.length * 8;
    for (var position = 0; position < end;) {
      var window = 0;
      final start = position ~/ 8;
      for (var index = 0; index < 5; index++) {
        window =
            (window << 8) |
            (start + index < input.length ? input[start + index] : 0);
      }
      final code = (window >> (8 - position % 8)) & 0xffffffff;
      final quick = lookup[code >> 24];
      var bits = quick & 31;
      if (bits == 0) _badMobi();
      int maxCode;
      if (quick & 128 == 0) {
        while (bits <= 32 && code < lower[bits]) {
          bits++;
        }
        if (bits > 32) _badMobi();
        maxCode = upper[bits];
      } else {
        maxCode = ((((quick >> 8) + 1) << (32 - bits)) - 1) & 0xffffffff;
      }
      position += bits;
      if (position > end) break;
      if (code > maxCode) _badMobi();
      final phraseIndex = (maxCode - code) >> (32 - bits);
      if (phraseIndex >= phrases.length) _badMobi();
      final phrase = phrases[phraseIndex];
      if (!phrase.$2) {
        written += expand(
          phrase.$1,
          Uint8List.sublistView(output, written),
          depth + 1,
        );
      } else {
        if (phrase.$1.length > output.length - written) _badMobi();
        output.setRange(written, written + phrase.$1.length, phrase.$1);
        written += phrase.$1.length;
      }
    }
    return written;
  }
}
