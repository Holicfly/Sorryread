import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/discover/data/discover_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';

import 'reader_parsing_test.dart';
import 'support/test_runtime.dart';

const searchUrl = 'https://18mh.net/novel/search/test';
const searchMarkup = '''<main data-search-result-count="3">
<a href="/novel/detail/1"><span class="jm-rrow__title">山间来信</span><span>其他信息</span></a>
<a href="/novel/detail/1"><img alt="重复封面"></a>
<a href="https://evil.invalid/novel/detail/7">站外</a>
<a href="/comic/detail/7">其他内容</a>
<a class="jm-pg__step--next" href="/novel/search/test/page/2">下一页<span>（第 2 页）</span></a></main>''';
const nightMarkup = '''<div class="listwap"><div class="list">
<a class="pic" href="/artdetail-42.html">封面</a>
<a class="info" title="湖畔故事" href="/artdetail-42.html"><div>杂项</div></a>
</div></div><a href="/artdetail-9.html">侧栏推荐</a>
<div class="mac_pages"><div class="page_tip">共61条数据,当前1/3页</div>
<a href="/arttype/5-1.html">上一页</a><a href="/arttype/5-2.html">下一页</a></div>''';

class FakeDiscoverRepository extends DiscoverRepository {
  FakeDiscoverRepository(super.reader);
  final requests = <String>[];
  final pending = <String, Completer<DiscoverBatch>>{};
  @override
  Future<DiscoverBatch> fetch(DiscoverMode mode, String url) {
    requests.add(url);
    return pending.putIfAbsent(url, Completer<DiscoverBatch>.new).future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('current search markup gives titles only, deduplicates and follows exact query', () {
    final batch = parseDiscoverBatch(DiscoverMode.mh, searchMarkup, searchUrl);
    expect(batch.books.map((b) => b.title), ['山间来信']);
    expect(batch.total, 3);
    expect(batch.nextUrl, '$searchUrl/page/2');
    for (final invalid in [
      'https://evil.invalid/novel/search/test/page/2',
      '/novel/search/other/page/2',
      'https://18mh.net:9443/novel/search/test/page/2',
    ]) {
      expect(
        parseDiscoverBatch(
          DiscoverMode.mh,
          searchMarkup.replaceAll('/novel/search/test/page/2', invalid),
          searchUrl,
        ).nextUrl,
        isNull,
      );
    }
  });
  test(
    'night list excludes picture/recommendation links and reads next page',
    () {
      final batch = parseDiscoverBatch(
        DiscoverMode.yeshe,
        nightMarkup,
        yesheListUrl,
      );
      expect(batch.books.single.title, '湖畔故事');
      expect(batch.nextUrl, '$yesheBase/arttype/5-2.html');
      expect(batch.total, 61);
      expect(
        parseDiscoverBatch(
          DiscoverMode.yeshe,
          nightMarkup.replaceAll('下一页', '尾页'),
          yesheListUrl,
        ).nextUrl,
        isNull,
      );
    },
  );
  test('empty query results differ from a challenge or broken page', () {
    expect(
      parseDiscoverBatch(
        DiscoverMode.mh,
        '<main data-search-result-count="0"></main>',
        searchUrl,
      ).books,
      isEmpty,
    );
    expect(
      () =>
          parseDiscoverBatch(DiscoverMode.mh, '<h1>Challenge</h1>', searchUrl),
      throwsA(isA<ReaderFailure>()),
    );
  });
  test('night direct URLs preserve requested chapter and canonicalize book identity', () {
    expect(parseYesheInput(' $yesheBase/artrss-42/nid/3.html?ref=1#here '), (
      '$yesheBase/artdetail-42.html',
      '$yesheBase/artrss-42/nid/3.html',
    ));
    expect(parseYesheInput('$yesheBase/artdetail-42.html'), (
      '$yesheBase/artdetail-42.html',
      null,
    ));
    for (final invalid in [
      '湖畔故事',
      'http://yeshezy1.com/artdetail-42.html',
      'https://yeshezy1.com.evil.invalid/artdetail-42.html',
      'https://user@yeshezy1.com/artdetail-42.html',
      '$yesheBase:9443/artdetail-42.html',
      '$yesheBase/arttype/5.html',
    ]) {
      expect(() => parseYesheInput(invalid), throwsA(isA<ReaderFailure>()));
    }
    final book = const DiscoverBook(
      '湖畔故事',
      '$yesheBase/artdetail-42.html',
      DiscoverMode.yeshe,
    ).toShelfBook();
    expect(book.id, 'book:yeshe|$yesheBase/artdetail-42.html');
    expect(book.isSpecialSource, isTrue);
    expect(book.favorite, isFalse);
  });
  test('three histories persist independently and serialize simultaneous edits without sync events', () async {
    final sync = await testRepository();
    addTearDown(sync.close);
    final history = DiscoverHistory(sync);
    final recordsBefore = await sync.records();
    await Future.wait([
      history.add(DiscoverMode.mh, '山间来信'),
      history.add(DiscoverMode.mh, '湖畔故事'),
      history.add(DiscoverMode.yeshe, '$yesheBase/artdetail-42.html'),
      history.add(DiscoverMode.normal, '普通记录'),
    ]);
    await history.add(DiscoverMode.mh, '山间来信');
    final reopened = DiscoverHistory(sync);
    expect(await reopened.read(DiscoverMode.mh), ['山间来信', '湖畔故事']);
    await reopened.remove(DiscoverMode.mh, '山间来信');
    expect(await reopened.read(DiscoverMode.mh), ['湖畔故事']);
    await reopened.clear(DiscoverMode.mh);
    expect(await reopened.read(DiscoverMode.mh), isEmpty);
    expect(await reopened.read(DiscoverMode.normal), ['普通记录']);
    expect(await reopened.read(DiscoverMode.yeshe), [
      '$yesheBase/artdetail-42.html',
    ]);
    expect(await sync.records(), hasLength(recordsBefore.length));
    expect(await sync.meta('seq'), '0');
  });
  test('pagination ignores stale query, retries failed page and stops after last page', () async {
    final dir = await Directory.systemTemp.createTemp('discover-test-');
    addTearDown(() => dir.delete(recursive: true));
    final reader = FixtureReaderRepository(dir, [], {});
    addTearDown(reader.dispose);
    final repo = FakeDiscoverRepository(reader);
    final state = DiscoverResults(repo);
    addTearDown(state.dispose);
    final old = state.start(DiscoverMode.mh, 'old');
    final current = state.start(DiscoverMode.mh, 'test');
    repo.pending[searchUrl]!.complete(
      parseDiscoverBatch(DiscoverMode.mh, searchMarkup, searchUrl),
    );
    await current;
    repo.pending['https://18mh.net/novel/search/old']!.complete(
      const DiscoverBatch([], null),
    );
    await old;
    expect(state.books.single.title, '山间来信');
    final next = state.loadMore();
    await state.loadMore(); // Concurrent scroll callbacks issue one request.
    expect(repo.requests.where((u) => u.endsWith('/page/2')), hasLength(1));
    repo.pending['$searchUrl/page/2']!.completeError(
      const ReaderFailure('合成网络错误'),
    );
    await next;
    expect(state.error, isNotNull);
    expect(state.nextUrl, '$searchUrl/page/2');
    repo.pending.remove('$searchUrl/page/2');
    final retry = state.loadMore();
    repo.pending['$searchUrl/page/2']!.complete(
      const DiscoverBatch([
        DiscoverBook('重复书', 'https://18mh.net/novel/detail/1', DiscoverMode.mh),
        DiscoverBook('第二本', 'https://18mh.net/novel/detail/2', DiscoverMode.mh),
      ], null),
    );
    await retry;
    expect(state.books.map((b) => b.title), ['山间来信', '第二本']);
    expect(state.error, isNull);
    expect(state.nextUrl, isNull);
    await state.loadMore();
    expect(repo.requests, hasLength(4));
  });
  test('night reader parses catalog and body without consuming next chapter as continuation', () async {
    final dir = await Directory.systemTemp.createTemp('night-reader-');
    addTearDown(() => dir.delete(recursive: true));
    const detail = '$yesheBase/artdetail-42.html';
    const chapter1 = '$yesheBase/artrss-42/nid/1.html';
    const chapter2 = '$yesheBase/artrss-42/nid/2.html';
    final reader = FixtureReaderRepository(dir, await testSources(), {
      detail:
          '''<div class="detailinfo"><h1>湖畔故事</h1></div><div class="videolist">
        <a class="link" href="/artrss-42/nid/1.html">第一章<span>(1万字)</span></a>
        <a class="btn" href="/artrss-42/nid/1.html">阅读</a>
        <a class="link" href="/artrss-42/nid/2.html">第二章<span>(2万字)</span></a></div>''',
      chapter1: '''<div class="picslist"><div class="content"><p>湖畔起风了。</p><p>远处传来鸟鸣。</p>
        <div class="nextbtn"><a href="/artrss-42/nid/2.html">下一章</a></div></div></div>''',
    });
    addTearDown(reader.dispose);
    final source = reader.source('yeshe', detail);
    final catalog = await reader.catalog(source, detail);
    expect(catalog.chapters.map((c) => c.title), ['第一章', '第二章']);
    expect(catalog.chapters.last.url, chapter2);
    final body = await reader.chapter(
      source,
      catalog.chapters.first,
      catalog.chapters,
    );
    expect(body.title, '第一章');
    expect(body.paragraphs, ['湖畔起风了。', '远处传来鸟鸣。']);
    expect(reader.requested, [detail, chapter1]);
    final (book, requested) = await DiscoverRepository(reader)
        .resolveYeshe(chapter2);
    expect(book.url, detail);
    expect(book.title, '湖畔故事');
    expect(requested, chapter2);
  });
}
