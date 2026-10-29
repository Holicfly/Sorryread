import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_cover.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';

import 'app_shell_test.dart' show launch;
import 'support/test_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'book progress preserves chapter progress and rejects stale peer metadata',
    () async {
      final repo = await testRepository(books: 1);
      addTearDown(repo.close);
      final book = (await repo.books()).single;
      expect(book.progress, .25);
      expect(book.bookProgress, .0025);
      await repo.localChange(book.id, 'position', {
        ...book.metadata,
        'chapterIndex': 3,
        'chapterCount': 10,
        'bookProgressChapterUrl': book.metadata['chapterUrl'],
      });
      expect((await repo.books()).single.bookProgress, .325);
      await repo.localChange(book.id, 'position', {
        ...(await repo.books()).single.metadata,
        'chapterUrl': 'https://example.invalid/chapter/new',
      });
      expect((await repo.books()).single.bookProgress, isNull);
      final unread = ShelfBook('unread', book.metadata, true, false, null);
      expect(unread.bookProgress, 0);
    },
  );

  test('cover choices remain stable with no horizontal or vertical twins', () {
    final covers = BookCoverAssignments(random: Random(17));
    final ids = List.generate(90, (i) => 'book-$i');
    final first = covers.forBooks(ids);
    expect(covers.forBooks(ids), first);
    expect(first.toSet(), hasLength(6));
    for (final order in [ids, ids.reversed.toList(), ids.sublist(5)]) {
      final choices = covers.forBooks(order);
      for (var i = 0; i < choices.length; i++) {
        if (i % 3 > 0) expect(choices[i], isNot(choices[i - 1]));
        if (i >= 3) expect(choices[i], isNot(choices[i - 3]));
      }
    }
  });

  testWidgets(
    'favorites and recent use isolated groups without filtering sync records',
    (tester) async {
      final repo = await launch(
        tester,
        bookCount: 2,
        seed: (repo) async {
          for (final source in ['test', '18mh']) {
            final id = 'book:$source|https://example.invalid/extra/$source';
            final p = <String, dynamic>{
              'kind': 'book',
              'title': '$source 分组书籍',
              'sourceId': source,
              'sourceName': source,
              'detailUrl': 'https://example.invalid/extra/$source',
              'chapterUrl': '',
              'chapterTitle': '',
              'progress': 0,
              'active': true,
              'updatedUtc': '2026-10-26T00:00:00Z',
            };
            await repo.localChange(id, 'recent', p);
            if (source == '18mh') await repo.localChange(id, 'favorite', p);
          }
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏  2'), findsOneWidget);
      expect(find.text('最近阅读  3'), findsOneWidget);
      expect(find.byType(BookCover), findsNWidgets(2));
      expect(find.text('18mh 分组书籍'), findsNothing);
      final recordsBefore = (await tester.runAsync(repo.records))!;
      await tester.tap(find.text('最近阅读  3'));
      await tester.pumpAndSettle();
      expect(find.byType(BookCover), findsNWidgets(3));
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('我的书架'));
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.text('收藏  2'), findsOneWidget);
      await tester.tap(find.text('我的书架'));
      await tester.pumpAndSettle();
      expect(find.text('收藏  1'), findsOneWidget);
      expect(find.text('最近阅读  1'), findsOneWidget);
      expect(find.byType(BookCover), findsOneWidget);
      expect(find.text('18mh 分组书籍'), findsWidgets);
      expect(
        (await tester.runAsync(repo.records))!,
        hasLength(recordsBefore.length),
      );
      expect((await tester.runAsync(repo.books))!, hasLength(4));
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.text('我的书架'));
        await tester.pump(const Duration(milliseconds: 80));
      }
      await tester.pumpAndSettle();
      expect(find.text('收藏  2'), findsOneWidget);
      expect(find.text('18mh 分组书籍'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
