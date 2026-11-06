import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart' show InputFileStream;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

part 'local_book_mobi.dart';

const localBookSource = 'local';
const localBookUrl = 'https://local.sorryread.invalid/';
const maxBookBytes = 200 * 1024 * 1024;
const maxUnits = 25000;
const bookPicker = MethodChannel('sorryread/local_books');
const bookFormats = {'txt', 'epub', 'mobi'};

bool isBookHash(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
String localBookId(String hash) => 'book:local|$localBookUrl$hash';

class BookBlock {
  const BookBlock(this.text, [this.image]);
  final String text;
  final String? image;

  Map<String, dynamic> toJson() => {'text': text, 'image': image};
  factory BookBlock.fromJson(Map<String, dynamic> value) =>
      BookBlock(value['text'] as String, value['image'] as String?);
}

class BookUnit {
  const BookUnit(this.title, this.address, this.blocks);
  final String title, address;
  final List<BookBlock> blocks;
}

class ParsedBook {
  ParsedBook(this.title, this.comic, this.units, [this.cover]);
  final String title;
  final bool comic;
  final List<BookUnit> units;
  final Uint8List? cover;
  late final String catalogHash = sha256
      .convert(utf8.encode(units.map((unit) => unit.address).join('\n')))
      .toString();
}

String bookTitle(String value, String fallback) {
  var title = value.trim().isEmpty ? fallback.trim() : value.trim();
  if (title.isEmpty) title = '未命名图书';
  if (title.length <= 512) return title;
  return title.substring(0, _highSurrogate(title.codeUnitAt(511)) ? 511 : 512);
}

Future<ParsedBook> parseBookFile(
  String path,
  String format,
  String fallback,
) async {
  final file = File(path);
  final length = await file.length();
  if (length <= 0 || length > maxBookBytes) {
    throw const FormatException('文件为空或超过 200 MiB');
  }
  if (format == 'txt') {
    final decoded = await Isolate.run(
      () => _decodeTxt(File(path).readAsBytesSync()),
    );
    final text =
        decoded ??
        await bookPicker.invokeMethod<String>(
          'decodeGb18030',
          await file.readAsBytes(),
        );
    if (text == null) throw const FormatException('无法识别 TXT 编码');
    return Isolate.run(
      () => _validBook(fallback, false, splitBookText(text, 'txt'), fallback),
    );
  }
  return Isolate.run(() {
    return switch (format) {
      'epub' => _withEpub(path, (epub) => _parseEpub(epub, fallback)),
      'mobi' => _parseMobi(File(path).readAsBytesSync(), fallback),
      _ => throw const FormatException('仅支持 TXT、EPUB、MOBI'),
    };
  });
}

String? _decodeTxt(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    return utf8.decode(Uint8List.sublistView(bytes, 3));
  }
  if (bytes.length >= 2 &&
      (bytes[0] == 0xff && bytes[1] == 0xfe ||
          bytes[0] == 0xfe && bytes[1] == 0xff)) {
    if (bytes.length.isOdd) throw const FormatException('UTF-16 长度无效');
    final data = ByteData.sublistView(bytes);
    final order = bytes[0] == 0xff ? Endian.little : Endian.big;
    final chars = List.generate(
      (bytes.length - 2) ~/ 2,
      (i) => data.getUint16(2 + i * 2, order),
    );
    for (var i = 0; i < chars.length; i++) {
      if (_highSurrogate(chars[i])) {
        if (++i == chars.length || chars[i] < 0xdc00 || chars[i] > 0xdfff) {
          throw const FormatException('UTF-16 字符无效');
        }
      } else if (chars[i] >= 0xdc00 && chars[i] <= 0xdfff) {
        throw const FormatException('UTF-16 字符无效');
      }
    }
    return String.fromCharCodes(chars);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

bool _highSurrogate(int value) => value >= 0xd800 && value <= 0xdbff;
final _heading = RegExp(
  r'^[^\S\n]*第[0-9一两二三四五六七八九十百千零〇壹贰叁肆伍陆柒捌玖拾]+[册卷部章回节][^\n]*$',
  multiLine: true,
);

List<BookUnit> splitBookText(String input, String prefix) {
  final text = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final units = <BookUnit>[];
  var start = 0;
  String? title;
  void addParts(int end, String? chapter) {
    var part = 1;
    final long = end - start > 5000;
    while (start < end) {
      var next = min(end, start + 5000);
      if (next < end) {
        final newline = text.lastIndexOf('\n', next - 1);
        if (newline >= start + 2500) {
          next = newline + 1;
        } else if (_highSurrogate(text.codeUnitAt(next - 1))) {
          next--;
        }
      }
      final body = text.substring(start, next).trim();
      if (body.isNotEmpty) {
        if (units.length >= maxUnits) throw const FormatException('章节条目过多');
        final name = chapter == null
            ? '第${units.length + 1}章'
            : long
            ? '$chapter 第${part++}部分'
            : chapter;
        units.add(BookUnit(name, '$prefix:$start:$next', [BookBlock(body)]));
      }
      start = next;
    }
  }

  for (final match in _heading.allMatches(text)) {
    final heading = match[0]!.trim();
    if (heading.length >= 30) continue;
    addParts(match.start, title ?? '前言');
    title = heading;
    start = match.end;
    if (start < text.length && text.codeUnitAt(start) == 10) start++;
  }
  addParts(text.length, title);
  return units;
}

ParsedBook _validBook(
  String title,
  bool comic,
  List<BookUnit> units,
  String fallback, [
  Uint8List? cover,
]) {
  if (units.isEmpty || units.length > maxUnits)
    throw const FormatException('图书没有可读内容或目录过长');
  return ParsedBook(bookTitle(title, fallback), comic, units, cover);
}

const _entryLimit = 24 * 1024 * 1024;
bool _imagePath(String path) => RegExp(
  r'\.(jpe?g|png|gif|bmp|tiff?)$',
  caseSensitive: false,
).hasMatch(path);

String? _entryPath(String parent, String? href) {
  if (href == null || href.trim().isEmpty) return null;
  final relative = href.split(RegExp(r'[?#]')).first;
  if (relative.isEmpty) return parent.isEmpty ? null : parent;
  if (relative.startsWith('/') ||
      relative.contains(':') ||
      relative.contains('\\'))
    return null;
  final slash = parent.lastIndexOf('/');
  final parts = slash < 0 ? <String>[] : parent.substring(0, slash).split('/');
  for (final raw in relative.split('/')) {
    final escaped = raw
        .replaceAll(RegExp(r'%(?![0-9a-fA-F]{2})'), '%25')
        .replaceAllMapped(
          RegExp(r'[^\x00-\x7F]+'),
          (match) => Uri.encodeComponent(match[0]!),
        );
    final String part;
    try {
      part = Uri.decodeComponent(escaped);
    } on ArgumentError {
      return null;
    }
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      if (part.contains(RegExp(r'[/\\:\x00]'))) return null;
      parts.add(part);
    }
  }
  return parts.isEmpty ? null : parts.join('/');
}

class _EpubArchive {
  _EpubArchive(Archive archive) {
    if (archive.length > 50000 ||
        archive.files.fold<int>(0, (sum, file) => sum + file.size) >
            512 * 1024 * 1024) {
      throw const FormatException('EPUB 解压资源超出上限');
    }
    for (final file in archive.files) {
      if (file.isFile && !file.isSymbolicLink)
        files.putIfAbsent(file.name, () => file);
    }
  }
  final files = <String, ArchiveFile>{};
  bool readable(String path) {
    final file = files[path];
    return file != null && file.size > 0 && file.size <= _entryLimit;
  }

  Uint8List content(String path) {
    final file = files[path];
    if (file == null || !readable(path))
      throw const FormatException('EPUB 缺少可读资源');
    final bytes = file.content as List<int>;
    if (bytes.length != file.size) throw const FormatException('EPUB 资源长度异常');
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }

  String text(String path) => utf8.decode(content(path));
}

T _withEpub<T>(String path, T Function(_EpubArchive) action) {
  final input = InputFileStream(path);
  try {
    return action(_EpubArchive(ZipDecoder().decodeBuffer(input)));
  } finally {
    input.closeSync();
  }
}

Iterable<XmlElement> _elements(XmlNode node, String local) => node.descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == local);

ParsedBook _parseEpub(_EpubArchive epub, String fallback) {
  XmlDocument xml(String path) => XmlDocument.parse(epub.text(path));
  if (epub.files.containsKey('META-INF/encryption.xml') &&
      _elements(xml('META-INF/encryption.xml'), 'EncryptionMethod').any(
        (item) => !const {
          'http://www.idpf.org/2008/embedding',
          'http://ns.adobe.com/pdf/enc#RC',
        }.contains(item.getAttribute('Algorithm')),
      )) {
    throw const FormatException('此 EPUB 含加密正文或图片');
  }
  final path = _entryPath(
    '',
    _elements(
      xml('META-INF/container.xml'),
      'rootfile',
    ).firstOrNull?.getAttribute('full-path'),
  );
  if (path == null) throw const FormatException('EPUB 缺少出版清单');
  final opf = xml(path);
  final items = <String, (String, String, List<String>)>{};
  for (final item in _elements(opf, 'item')) {
    final id = item.getAttribute('id'),
        href = _entryPath(path, item.getAttribute('href'));
    if (id != null && id.isNotEmpty && href != null) {
      items.putIfAbsent(
        id,
        () => (
          href,
          item.getAttribute('media-type') ?? '',
          (item.getAttribute('properties') ?? '').split(' '),
        ),
      );
    }
  }
  final spine = _elements(opf, 'spine').firstOrNull;
  if (spine == null) throw const FormatException('EPUB 缺少阅读顺序');
  final titles = <String, String>{};
  void addTitle(String parent, String? href, String? title) {
    final entry = _entryPath(parent, href);
    if (entry != null && title != null && title.trim().isNotEmpty) {
      titles.putIfAbsent(entry, () => title.trim());
    }
  }

  final nav = items.values
      .where((entry) => entry.$3.contains('nav'))
      .firstOrNull;
  if (nav != null && epub.files.containsKey(nav.$1)) {
    final document = html.parse(epub.text(nav.$1));
    final nodes = document.querySelectorAll('nav');
    final toc =
        nodes
            .where(
              (node) => (node.attributes['epub:type'] ?? '')
                  .split(' ')
                  .contains('toc'),
            )
            .firstOrNull ??
        nodes.firstOrNull;
    for (final link in toc?.querySelectorAll('a[href]') ?? <dom.Element>[]) {
      addTitle(nav.$1, link.attributes['href'], link.text);
    }
  }
  final ncx = items[spine.getAttribute('toc')];
  if (ncx != null && epub.files.containsKey(ncx.$1)) {
    for (final node in _elements(xml(ncx.$1), 'navPoint')) {
      final children = node.childElements;
      addTitle(
        ncx.$1,
        children
            .where((x) => x.name.local == 'content')
            .firstOrNull
            ?.getAttribute('src'),
        children
            .where((x) => x.name.local == 'navLabel')
            .firstOrNull
            ?.innerText,
      );
    }
  }
  final metadata = _elements(opf, 'meta');
  final fixed = metadata.any(
    (node) =>
        node.getAttribute('property') == 'rendition:layout' &&
        node.innerText.trim() == 'pre-paginated',
  );
  final coverId = metadata
      .where((node) => node.getAttribute('name') == 'cover')
      .firstOrNull
      ?.getAttribute('content');
  final coverPath =
      items.values
          .where((entry) => entry.$3.contains('cover-image'))
          .firstOrNull
          ?.$1 ??
      items[coverId]?.$1;
  final cover =
      coverPath != null &&
          _imagePath(coverPath) &&
          epub.readable(coverPath) &&
          epub.files[coverPath]!.size <= 6 * 1024 * 1024
      ? epub.content(coverPath)
      : null;
  var index = -1, imagePages = 0, textUnits = 0, textSize = 0;
  final units = <BookUnit>[];
  for (final reference in spine.childElements.where(
    (element) => element.name.local == 'itemref',
  )) {
    index++;
    if (reference.getAttribute('linear') == 'no') continue;
    final item = items[reference.getAttribute('idref')];
    if (item == null || !epub.files.containsKey(item.$1))
      throw const FormatException('EPUB 缺少正文资源');
    var title = titles[item.$1];
    final blocks = <BookBlock>[];
    if (_imagePath(item.$1) && epub.readable(item.$1)) {
      blocks.add(BookBlock('', item.$1));
    } else if (const {
      'application/xhtml+xml',
      'text/html',
      'image/svg+xml',
    }.contains(item.$2)) {
      final doc = html.parse(epub.text(item.$1));
      title ??= doc.querySelector('h1,h2,h3,title')?.text;
      final buffer = StringBuffer();
      void flush() {
        final value = buffer.toString().trim();
        buffer.clear();
        if (value.isNotEmpty) blocks.add(BookBlock(value));
      }

      void visit(dom.Node node, int depth) {
        if (depth > 256) throw const FormatException('EPUB 页面结构过深');
        if (node is dom.Text) {
          buffer.write(node.data);
          return;
        }
        if (node is! dom.Element ||
            const {
              'script',
              'style',
              'template',
              'head',
            }.contains(node.localName))
          return;
        if (node.localName == 'img' || node.localName == 'image') {
          final attrs = node.attributes;
          final image = _entryPath(
            item.$1,
            attrs['src'] ??
                attrs['href'] ??
                attrs.entries
                    .where((x) => x.key.toString().endsWith(':href'))
                    .firstOrNull
                    ?.value,
          );
          if (image != null && _imagePath(image) && epub.readable(image)) {
            flush();
            blocks.add(BookBlock('', image));
          }
          return;
        }
        final paragraph = _epubBlocks.contains(node.localName);
        if (paragraph) buffer.write('\n\n');
        if (node.localName == 'br' || node.localName == 'hr')
          buffer.write('\n');
        for (final child in node.nodes) {
          visit(child, depth + 1);
        }
        if (paragraph) buffer.write('\n\n');
      }

      if (doc.body != null) visit(doc.body!, 0);
      flush();
    }
    if (blocks.isEmpty) continue;
    if (blocks.every((block) => block.image != null)) {
      for (var i = 0; i < blocks.length; i++) {
        // RFC 3986 unreserved characters match the desktop component encoder.
        final escaped = Uri.encodeComponent(blocks[i].image!).replaceAllMapped(
          RegExp(r"[!'()*]"),
          (match) =>
              '%${match[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
        );
        units.add(
          BookUnit('第 ${units.length + 1} 页', 'epub:$index:image:$i:$escaped', [
            blocks[i],
          ]),
        );
      }
      imagePages += blocks.length;
    } else {
      textUnits++;
      textSize += blocks.fold(0, (size, block) => size + block.text.length);
      units.add(
        BookUnit(
          bookTitle(title ?? '', '第 ${units.length + 1} 节'),
          'epub:$index',
          blocks,
        ),
      );
    }
    if (units.length > maxUnits || textSize > 60000000)
      throw const FormatException('EPUB 正文或目录超出上限');
  }
  return _validBook(
    _elements(opf, 'title').firstOrNull?.innerText ?? fallback,
    imagePages > 0 && (textUnits == 0 || fixed || imagePages >= textUnits * 3),
    units,
    fallback,
    cover,
  );
}

const _epubBlocks = {
  'p',
  'div',
  'section',
  'article',
  'li',
  'blockquote',
  'pre',
  'tr',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
};

Future<Map<String, Uint8List>> readBookImages(
  String epub,
  List<String> entries,
) => Isolate.run(
  () => _withEpub(epub, (archive) {
    final images = <String, Uint8List>{};
    var size = 0;
    for (final entry in entries) {
      final file = archive.files[entry];
      if (file == null || size + file.size > 80 * 1024 * 1024) continue;
      try {
        final bytes = archive.content(entry);
        size += bytes.length;
        images[entry] = bytes;
      } on FormatException {
        // Keep readable blocks when one illustration is damaged.
      }
    }
    return images;
  }),
);
