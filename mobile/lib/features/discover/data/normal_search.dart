import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../../reader/data/reader_repository.dart';
import '../../reader/data/reader_source.dart';
import '../../reader/data/reader_selectors.dart';
import 'discover_repository.dart';

bool normalSource(SourceRule source) =>
    !const ['18mh', 'yeshe', 'wodushu'].contains(source.id) &&
    source.json['search'] is Map;

bool _sameSource(Uri candidate, Uri base) =>
    ['http', 'https'].contains(candidate.scheme) &&
    candidate.userInfo.isEmpty &&
    candidate.host.replaceFirst(RegExp(r'^(www|m)\.'), '') ==
        base.host.replaceFirst(RegExp(r'^(www|m)\.'), '') &&
    (!candidate.hasPort || candidate.port == 80 || candidate.port == 443);

String _clean(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
String _value(Element? node) =>
    _clean(node?.attributes['content'] ?? node?.text ?? '');

DiscoverBatch parseNormalSearch(SourceRule source, String markup, String url) {
  final search = Map<String, dynamic>.from(source.json['search'] as Map);
  final document = html.parse(markup);
  final base = Uri.parse(url),
      home = Uri.parse(source.json['baseUrl'] as String);
  if (!_sameSource(base, home)) throw const ReaderFailure('书源跳转到了其他网站，已停止解析。');
  final rows = select(document, search['resultSelector'] as String? ?? '');
  final books = <DiscoverBook>[];
  final seen = <String>{};
  String author(Element? node) {
    final text = _value(node)
        .replaceFirst(RegExp(r'^作\s*者\s*[:：]?\s*'), '')
        .trim();
    return const ['', '未知', '未知作者', '暂无', '—', '--'].contains(text) ? '' : text;
  }

  void add(String title, String? link, String writer) {
    if (title.isEmpty ||
        link == null ||
        !_sameSource(Uri.parse(link), home) ||
        !seen.add(urlKey(link))) {
      return;
    }
    books.add(
      DiscoverBook(
        title,
        link,
        DiscoverMode.normal,
        author: writer,
        sourceId: source.id,
        sourceName: source.json['name'] as String,
      ),
    );
  }

  for (final row in rows) {
    final titleSelector = search['titleLinkSelector'] as String? ?? '';
    final link = readerSelectWithin(row, titleSelector).firstOrNull;
    final writer = readerSelectWithin(
      row,
      search['authorSelector'] as String? ?? '',
    ).firstOrNull;
    add(
      _value(link),
      link == null ? null : elementUrl(link, url),
      author(writer),
    );
  }
  // Some sources redirect an exact-match search directly to the book detail.
  if (books.isEmpty &&
      parseCatalogPage(source, markup, url).isNotEmpty &&
      !RegExp(
        r'search|s\.php|waps\.php',
        caseSensitive: false,
      ).hasMatch(base.path)) {
    final detail = source.json['detail'] as Map;
    final titleNode =
        select(
          document,
          detail['titleSelector'] as String? ?? '',
        ).firstOrNull ??
        document.querySelector(
          'meta[property="og:novel:book_name"], meta[property="og:title"], h1',
        );
    final writer =
        select(
          document,
          detail['authorSelector'] as String? ?? '',
        ).firstOrNull ??
        document.querySelector('meta[property="og:novel:author"]');
    add(_value(titleNode), url, author(writer));
  }
  final selector = search['nextPageSelector'] as String? ?? '';
  final candidates = [
    if (selector.isNotEmpty) ...select(document, selector),
    ...document.querySelectorAll(
      '.pagelink a, #pagelink a, .pagination a, .page a, a[rel="next"]',
    ),
  ];
  final next = candidates
      .where(
        (node) =>
            node.attributes['rel'] == 'next' ||
            RegExp(
              r'下一页|下页|^next$|^[›»>]\s*>?$',
              caseSensitive: false,
            ).hasMatch(_clean(node.text)),
      )
      .firstOrNull;
  String? nextUrl = next == null ? null : elementUrl(next, url);
  if (nextUrl != null &&
      (!_sameSource(Uri.parse(nextUrl), home) ||
          urlKey(nextUrl) == urlKey(url))) {
    nextUrl = null;
  }
  if (books.isEmpty &&
      !RegExp(
        r'没有找到|未找到|(?:没有|暂无)(?:相关)?(?:小说|书籍|结果|记录|作品)|无相关|共\s*0|0\s*(?:条|本)\s*(?:结果|小说|记录)|no results',
        caseSensitive: false,
      ).hasMatch(document.body?.text ?? '')) {
    throw const ReaderFailure('没有识别到搜索结果，书源可能暂时不可用或规则已变化。');
  }
  return DiscoverBatch(books, nextUrl);
}

DiscoverBatch _parse((SourceRule, String, String) data) =>
    parseNormalSearch(data.$1, data.$2, data.$3);

class SourceSearchState extends ChangeNotifier {
  SourceSearchState(this.source);
  final SourceRule source;
  final books = <DiscoverBook>[];
  final visited = <String>{}, bookKeys = <String>{};
  bool loading = false, started = false;
  String? error, nextUrl;
  String get name => source.json['name'] as String;
  void _notify() => notifyListeners();
}

class NormalSearchController extends ChangeNotifier {
  NormalSearchController(this.reader)
    : sources = reader.rules
          .where(normalSource)
          .map(SourceSearchState.new)
          .toList();
  final ReaderRepository reader;
  final List<SourceSearchState> sources;
  int selectedIndex = 0, _generation = 0;
  bool _chosen = false, _disposed = false;
  CancelToken? _cancel;
  String query = '';
  SourceSearchState get selected => sources[selectedIndex];
  int get completed => sources.where((s) => s.started && !s.loading).length;
  int get totalResults => sources.fold(0, (n, s) => n + s.books.length);
  void _notify([SourceSearchState? source]) {
    if (_disposed) return;
    source?._notify();
    notifyListeners();
  }

  Future<void> start(String keyword) async {
    _cancel?.cancel();
    final generation = ++_generation;
    _cancel = CancelToken();
    query = keyword.trim();
    selectedIndex = 0;
    _chosen = false;
    for (final state in sources) {
      state.books.clear();
      state.visited.clear();
      state.bookKeys.clear();
      state.loading = false;
      state.started = false;
      state.error = null;
      state.nextUrl = null;
      state._notify();
    }
    _notify();
    var cursor = 0;
    Future<void> worker() async {
      while (!_disposed &&
          generation == _generation &&
          cursor < sources.length) {
        final index = cursor++;
        await _load(index, generation);
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
  }

  void selectSource(int index) {
    _chosen = true;
    if (selectedIndex == index) return;
    selectedIndex = index;
    _notify();
  }

  Future<void> loadMore() => _load(selectedIndex, _generation);

  Future<void> _load(int index, int generation) async {
    final state = sources[index];
    if (_disposed ||
        state.loading ||
        (state.visited.isNotEmpty && state.nextUrl == null) ||
        (state.started && state.error == null && state.nextUrl == null)) {
      return;
    }
    final search = state.source.json['search'] as Map;
    final first = state.visited.isEmpty;
    final url = first
        ? (search['uriTemplate'] as String).replaceAll(
            '{keyword}',
            Uri.encodeComponent(query),
          )
        : state.nextUrl!;
    final form = Map<String, String>.from(
      search['formFields'] as Map? ?? {},
    ).map((key, value) => MapEntry(key, value.replaceAll('{keyword}', query)));
    state.loading = true;
    state.error = null;
    _notify(state);
    try {
      final (markup, resolved) = await reader.fetchSearch(
        state.source,
        url,
        method: first
            ? (search['method'] as String? ?? 'GET').toUpperCase()
            : 'GET',
        form:
            first && (search['method'] as String? ?? '').toUpperCase() == 'POST'
            ? form
            : null,
        cancelToken: _cancel,
      );
      final batch = await compute(_parse, (state.source, markup, resolved));
      if (_disposed || generation != _generation) return;
      state.visited.add(urlKey(url));
      state.visited.add(urlKey(resolved));
      for (final book in batch.books) {
        if (state.bookKeys.add(urlKey(book.url))) state.books.add(book);
      }
      state.nextUrl = batch.nextUrl;
      if (state.nextUrl != null &&
          state.visited.contains(urlKey(state.nextUrl!))) {
        state.nextUrl = null;
        state.error = '书源重复返回同一分页，已停止加载。';
      }
      if (!_chosen && state.books.isNotEmpty) {
        _chosen = true;
        selectedIndex = index;
      }
    } catch (error) {
      if (_disposed || generation != _generation) return;
      state.error = error is ReaderFailure ? error.message : '搜索失败，请检查网络后重试。';
    } finally {
      if (!_disposed && generation == _generation) {
        state.loading = false;
        state.started = true;
        _notify(state);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancel?.cancel();
    for (final source in sources) {
      source.dispose();
    }
    super.dispose();
  }
}
