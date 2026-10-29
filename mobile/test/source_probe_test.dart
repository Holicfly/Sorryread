import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/discover/data/normal_search.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';

import 'reader_parsing_test.dart' show testSources;

void main() {
  test('cached current normal-source layouts', () async {
    final rules = await testSources();
    final network = jsonDecode(
      await File('../artifacts/mobile-v024-probe/normal-network.json')
          .readAsString(),
    ) as List;
    var usable = 0;
    for (final result in network) {
      if (result['status'] != 200) continue;
      final id = result['id'] as String;
      try {
        final batch = parseNormalSearch(
          rules.firstWhere((r) => r.id == id),
          await File('../artifacts/mobile-v024-probe/$id-search.html')
              .readAsString(),
          result['url'] as String,
        );
        // ignore: avoid_print
        print(
          '$id: ${batch.books.length} books, ${batch.books.where((b) => b.author.isNotEmpty).length} authors, next=${batch.nextUrl != null}',
        );
        if (batch.books.isNotEmpty) usable++;
      } catch (e) {
        // ignore: avoid_print
        print('$id: $e');
      }
    }
    expect(usable, greaterThanOrEqualTo(4));
  }, skip: !const bool.fromEnvironment('NORMAL_PROBE'));

  test(
    'live 18mh updated catalog and public chapter',
    () async {
      final dir = await Directory.systemTemp.createTemp('18mh-v024-');
      addTearDown(() => dir.delete(recursive: true));
      final repo = ReaderRepository(dir, await testSources());
      addTearDown(repo.dispose);
      const detail = 'https://18mh.net/novel/detail/1724';
      final source = repo.source('18mh', detail);
      final catalog = await repo.catalog(source, detail, refresh: true);
      expect(catalog.chapters, isNotEmpty);
      expect(catalog.chapters.first.url, endsWith('/1724/1.html'));
      final chapter = await repo.chapter(
        source,
        catalog.chapters.first,
        catalog.chapters,
        refresh: true,
      );
      expect(chapter.paragraphs.length, greaterThan(5));
      expect(repo.webView, isNull);
      // ignore: avoid_print
      print(
        '18mh: ${catalog.chapters.length} catalog items; ${chapter.paragraphs.length} paragraphs; title matches=${chapter.title == catalog.chapters.first.title}',
      );
    },
    skip: !const bool.fromEnvironment('SOURCE_LIVE'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
