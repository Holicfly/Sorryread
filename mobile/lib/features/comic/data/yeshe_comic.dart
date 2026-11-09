import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html;
import 'package:path_provider/path_provider.dart';

import '../../../data/book_source.dart';
import '../../../data/sync_repository.dart';
import '../../discover/data/yeshe_index.dart';
import '../../reader/data/reader_repository.dart';
import '../../reader/data/reader_source.dart';

const _host = 'yeshezy1.com';
const _imageHost = 'coms3.ejhx7q0rrrnhamudki.com';
final _detailPath = RegExp(r'^/voddetail/(\d+)\.html$');
final _chapterPath = RegExp(r'^/vodplay/(\d+)-\d+-\d+\.html$');

bool _https(Uri uri) =>
    uri.scheme == 'https' && uri.userInfo.isEmpty && uri.port == 443;

String? comicImageUrl(Uri base, String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null) return null;
  final uri = base.resolveUri(parsed);
  return _https(uri) && (uri.host == _host || uri.host == _imageHost)
      ? uri.toString()
      : null;
}

({String detail, String? chapter}) parseComicLink(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri != null && _https(uri) && uri.host == _host) {
    final detail = _detailPath.firstMatch(uri.path);
    final chapter = _chapterPath.firstMatch(uri.path);
    final id = (detail ?? chapter)?.group(1);
    if (id != null) {
      return (
        detail: 'https://$_host/voddetail/$id.html',
        chapter: chapter == null ? null : 'https://$_host${uri.path}',
      );
    }
  }
  throw const ReaderFailure('请粘贴夜社漫画的详情或章节网址。');
}

class ComicBook {
  const ComicBook(this.title, this.url, {this.cover, this.category = 4});

  factory ComicBook.fromMap(Map<Object?, Object?> row) {
    final url = parseComicLink(row['url'] as String).detail;
    return ComicBook(
      row['title'] as String,
      url,
      cover: comicImageUrl(Uri.parse(url), row['cover'] as String?),
      category: (row['category'] as int?) ?? 4,
    );
  }

  final String title, url;
  final String? cover;
  final int category;

  ShelfBook toShelfBook() => ShelfBook(
    '$yesheComicBookPrefix$url',
    {
      'kind': 'book',
      'title': title,
      'sourceId': yesheComicSource,
      'sourceName': '夜社漫画',
      'detailUrl': url,
      if (cover != null) 'coverUrl': cover,
      'chapterUrl': '',
      'chapterTitle': '',
      'progress': 0,
      'active': true,
      'updatedUtc': DateTime.now().toUtc().toIso8601String(),
    },
    false,
    false,
    null,
  );
}

class ComicDetail {
  const ComicDetail(this.book, this.labels, this.chapters);
  final ComicBook book;
  final List<String> labels;
  final List<ChapterLink> chapters;
}

ComicDetail parseComicDetail((String, String) input) {
  final (markup, url) = input;
  final doc = html.parse(markup);
  final base = Uri.parse(url);
  final title = doc.querySelector('.detailinfo h1')?.text.trim() ?? '';
  final cover = comicImageUrl(
    base,
    doc.querySelector('.detailpic img')?.attributes['src'],
  );
  final labels = doc
      .querySelectorAll('.detailinfo p')
      .map((node) => node.text.trim())
      .where((text) => text.isNotEmpty)
      .toList();
  final chapters = <String, ChapterLink>{};
  void add(String? href, String label) {
    final parsed = href == null ? null : Uri.tryParse(href);
    if (parsed == null) return;
    final link = base.resolveUri(parsed);
    if (!_https(link) || link.host != _host) return;
    final match = _chapterPath.firstMatch(link.path);
    if (match == null ||
        match.group(1) != _detailPath.firstMatch(base.path)?.group(1)) {
      return;
    }
    final target = 'https://$_host${link.path}';
    chapters.putIfAbsent(
      target,
      () => ChapterLink(
        label.isEmpty ? '第 ${chapters.length + 1} 话' : label,
        target,
      ),
    );
  }

  for (final row in doc.querySelectorAll('.cartoonlist .list')) {
    add(
      row.querySelector('a.btn[href]')?.attributes['href'],
      row.querySelector('.name')?.text.trim() ?? '',
    );
  }
  if (chapters.isEmpty) {
    for (final link in doc.querySelectorAll('.loading a.loadiultxt[href]')) {
      add(link.attributes['href'], link.text.trim());
    }
  }
  if (title.isEmpty || chapters.isEmpty) {
    throw const ReaderFailure('未识别到漫画详情或章节目录，请稍后重试。');
  }
  return ComicDetail(
    ComicBook(title, parseComicLink(url).detail, cover: cover),
    labels,
    chapters.values.toList(),
  );
}

List<String> parseComicPages((String, String) input) {
  final (markup, url) = input;
  final base = Uri.parse(url);
  final pages = <(int?, String)>[];
  final id = RegExp(r'^(\d+)P$');
  for (final img
      in html.parse(markup).querySelectorAll('.picslist .list > img')) {
    final src =
        comicImageUrl(base, img.attributes['src']) ??
        comicImageUrl(base, img.attributes['data-src']);
    if (src != null) {
      pages.add((int.tryParse(id.firstMatch(img.id)?.group(1) ?? ''), src));
    }
  }
  if (pages.isEmpty) throw const ReaderFailure('未识别到本话漫画图片。');
  final numbers = pages.map((page) => page.$1).toSet();
  if (numbers.length == pages.length && !numbers.contains(null)) {
    pages.sort((a, b) => a.$1!.compareTo(b.$1!));
  }
  return pages.map((page) => page.$2).toList();
}

class ComicCatalog {
  Future<({List<ComicBook> books, bool hasMore})> load(
    int category, {
    String? query,
    required int page,
    required int offset,
  }) async {
    final data = await YesheIndexRepository.channel
        .invokeMapMethod<String, dynamic>(query == null ? 'page' : 'search', {
          'comic': true,
          'category': category,
          'page': page,
          'query': ?query,
          'offset': offset,
        });
    final books = (data?['books'] as List? ?? [])
        .map((row) => ComicBook.fromMap(row as Map<Object?, Object?>))
        .toList();
    final onlineHasMore = data?['hasMore'] == true;
    final total = (data?['total'] as int?) ?? 0;
    return (
      books: books,
      hasMore: query == null
          ? onlineHasMore
          : books.isNotEmpty && offset + books.length < total,
    );
  }
}

final comicCatalogProvider = Provider((ref) => ComicCatalog());
final comicIndexProvider = Provider((ref) => YesheIndexRepository(comic: true));

final comicRepositoryProvider = FutureProvider.autoDispose<ComicRepository>((
  ref,
) async {
  final reader = await ref.watch(readerRepositoryProvider.future);
  final directory = await getTemporaryDirectory();
  return ComicRepository(reader, Directory('${directory.path}/yeshe_comic'));
});

class ComicRepository {
  ComicRepository(this.reader, this.cache);
  final ReaderRepository reader;
  final Directory cache;
  final _images = <String, Future<File>>{};
  final _waiting = Queue<Completer<void>>();
  int _inFlight = 0, _writes = 0;

  Future<String> _html(String url) async {
    final (markup, resolved) = await reader.fetchSearch(
      reader.source('yeshe', url),
      url,
    );
    if (parseComicLink(resolved) != parseComicLink(url)) {
      throw const ReaderFailure('漫画地址发生跳转，请重新打开作品。');
    }
    return markup;
  }

  Future<ComicDetail> detail(String url) async {
    final link = parseComicLink(url).detail;
    return compute(parseComicDetail, (await _html(link), link));
  }

  Future<List<String>> pages(String url) async {
    final link = parseComicLink(url).chapter;
    if (link == null) throw const ReaderFailure('漫画章节链接无效。');
    return compute(parseComicPages, (await _html(link), link));
  }

  Future<File> image(String url) => _images.putIfAbsent(
    url,
    () => _loadImage(url).whenComplete(() {
      _images.remove(url);
    }),
  );

  Future<File> _loadImage(String url) async {
    final target = File('${cache.path}/${reader.key(url)}.webp');
    if (await target.exists()) {
      unawaited(
        target
            .setLastModified(DateTime.now())
            .then<void>((_) {})
            .catchError((Object _) {}),
      );
      return target;
    }
    if (comicImageUrl(Uri.parse('https://$_host/'), url) != url) {
      throw const ReaderFailure('漫画图片地址无效。');
    }
    if (_inFlight >= 3) {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future;
    } else {
      _inFlight++;
    }
    try {
      final response = await reader.http.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
        ),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        if (bytes.length + chunk.length > 8 * 1024 * 1024) {
          throw const ReaderFailure('漫画图片过大。');
        }
        bytes.add(chunk);
      }
      final data = bytes.takeBytes();
      if (data.length < 12 ||
          String.fromCharCodes(data.take(4)) != 'RIFF' ||
          String.fromCharCodes(data.skip(8).take(4)) != 'WEBP') {
        throw const ReaderFailure('漫画图片格式异常。');
      }
      await cache.create(recursive: true);
      final temp = File('${target.path}.${identityHashCode(this)}.tmp');
      try {
        await temp.writeAsBytes(data);
        await temp.rename(target.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      if (_writes++ % 32 == 0) unawaited(_trim().catchError((Object _) {}));
      return target;
    } finally {
      if (_waiting.isEmpty) {
        _inFlight--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }

  Future<void> _trim() async {
    final files = <(File, FileStat)>[];
    await for (final entry in cache.list()) {
      if (entry is File && entry.path.endsWith('.webp')) {
        files.add((entry, await entry.stat()));
      }
    }
    var size = files.fold(0, (total, file) => total + file.$2.size);
    if (size <= 256 * 1024 * 1024) return;
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (file, stat) in files) {
      if (size <= 240 * 1024 * 1024) break;
      if (await file.exists()) await file.delete();
      size -= stat.size;
    }
  }
}
