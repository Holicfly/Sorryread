import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_cover.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import 'normal_search_test.dart' show NormalFixtureReader, normalRule;
import 'reader_page_test.dart' show flushReader, settleReader;
import 'support/test_runtime.dart';

class _UiReader extends NormalFixtureReader {
  _UiReader(super.directory, super.rules);
  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  @override
  Future<String> fetch(SourceRule source, String url) async =>
      url.contains('/chapter/')
      ? '<h1>第一章</h1><div id="content"><p>用于普通搜索进入阅读的合成正文。</p></div>'
      : '<div id="chapters"><a href="/chapter/1">第一章</a></div>';
}

void main() {
  testWidgets(
    'source tabs show only title/optional author and open the retained reader',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final sync = (await tester.runAsync(() => testRepository(books: 0)))!;
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('normal-ui-'),
      ))!;
      final reader = _UiReader(directory, [
        normalRule('a'),
        normalRule('b'),
        normalRule('wodushu'),
      ]);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await flushReader(tester);
        reader.dispose();
        await sync.close();
        await directory.delete(recursive: true);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncRepositoryProvider.overrideWith((ref) async => sync),
            readerRepositoryProvider.overrideWith((ref) async {
              ref.onDispose(reader.dispose);
              return reader;
            }),
            peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
            backgroundSyncEnabledProvider.overrideWithValue(false),
          ],
          child: const ReaderApp(),
        ),
      );
      await flushReader(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderApp)),
      );
      final router = container.read(appRouterProvider);
      router.go('/discover/results?mode=normal&q=fixture');
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('normal-source-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('normal-source-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('normal-source-wodushu')), findsNothing);
      expect(find.text('全部'), findsNothing);
      expect(find.text('综合排序'), findsNothing);
      expect(find.byType(BookCover).hitTestable(), findsNothing);
      expect(find.widgetWithText(ListTile, '山间来信'), findsOneWidget);
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, '山间来信')).subtitle,
        isNotNull,
      );
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, '湖畔故事')).subtitle,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('normal-source-b')));
      await flushReader(tester);
      await tester.tap(find.byKey(const ValueKey('normal-source-a')));
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(reader.disposed, isFalse);
      await tester.tap(find.widgetWithText(ListTile, '山间来信'));
      await settleReader(tester);
      expect(find.byKey(const Key('reader-content')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
