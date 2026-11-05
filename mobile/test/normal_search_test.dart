import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/discover/data/normal_search.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';

SourceRule normalRule(String id, {String method = 'Post'}) => SourceRule({
  'id': id,
  'name': '$id书源',
  'baseUrl': 'https://$id.invalid/',
  'dynamic': false,
  'detail': <String, dynamic>{},
  'catalog': {'itemSelector': '#chapters a'},
  'chapter': {'contentSelector': '#content', 'titleSelector': 'h1'},
  'search': {
    'uriTemplate': 'https://$id.invalid/search?q={keyword}',
    'method': method,
    'formFields': {'s': '{keyword}'},
    'resultSelector': '#results tr',
    'titleLinkSelector': 'td:nth-child(1) a',
    'authorSelector': 'td:nth-child(2)',
    'nextPageSelector': '#pages a:not(.ngroup)',
  },
});
String normalHtml(String id, {bool next = true, bool author = true}) =>
    '''
<table id="results"><tr><td><a href="/book/1">山间来信</a></td><td>${author ? '作者：甲' : ''}</td></tr>
<tr><td><a href="/book/1">重复书名</a></td><td>作者：甲</td></tr>
<tr><td><a href="https://evil.invalid/book/4">外站</a></td><td>乙</td></tr></table>
<div id="pagelink"><a class="ngroup" href="/search?page=2">${next ? '下一页' : '尾页'}</a></div>''';

class NormalFixtureReader extends ReaderRepository {
  NormalFixtureReader(super.directory, super.rules);
  final requests = <(String, String, Map<String, String>?)>[];
  final failOnce = <String>{};
  @override
  Future<(String, String)> fetchSearch(
    SourceRule source,
    String url, {
    String method = 'GET',
    Map<String, String>? form,
    CancelToken? cancelToken,
  }) async {
    requests.add((source.id, method, form));
    if (failOnce.remove(source.id)) throw const ReaderFailure('合成网络错误');
    if (Uri.parse(url).queryParameters['page'] == '2') {
      return (
        '<table id="results"><tr><td><a href="/book/2">湖畔故事</a></td><td></td></tr></table>',
        url,
      );
    }
    return (normalHtml(source.id), url);
  }
}

class DelayedNormalReader extends NormalFixtureReader {
  DelayedNormalReader(super.directory, super.rules);
  final gates = <String, Completer<void>>{};
  final empty = <String>{};

  @override
  Future<(String, String)> fetchSearch(
    SourceRule source,
    String url, {
    String method = 'GET',
    Map<String, String>? form,
    CancelToken? cancelToken,
  }) async {
    await gates[source.id]?.future;
    if (empty.contains(source.id)) return ('没有找到相关小说', url);
    return super.fetchSearch(
      source,
      url,
      method: method,
      form: form,
      cancelToken: cancelToken,
    );
  }
}

Future<void> waitForSearch(
  NormalSearchController controller,
  bool Function() ready,
) async {
  if (ready()) return;
  final done = Completer<void>();
  void changed() {
    if (ready() && !done.isCompleted) done.complete();
  }

  controller.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 5));
  } finally {
    controller.removeListener(changed);
  }
}

class _RedirectAdapter implements HttpClientAdapter {
  _RedirectAdapter(this.location, {this.status = 302});
  final String location;
  final int status;
  final methods = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    methods.add(options.method);
    return methods.length == 1
        ? ResponseBody.fromString(
            '',
            status,
            headers: {
              'location': [location],
            },
          )
        : ResponseBody.fromBytes(
            utf8.encode('搜索结果'),
            200,
            headers: {
              'content-type': ['text/html; charset=utf-8'],
            },
          );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('first nonempty source wins once; a new keyword resets the choice and manual choice wins pending responses', () async {
    final dir = await Directory.systemTemp.createTemp('normal-race-');
    final reader = DelayedNormalReader(dir, [
      normalRule('a'),
      normalRule('b'),
      normalRule('c'),
    ]);
    final controller = NormalSearchController(reader);
    addTearDown(() async {
      controller.dispose();
      reader.dispose();
      await dir.delete(recursive: true);
    });
    reader.empty.add('a');
    reader.gates['b'] = Completer<void>();
    reader.gates['c'] = Completer<void>();
    final first = controller.start('第一次');
    await waitForSearch(controller, () => controller.sources[0].started);
    expect(controller.totalResults, 0);
    reader.gates['c']!.complete();
    await waitForSearch(controller, () => controller.sources[2].started);
    expect(controller.selectedIndex, 2);
    reader.gates['b']!.complete();
    await first;
    expect(controller.selectedIndex, 2);

    reader.gates['b'] = Completer<void>();
    reader.gates['c'] = Completer<void>();
    final second = controller.start('第二次');
    expect(controller.selectedIndex, 0);
    controller.selectSource(1);
    reader.gates['c']!.complete();
    await waitForSearch(controller, () => controller.sources[2].started);
    expect(controller.selectedIndex, 1);
    reader.gates['b']!.complete();
    await second;
    expect(controller.selectedIndex, 1);
  });
  test('browser-style POST redirects follow same-site GET; 307 preserves POST and external redirects stop', () async {
    final directory = await Directory.systemTemp.createTemp('search-redirect-');
    final reader = ReaderRepository(directory, [normalRule('a')]);
    addTearDown(() async {
      reader.dispose();
      await directory.delete(recursive: true);
    });
    for (final status in [302, 307]) {
      final adapter = _RedirectAdapter('/search/result', status: status);
      reader.http.httpClientAdapter = adapter;
      final result = await reader.fetchSearch(
        normalRule('a'),
        'https://a.invalid/search',
        method: 'POST',
        form: {'s': '中文'},
      );
      expect(result, ('搜索结果', 'https://a.invalid/search/result'));
      expect(adapter.methods, ['POST', status == 302 ? 'GET' : 'POST']);
    }
    final adapter = _RedirectAdapter('https://external.invalid/search');
    reader.http.httpClientAdapter = adapter;
    await expectLater(
      reader.fetchSearch(
        normalRule('a'),
        'https://a.invalid/search',
        method: 'POST',
      ),
      throwsA(isA<ReaderFailure>()),
    );
    expect(adapter.methods, ['POST']);
  });
  test('table rows preserve author cell indices, hide missing authors, reject external links', () {
    final rule = normalRule('test');
    final result = parseNormalSearch(
      rule,
      normalHtml('test'),
      'https://test.invalid/search',
    );
    expect(result.books, hasLength(1));
    expect(result.books.single.author, '甲');
    expect(result.nextUrl, 'https://test.invalid/search?page=2');
    expect(result.books.single.toShelfBook().metadata['sourceId'], 'test');
    expect(result.books.single.toShelfBook().metadata['author'], '甲');
    expect(
      parseNormalSearch(
        rule,
        normalHtml('test', author: false),
        'https://test.invalid/search',
      ).books.single.author,
      '',
    );
  });
  test('source results and paging remain independent; failed source retries its own initial POST', () async {
    final dir = await Directory.systemTemp.createTemp('normal-search-');
    final reader = NormalFixtureReader(dir, [
      normalRule('a'),
      normalRule('b'),
      normalRule('wodushu'),
    ]);
    final controller = NormalSearchController(reader);
    addTearDown(() async {
      controller.dispose();
      reader.dispose();
      await dir.delete(recursive: true);
    });
    reader.failOnce.add('b');
    await controller.start('中文 关键词');
    expect(controller.sources, hasLength(2));
    expect(controller.sources[0].books, hasLength(1));
    expect(controller.sources[1].error, isNotNull);
    expect(reader.requests.first.$2, 'POST');
    expect(reader.requests.first.$3, {'s': '中文 关键词'});
    controller.selectSource(1);
    await controller.loadMore();
    expect(controller.selected.error, isNull);
    expect(controller.selected.books.single.author, '甲');
    controller.selectSource(0);
    await controller.loadMore();
    expect(controller.selected.books.map((b) => b.title), ['山间来信', '湖畔故事']);
    expect(controller.selected.nextUrl, isNull);
    expect(controller.sources[1].books, hasLength(1));
    expect(reader.requests.last.$2, 'GET');
  });
}
