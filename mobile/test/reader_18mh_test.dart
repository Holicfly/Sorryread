import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';

import 'reader_parsing_test.dart' show testSources;

const detailUrl = 'https://18mh.net/novel/detail/42';
const chapterUrl = 'https://18mh.net/novel_chapter/42/1.html';
const catalogHtml =
    '''<a class="detail-page__catalog-item" href="/novel_chapter/42/1.html">
<span class="detail-page__chapter-badge">第1章</span><span class="detail-page__chapter-title">山间来信</span></a>''';
const chapterHtml = '''<style>.chapter-content {color: black}</style>
<h1>网站或书籍标题</h1><main class="app-content"><article><div class="article">
<div class="line"> 第一段 &amp; 中文。</div><div class="line">第二段。</div>
<div class="line"> </div><div hidden>广告</div></div></article></main>
<div class="novel-read-footer">前一章 返回书页 后一章</div>''';

class HtmlAdapter implements HttpClientAdapter {
  final requested = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    return ResponseBody.fromBytes(
      utf8.encode(options.path == detailUrl ? catalogHtml : chapterHtml),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('browser DOM must belong to the requested URL and be fully parsed', () {
    String payload(String url, String state) =>
        jsonEncode({'url': url, 'state': state, 'html': chapterHtml});
    // getUrl may already say chapterUrl while the actual document is a catalog.
    expect(
      decodeReaderDomSnapshot(payload(detailUrl, 'interactive'))
          .matches(chapterUrl),
      isFalse,
    );
    expect(
      decodeReaderDomSnapshot(payload(chapterUrl, 'loading'))
          .matches(chapterUrl),
      isFalse,
    );
    final snapshot = decodeReaderDomSnapshot(
      jsonEncode(payload(chapterUrl, 'interactive')),
    );
    expect(snapshot.matches(chapterUrl), isTrue);
    expect(snapshot.markup, chapterHtml);
  });
  test('18mh article lines parse without browser and preserve catalog chapter name', () async {
    final source = (await testSources()).firstWhere((s) => s.id == '18mh');
    final catalog = parseCatalogPage(source, catalogHtml, detailUrl);
    expect(catalog.single.title, '第1章 山间来信');
    expect(catalog.single.url, chapterUrl);
    const currentCatalog = '''<a class="jm-dt-ch" href="/novel_chapter/42/1.html"><span class="jm-dt-ch__no">第1章</span><span class="jm-dt-ch__t">山间来信</span></a>
<a class="jm-dt-ch is-hidden" href="/novel_chapter/42/2.html"><span class="jm-dt-ch__no">第2章</span><span class="jm-dt-ch__t">湖畔故事</span></a>''';
    final updated = parseCatalogPage(source, currentCatalog, detailUrl);
    expect(updated.map((e) => e.title), ['第1章 山间来信', '第2章 湖畔故事']);
    expect(readerPageReady(source, currentCatalog, detailUrl), isTrue);
    final chapter = parseChapterPage(source, chapterHtml, catalog.single);
    expect(chapter.title, '第1章 山间来信');
    expect(chapter.paragraphs, ['第一段 & 中文。', '第二段。']);
    expect(readerPageReady(source, chapterHtml, chapterUrl), isTrue);
    expect(readerPageReady(source, catalogHtml, detailUrl), isTrue);
    expect(readerPageReady(source, catalogHtml, chapterUrl), isFalse);
    expect(
      readerPageReady(
        source,
        '<script>"detail-page__catalog-item"</script><style>.chapter-content{}</style>',
        chapterUrl,
      ),
      isFalse,
    );
    expect(
      readerPageReady(
        source,
        '<main class="app-content"><div class="article"> </div></main>',
        chapterUrl,
      ),
      isFalse,
    );
  });
  test('server-rendered dynamic source uses HTTP and cached chapters without creating WebView', () async {
    final dir = await Directory.systemTemp.createTemp('reader-18mh-');
    addTearDown(() => dir.delete(recursive: true));
    final repository = ReaderRepository(dir, await testSources());
    addTearDown(repository.dispose);
    final adapter = HtmlAdapter();
    repository.http.httpClientAdapter = adapter;
    final source = repository.source('18mh', detailUrl);
    final catalog = await repository.catalog(source, detailUrl);
    final chapter = await repository.chapter(
      source,
      catalog.chapters.single,
      catalog.chapters,
    );
    expect(chapter.paragraphs, ['第一段 & 中文。', '第二段。']);
    expect(repository.webView, isNull);
    expect(adapter.requested, [detailUrl, chapterUrl]);
    await repository.chapter(source, catalog.chapters.single, catalog.chapters);
    expect(adapter.requested, hasLength(2));
  });
}
