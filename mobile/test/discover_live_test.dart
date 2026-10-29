import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/discover/data/discover_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';

import 'reader_parsing_test.dart' show testSources;

void main() {
  test(
    'live search/list pagination, last page and night reader',
    () async {
      final dir = await Directory.systemTemp.createTemp('discover-live-');
      addTearDown(() => dir.delete(recursive: true));
      final reader = ReaderRepository(dir, await testSources());
      addTearDown(reader.dispose);
      final repo = DiscoverRepository(reader);
      final search = await repo.fetch(
        DiscoverMode.mh,
        'https://18mh.net/novel/search/${Uri.encodeComponent('都市')}',
      );
      expect(search.books, isNotEmpty);
      expect(search.nextUrl, isNotNull);
      final searchNext = await repo.fetch(DiscoverMode.mh, search.nextUrl!);
      expect(searchNext.books, isNotEmpty);
      final searchLast = await repo.fetch(
        DiscoverMode.mh,
        'https://18mh.net/novel/search/${Uri.encodeComponent('都市')}/page/${(search.total! / search.books.length).ceil()}',
      );
      expect(searchLast.books, isNotEmpty);
      expect(searchLast.nextUrl, isNull);
      final night = await repo.fetch(DiscoverMode.yeshe, yesheListUrl);
      expect(night.books, isNotEmpty);
      final nightNext = await repo.fetch(DiscoverMode.yeshe, night.nextUrl!);
      expect(nightNext.books, isNotEmpty);
      final nightLast = await repo.fetch(
        DiscoverMode.yeshe,
        '$yesheBase/arttype/5-${(night.total! / night.books.length).ceil()}.html',
      );
      expect(nightLast.books, isNotEmpty);
      expect(nightLast.nextUrl, isNull);
      final (book, target) = await repo.resolveYeshe(
        '$yesheBase/artrss-28279/nid/1.html',
      );
      final source = reader.source('yeshe', book.url);
      final catalog = await reader.catalog(source, book.url);
      expect(catalog.chapters.any((c) => c.url == target), isTrue);
      final chapter = await reader.chapter(
        source,
        catalog.chapters.first,
        catalog.chapters,
      );
      expect(chapter.paragraphs, isNotEmpty);
      expect(reader.webView, isNull);
      // No source text or titles in test output.
      // ignore: avoid_print
      print(
        'live: search ${search.books.length}+${searchNext.books.length}; '
        'night ${night.books.length}+${nightNext.books.length}; '
        'catalog ${catalog.chapters.length}; body ${chapter.paragraphs.length} paragraphs',
      );
    },
    skip: !const bool.fromEnvironment('DISCOVER_LIVE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
