import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html;

import '../../../app/dependencies.dart';
import '../../../data/sync_repository.dart';
import '../../reader/data/reader_repository.dart';
import '../../reader/data/reader_source.dart';

enum DiscoverMode {
  normal('normal'),
  mh('18mh'),
  yeshe('yeshe');

  const DiscoverMode(this.id);
  final String id;
}

const yesheBase = 'https://yeshezy1.com';
const yesheListUrl = '$yesheBase/arttype/5.html';

class DiscoverBook {
  const DiscoverBook(
    this.title,
    this.url,
    this.mode, {
    this.author = '',
    this.sourceId,
    this.sourceName,
  });
  final String title, url;
  final DiscoverMode mode;
  final String author;
  final String? sourceId, sourceName;

  ShelfBook toShelfBook({bool favorite = false}) => ShelfBook(
    'book:${sourceId ?? mode.id}|${urlKey(url)}',
    {
      'kind': 'book',
      'title': title,
      'sourceId': sourceId ?? mode.id,
      'sourceName':
          sourceName ?? (mode == DiscoverMode.yeshe ? '夜社' : '18mh小说网'),
      if (author.isNotEmpty) 'author': author,
      'detailUrl': url,
      'chapterUrl': '',
      'chapterTitle': '',
      'progress': 0,
      'active': true,
      'updatedUtc': DateTime.now().toUtc().toIso8601String(),
    },
    favorite,
    false,
    null,
  );
}

class DiscoverBatch {
  const DiscoverBatch(this.books, this.nextUrl, {this.total});
  final List<DiscoverBook> books;
  final String? nextUrl;
  final int? total;
}

String _text(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

bool _sameSite(Uri candidate, Uri base) =>
    candidate.scheme == 'https' &&
    candidate.host == base.host &&
    candidate.port == base.port &&
    candidate.userInfo.isEmpty;

/// Only follow result links and the next page of this exact query/category.
DiscoverBatch parseDiscoverBatch(DiscoverMode mode, String markup, String url) {
  if (mode == DiscoverMode.normal) {
    throw const ReaderFailure('普通搜索暂未开放。');
  }
  final document = html.parse(markup), base = Uri.parse(url);
  final night = mode == DiscoverMode.yeshe;
  final pattern = night
      ? RegExp(r'^/artdetail-\d+\.html$')
      : RegExp(r'^/novel/detail/[^/?#]+/?$');
  final nodes = document.querySelectorAll(
    night ? '.listwap a.info[href]' : 'a[href*="/novel/detail/"]',
  );
  final seen = <String>{}, books = <DiscoverBook>[];
  for (final node in nodes) {
    final value = elementUrl(node, url);
    if (value == null) continue;
    final uri = Uri.parse(value);
    if (!_sameSite(uri, base) || !pattern.hasMatch(uri.path)) continue;
    final title = _text(
      (night ? node.attributes['title'] : null) ??
          node.querySelector('.jm-rrow__title, h1, h2, h3, h4')?.text ??
          node.querySelector('img[alt]')?.attributes['alt'] ??
          node.attributes['title'] ??
          node.text,
    );
    if (title.isNotEmpty && seen.add(urlKey(value))) {
      books.add(DiscoverBook(title, value, mode));
    }
  }
  final count = night
      ? RegExp(r'共\s*(\d+)\s*条')
            .firstMatch(document.querySelector('.page_tip')?.text ?? '')
            ?.group(1)
      : document
            .querySelector('[data-search-result-count]')
            ?.attributes['data-search-result-count'];
  final total = int.tryParse(count ?? '');
  if (books.isEmpty && total != 0) {
    // A challenge page or changed markup must not silently mean "finished".
    throw const ReaderFailure('未识别到小说列表，请重试；网站结构可能已变化。');
  }
  final nextNode = document
      .querySelectorAll(
        night
            ? '.mac_pages a[href]'
            : '.jm-pg__step--next, a[rel="next"], a.pager-item',
      )
      .where(
        (n) =>
            n.attributes['rel'] == 'next' ||
            n.classes.contains('jm-pg__step--next') ||
            RegExp(
              r'下一页|^next$|^[›»]$',
              caseSensitive: false,
            ).hasMatch(_text(n.text)),
      )
      .firstOrNull;
  String? next = nextNode == null ? null : elementUrl(nextNode, url);
  if (next != null) {
    final uri = Uri.parse(next);
    final currentPath = base.path.replaceFirst(RegExp(r'/page/\d+/?$'), '');
    final validPath = night
        ? RegExp(r'^/arttype/5-\d+\.html$').hasMatch(uri.path)
        : uri.path.startsWith('$currentPath/page/') &&
              RegExp(r'/page/\d+/?$').hasMatch(uri.path);
    if (!_sameSite(uri, base) || !validPath || urlKey(next) == urlKey(url)) {
      next = null;
    }
  }
  return DiscoverBatch(books, next, total: total);
}

DiscoverBatch _parseBatch((DiscoverMode, String, String) input) =>
    parseDiscoverBatch(input.$1, input.$2, input.$3);

/// Canonical book URL plus an optional explicitly requested chapter.
(String, String?) parseYesheInput(String input) {
  final uri = Uri.tryParse(input.trim());
  final base = Uri.parse(yesheBase);
  if (uri == null || !_sameSite(uri, base)) {
    throw const ReaderFailure('请粘贴 yeshezy1.com 的小说或章节 HTTPS 网址。');
  }
  final detail = RegExp(r'^/artdetail-(\d+)\.html$').firstMatch(uri.path);
  final chapter = RegExp(r'^/artrss-(\d+)/nid/(\d+)\.html$')
      .firstMatch(uri.path);
  final id = detail?.group(1) ?? chapter?.group(1);
  if (id == null) {
    throw const ReaderFailure('网址格式无法识别，请使用小说详情页或章节页网址。');
  }
  return (
    '$yesheBase/artdetail-$id.html',
    chapter == null ? null : '$yesheBase${uri.path}',
  );
}

class DiscoverRepository {
  DiscoverRepository(this.reader);
  final ReaderRepository reader;

  Future<DiscoverBatch> fetch(DiscoverMode mode, String url) async {
    final id = mode.id;
    final source = reader.source(id, url);
    // Search lists are server-rendered. Never create a reader WebView here.
    final staticSource = SourceRule({...source.json, 'dynamic': false});
    final markup = await reader.fetch(staticSource, url);
    return compute(_parseBatch, (mode, markup, url));
  }

  Future<(DiscoverBook, String?)> resolveYeshe(String input) async {
    final (detail, chapter) = parseYesheInput(input);
    final source = reader.source('yeshe', detail);
    final markup = await reader.fetch(source, detail);
    final document = html.parse(markup);
    final title = _text(document.querySelector('.detailinfo h1')?.text ?? '');
    if (title.isEmpty || parseCatalogPage(source, markup, detail).isEmpty) {
      throw const ReaderFailure('未找到小说信息或章节目录，请检查网址后重试。');
    }
    return (DiscoverBook(title, detail, DiscoverMode.yeshe), chapter);
  }
}

final discoverRepositoryProvider = FutureProvider<DiscoverRepository>((
  ref,
) async {
  return DiscoverRepository(await ref.watch(readerRepositoryProvider.future));
});

class DiscoverHistory {
  DiscoverHistory(this.sync);
  final SyncRepository sync;
  Future<void> _tail = Future.value();
  String _key(DiscoverMode mode) => 'local:discover-history:${mode.id}';

  Future<List<String>> read(DiscoverMode mode) async {
    final raw = await sync.meta(_key(mode));
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).whereType<String>().toList();
    } on FormatException {
      return [];
    } on TypeError {
      return [];
    }
  }

  Future<void> _edit(DiscoverMode mode, void Function(List<String>) update) {
    final next = _tail.then((_) async {
      final values = await read(mode);
      update(values);
      await sync.setMeta(_key(mode), jsonEncode(values.take(50).toList()));
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> add(DiscoverMode mode, String value) => _edit(mode, (values) {
    final text = value.trim();
    if (text.isEmpty) return;
    values.remove(text);
    values.insert(0, text);
  });
  Future<void> remove(DiscoverMode mode, String value) =>
      _edit(mode, (values) => values.remove(value));
  Future<void> clear(DiscoverMode mode) =>
      _edit(mode, (values) => values.clear());
}

final discoverHistoryProvider = FutureProvider<DiscoverHistory>(
  (ref) async =>
      DiscoverHistory(await ref.watch(syncRepositoryProvider.future)),
);
final discoverHistoryEntriesProvider =
    FutureProvider.family<List<String>, DiscoverMode>(
      (ref, mode) async =>
          (await ref.watch(discoverHistoryProvider.future)).read(mode),
    );

class DiscoverResults extends ChangeNotifier {
  DiscoverResults(this.repository);
  final DiscoverRepository repository;
  DiscoverMode mode = DiscoverMode.mh;
  final books = <DiscoverBook>[];
  final _visited = <String>{}, _bookKeys = <String>{};
  String? nextUrl, error;
  int? total;
  bool loading = false, _disposed = false;
  int _generation = 0;

  Future<void> start(DiscoverMode newMode, String query) async {
    _generation++;
    mode = newMode;
    books.clear();
    _visited.clear();
    _bookKeys.clear();
    total = null;
    loading = false;
    error = null;
    nextUrl = mode == DiscoverMode.yeshe
        ? yesheListUrl
        : 'https://18mh.net/novel/search/${Uri.encodeComponent(query.trim())}';
    await loadMore();
  }

  Future<void> loadMore() async {
    if (_disposed || loading || nextUrl == null) return;
    final generation = _generation, url = nextUrl!;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final batch = await repository.fetch(mode, url);
      if (_disposed || generation != _generation) return;
      _visited.add(urlKey(url));
      for (final book in batch.books) {
        if (_bookKeys.add(urlKey(book.url))) books.add(book);
      }
      total = batch.total ?? total;
      nextUrl = batch.nextUrl;
      if (nextUrl != null && _visited.contains(urlKey(nextUrl!))) {
        nextUrl = null;
        error = '网站分页链接重复，已停止加载。';
      }
    } catch (e) {
      if (_disposed || generation != _generation) return;
      error = e is ReaderFailure ? e.message : '加载失败，请检查网络后重试。';
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
