import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';

class FixtureReaderRepository extends ReaderRepository {
  FixtureReaderRepository(super.directory, super.rules, this.pages);
  final Map<String, String> pages;
  final requested = <String>[];
  @override
  Future<String> fetch(SourceRule source, String url) async {
    requested.add(url);
    if (!pages.containsKey(url)) throw const ReaderFailure('合成网络失败');
    return pages[url]!;
  }
}

Future<List<SourceRule>> testSources() async => (jsonDecode(
  await File('assets/reader_sources.json').readAsString(),
) as List).map((e) => SourceRule(Map<String, dynamic>.from(e as Map))).toList();

void main() {
  test(
    '14 desktop rules and mobile yeshe rule export catalog and body selectors',
    () async {
      final rules = await testSources();
      expect(rules, hasLength(15));
      expect(rules.map((r) => r.id).toSet(), hasLength(15));
      for (final source in rules) {
        expect(source.catalog['itemSelector'], isNotEmpty);
        if (!source.dynamicPage) {
          expect(source.chapter['contentSelector'], isNotEmpty);
        }
      }
    },
  );
  test('br, nested paragraphs, HTML entities, emoji and hidden ads preserve semantic paragraphs', () async {
    final rule = (await testSources()).firstWhere((s) => s.id == 'wodushu');
    final result = parseChapterPage(
      rule,
      '''<h1 class="title">第一章</h1><div id="content">
      &nbsp;&nbsp;第一段 &amp; 中文。<br><br>第二段😀<p>第三段<span>连续文字</span>。</p>
      <div hidden>不该出现</div><div style="display:none">隐藏广告</div><script>脚本</script><style>样式</style>
    </div>''',
      const ChapterLink('第一章', 'https://www.wodushu.com/read/1/1.html'),
    );
    expect(result.paragraphs, ['第一段 & 中文。', '第二段😀', '第三段连续文字。']);
  });
  test('base64 fragments decode without executing site scripts', () async {
    final rule = (await testSources()).firstWhere((s) => s.id == 'wxsy');
    final payload = base64Encode(utf8.encode('第一段<br>第二段'));
    final result = parseChapterPage(
      rule,
      '<h3>标题</h3><div class="row-detail"><div><div><script>document.write(qsbs.bb("$payload"));</script></div></div></div>',
      const ChapterLink('标题', 'https://www.wxsy.net/read/1.html'),
    );
    expect(result.paragraphs, ['第一段', '第二段']);
  });
  test('catalog pages deduplicate chapters; content continuation stops before next chapter; offline cache reopens', () async {
    final dir = await Directory.systemTemp.createTemp('reader-parsing-');
    addTearDown(() => dir.delete(recursive: true));
    final rules = await testSources();
    final repo = FixtureReaderRepository(dir, rules, {
      'https://www.wodushu.com/book/1/': '<ul id="chapter_list"><li><a href="/read/1/1.html">第一章</a></li></ul><select id="indexselect"><option value="/book/1/">一</option><option value="/book/1/?page=2">二</option></select>',
      'https://www.wodushu.com/book/1/?page=2': '<ul id="chapter_list"><li><a href="/read/1/1.html">第一章</a></li><li><a href="/read/1/2.html">第二章</a></li></ul>',
      'https://www.wodushu.com/read/1/1.html': '<h1 class="title">第一章</h1><div id="content">第一页<br>第二段</div><div class="section-opt"><a></a><a></a><a href="1_2.html">下一页</a></div>',
      'https://www.wodushu.com/read/1/1_2.html': '<div id="content">续页正文</div><div class="section-opt"><a></a><a></a><a href="2.html">下一章</a></div>',
    });
    addTearDown(repo.dispose);
    final source = repo.source('wodushu', 'https://www.wodushu.com/book/1/');
    final catalog = await repo.catalog(
      source,
      'https://www.wodushu.com/book/1/',
    );
    expect(catalog.chapters.map((c) => c.title), [
      '第一章',
      '第二章',
    ], reason: '${repo.requested} / ${catalog.warning}');
    final chapter = await repo.chapter(
      source,
      catalog.chapters.first,
      catalog.chapters,
    );
    expect(chapter.paragraphs, ['第一页', '第二段', '续页正文']);
    expect(repo.requested, hasLength(4));
    repo.pages.clear();
    expect(
      (await repo.catalog(source, 'https://www.wodushu.com/book/1/')).chapters,
      hasLength(2),
    );
    expect(
      (await repo.chapter(
        source,
        catalog.chapters.first,
        catalog.chapters,
      )).hash,
      chapter.hash,
    );
    expect(repo.requested, hasLength(4));
  });
  test(
    'looped chapter pages fail explicitly instead of returning truncated text',
    () async {
      final dir = await Directory.systemTemp.createTemp('reader-loop-');
      addTearDown(() => dir.delete(recursive: true));
      final repo = FixtureReaderRepository(dir, await testSources(), {
        'https://www.wodushu.com/read/1/1.html': '<div id="content">正文一</div><div class="section-opt"><a></a><a></a><a href="1_2.html">下一页</a></div>',
        'https://www.wodushu.com/read/1/1_2.html': '<div id="content">正文二</div><div class="section-opt"><a></a><a></a><a href="1_2.html">下一页</a></div>',
      });
      addTearDown(repo.dispose);
      final source = repo.rules.firstWhere((r) => r.id == 'wodushu');
      const link = ChapterLink('第一章', 'https://www.wodushu.com/read/1/1.html');
      await expectLater(
        repo.chapter(source, link, [link]),
        throwsA(isA<ReaderFailure>()),
      );
    },
  );
}
