import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/comic/data/yeshe_comic.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';

import 'support/test_runtime.dart';

void main() {
  const detailUrl = 'https://yeshezy1.com/voddetail/42.html';
  const chapterUrl = 'https://yeshezy1.com/vodplay/42-1-2.html';

  test('shared comic image requests complete and can be reused', () async {
    final cache = await Directory.systemTemp.createTemp('ys2-image-test-');
    addTearDown(() => cache.delete(recursive: true));
    final reader = ReaderRepository(cache, []);
    addTearDown(reader.dispose);
    final comic = ComicRepository(reader, cache);
    const url = 'https://yeshezy1.com/page.webp';
    final file = File('${cache.path}/${reader.key(url)}.webp');
    await file.writeAsBytes([1, 2, 3]);
    final request = comic.image(url);
    expect(comic.image(url), same(request));
    expect((await request.timeout(const Duration(seconds: 2))).path, file.path);
    expect((await comic.image(url)).path, file.path);
  });

  test('comic links and chapter lists stay within the same work', () {
    expect(parseComicLink('$chapterUrl?from=share').detail, detailUrl);
    expect(
      () => parseComicLink(
        'https://yeshezy1.com@outside.invalid/voddetail/42.html',
      ),
      throwsA(isA<ReaderFailure>()),
    );
    final detail = parseComicDetail((
      '''<div class="detailinfo"><h1>合成漫画</h1></div>
        <div class="cartoonlist">
          <div class="list"><div class="name">第2话</div><a class="btn" href="/vodplay/42-1-2.html">浏览</a></div>
          <div class="list"><div class="name">第1话</div><a class="btn" href="/vodplay/42-1-1.html">浏览</a></div>
          <div class="list"><a class="btn" href="/vodplay/99-1-1.html">其他作品</a></div>
        </div>''',
      detailUrl,
    ));
    expect(detail.chapters.map((chapter) => chapter.title), ['第2话', '第1话']);
    expect(detail.chapters.first.url, chapterUrl);
  });

  test('large chapters keep numeric page order and ignore recommendations', () {
    final markup = [
      '<div class="list"><img src="/recommendation.webp"></div><div class="picslist">',
      for (var i = 664; i >= 1; i--)
        '<div class="list"><img id="${i}P" src="/$i.webp"></div>',
      '</div>',
    ].join();
    final pages = parseComicPages((markup, chapterUrl));
    expect(pages.length, 664);
    expect(pages.first, 'https://yeshezy1.com/1.webp');
    expect(pages.last, 'https://yeshezy1.com/664.webp');
  });

  test('comic recent and favorite use the latest local position', () async {
    final repository = await testRepository();
    addTearDown(repository.close);
    final comic = const ComicBook('合成漫画', detailUrl).toShelfBook();
    await repository.setFavorite(comic, true);
    for (final page in [10, 2]) {
      await repository.saveComicPosition(comic, {
        'chapterUrl': chapterUrl,
        'chapterTitle': '第2话',
        'chapterIndex': 1,
        'chapterCount': 2,
        'bookProgressChapterUrl': chapterUrl,
        'comicPage': page,
        'progress': page / 20,
      });
    }
    final book = (await repository.books()).single;
    expect(book.isSpecialSource && book.favorite && book.recent, isTrue);
    expect(book.position?.effective.payload['comicPage'], 2);
    expect(await repository.localChangesAfter(0), isEmpty);
    expect((await repository.exportSnapshot()).$2, isEmpty);
  });
}
