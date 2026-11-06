import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/data/imported_books.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/data/reading_history.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/features/local_books/local_book_parser.dart';

void main() {
  test(
    'shared TXT addresses, private original, retained totals and reimport',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sorryread-local-test-',
      );
      final repo = SyncRepository(
        SyncDatabase(NativeDatabase.memory()),
        bookDirectory: Directory('${root.path}/books'),
      );
      final library = LocalLibrary(repo);
      addTearDown(() async {
        await library.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      await repo.initialize();
      await library.initialize();
      final remotePositions = <ImportedBook>[];
      final positions = repo.importedPositionAdvances.stream.listen(
        remotePositions.add,
      );
      addTearDown(positions.cancel);
      final fixture =
          (jsonDecode(
                await File('../shared/fixtures/local-books-v1.json')
                    .readAsString(),
              ) as Map)['txt']
              as Map;
      final source = await File('${root.path}/原书.txt')
          .writeAsString(fixture['content'] as String);
      final store = repo.importedBooks!;
      final book = await store.importFile(source, '原书.txt', server: 'desktop');
      expect(book.hash, fixture['sha256']);
      expect(
        (await store.catalog(book.hash)).map((unit) => unit.address),
        fixture['addresses'],
      );
      expect(
        await store.original(book).readAsBytes(),
        await source.readAsBytes(),
      );
      await store.updatePosition(book.hash, 0, 1, .4);
      await repo.setFavorite((await repo.books()).single, true);
      expect(remotePositions, isEmpty);
      expect((await repo.books()).single.favorite, isTrue);
      expect((await repo.books()).single.recent, isFalse);
      await library.setPinned(book.id, true);
      final now = DateTime.now();
      await library.recordReading(
        {'title': book.title, 'sourceId': 'local'},
        now,
        5000,
        bookId: book.id,
        position: ReadingPosition(
          chapterUrl: '$localBookUrl${book.hash}/1',
          chapterTitle: '第二章',
          chapterIndex: 1,
          chapterCount: 2,
        ),
      );
      expect((await library.readingOverview(now)).entries, isNotEmpty);
      await store.remove(book.hash, server: 'desktop', both: false);
      expect(await source.exists(), isTrue);
      expect(await store.original(book).exists(), isFalse);
      expect(await store.receive('desktop', 0, book.state), isNull);
      expect((await library.readingOverview(now)).entries, isEmpty);
      expect((await library.combinedReadingStats()).milliseconds, 5000);
      final restored = await store.importFile(
        source,
        '改名.txt',
        server: 'desktop',
      );
      expect(restored.hash, book.hash);
      expect((await store.operations('desktop')).map((op) => op.action), [
        'removeHere',
        'resume',
      ]);
      final ops = await store.operations('desktop');
      await store.applyPolicy(
        'desktop',
        BookPolicy(book.hash, 1, 0, false, false, true),
      );
      await store.acknowledge(ops.first);
      expect(await store.book(book.hash), isNotNull);
      await store.applyPolicy(
        'desktop',
        BookPolicy(book.hash, 2, 0, false, false, false),
      );
      await store.acknowledge(ops.last);
      expect(
        await store.receive('desktop', 0, {
          ...book.state,
          'position': {'index': 1, 'progress': .65},
        }),
        isNotNull,
      );
      expect((await store.book(book.hash))!.progress, .65);
      expect(remotePositions.map((book) => book.progress), [.65]);
      await store.receive('desktop', 0, {
        ...book.state,
        'position': {'index': 1, 'progress': .65},
      });
      expect(remotePositions, hasLength(1));
      await store.applyPolicy(
        'desktop',
        BookPolicy(book.hash, 3, 1, true, false, false),
      );
      expect(await store.book(book.hash), isNull);
      expect(await store.receive('desktop', 0, book.state), isNull);
    },
  );

  test('EPUB comic uses spine order and extracts its actual cover', () async {
    final root = await Directory.systemTemp.createTemp('sorryread-epub-test-');
    addTearDown(() => root.delete(recursive: true));
    final archive = Archive();
    void add(String path, String value) {
      final bytes = utf8.encode(value);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add(
      'META-INF/container.xml',
      '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    );
    add(
      'OPS/book.opf',
      '<package><metadata><title>漫画测试</title></metadata><manifest>'
          '<item id="p" href="text/page.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="a" href="images/图%201.png" media-type="image/png" properties="cover-image"/>'
          '</manifest><spine><itemref idref="p"/></spine></package>',
    );
    add(
      'OPS/text/page.xhtml',
      '<body><img src="../images/图%201.png"/>'
          '<svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../images/2.png"/></svg></body>',
    );
    add('OPS/images/图 1.png', 'cover fixture');
    add('OPS/images/2.png', 'page fixture');
    final file = await File('${root.path}/comic.epub')
        .writeAsBytes(ZipEncoder().encode(archive)!);
    final parsed = await parseBookFile(file.path, 'epub', 'fallback');
    expect(parsed.comic, isTrue);
    expect(parsed.units.map((unit) => unit.address), [
      'epub:0:image:0:OPS%2Fimages%2F%E5%9B%BE%201.png',
      'epub:0:image:1:OPS%2Fimages%2F2.png',
    ]);
    expect(utf8.decode(parsed.cover!), 'cover fixture');
  });

  final samples = Platform.environment['SORRYREAD_MOBI_SAMPLES'];
  test('real PalmDOC, HUFF and uncompressed MOBI', () async {
    final cp = await parseBookFile(
      '$samples/sample-cp1252.mobi',
      'mobi',
      'sample',
    );
    final huff = await parseBookFile(
      '$samples/sample-unicode-huffdic.mobi',
      'mobi',
      'sample',
    );
    final raw = await parseBookFile(
      '$samples/sample-unicode-uncompressed.mobi',
      'mobi',
      'sample',
    );
    expect(cp.units.length, 6);
    expect(
      huff.units.map((unit) => unit.blocks.single.text),
      raw.units.map((unit) => unit.blocks.single.text),
    );
    expect(huff.catalogHash, raw.catalogHash);
    await expectLater(
      parseBookFile('$samples/sample-drm-v2.mobi', 'mobi', 'sample'),
      throwsFormatException,
    );
  }, skip: samples == null);
}
