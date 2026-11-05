import 'dart:io';

import 'package:dio/dio.dart';

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
import 'package:sorryread_mobile/features/discover/presentation/search_results_surface.dart';
import 'package:sorryread_mobile/features/discover/presentation/normal_source_tabs.dart';
import 'package:sorryread_mobile/features/discover/presentation/normal_search_results.dart';
import 'package:sorryread_mobile/features/discover/data/normal_search.dart';

import 'normal_search_test.dart' show NormalFixtureReader, normalRule;
import 'reader_page_test.dart' show flushReader, settleReader;
import 'support/test_runtime.dart';

// Search parsing uses compute(), which needs real event-loop time even after
// a page animation ends. Keep the same bounded settling condition as Flutter.
Future<void> settleSearch(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (!tester.binding.hasScheduledFrame) return;
  }
  fail('Search UI did not settle');
}

class _UiReader extends NormalFixtureReader {
  _UiReader(super.directory, super.rules);
  bool disposed = false;
  int resultCount = 1;
  @override
  Future<(String, String)> fetchSearch(
    SourceRule source,
    String url, {
    String method = 'GET',
    Map<String, String>? form,
    CancelToken? cancelToken,
  }) async {
    if (resultCount == 1) {
      return super.fetchSearch(
        source,
        url,
        method: method,
        form: form,
        cancelToken: cancelToken,
      );
    }
    return (
      '<table id="results">${List.generate(resultCount, (i) => '<tr><td><a href="/book/$i">山间来信 $i</a></td><td>作者：林间</td></tr>').join()}</table>',
      url,
    );
  }

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

Finder resultRow(String title) => find
    .byWidgetPredicate(
      (widget) => widget is NormalSearchResultRow && widget.book.title == title,
    )
    .hitTestable();

Future<_UiReader> _mountNormal(
  WidgetTester tester, {
  int count = 1,
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  addTearDown(tester.view.reset);
  final sync = (await tester.runAsync(() => testRepository(books: 0)))!;
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('normal-ui-'),
  ))!;
  final reader = _UiReader(directory, [
    normalRule('a'),
    normalRule('b'),
    normalRule('wodushu'),
  ])..resultCount = count;
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
  return reader;
}

void main() {
  testWidgets(
    'source tabs show only title/optional author and open the retained reader',
    (tester) async {
      final reader = await _mountNormal(tester);
      expect(find.byKey(const ValueKey('normal-source-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('normal-source-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('normal-source-wodushu')), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(SearchResultsSurface), findsOneWidget);
      expect(find.byType(SearchResultDivider), findsWidgets);
      expect(find.text('全部'), findsNothing);
      expect(find.text('综合排序'), findsNothing);
      expect(find.byType(BookCover).hitTestable(), findsNothing);
      expect(resultRow('山间来信'), findsOneWidget);
      expect(
        tester.widget<NormalSearchResultRow>(resultRow('山间来信')).book.author,
        isNotEmpty,
      );
      expect(
        tester.widget<NormalSearchResultRow>(resultRow('湖畔故事')).book.author,
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('normal-source-b')));
      await flushReader(tester);
      await tester.pumpAndSettle();
      final pager = find.byKey(const Key('normal-results-pager'));
      final gesture = await tester.startGesture(tester.getCenter(pager));
      await gesture.moveBy(const Offset(220, 0));
      await tester.pump(const Duration(milliseconds: 30));
      final tabs = tester.widget<NormalSourceTabs>(
        find.byType(NormalSourceTabs),
      );
      final pagerWidget = tester.widget<TabBarView>(pager);
      expect(tabs.controller.animation!.value, inExclusiveRange(0, 1));
      await gesture.up();
      await settleSearch(tester);
      expect(tabs.controller.index, 0);
      await tester.drag(pager, const Offset(-300, 0));
      await settleSearch(tester);
      expect(tabs.controller.index, 1);
      expect(
        identical(
          tester.widget<NormalSourceTabs>(find.byType(NormalSourceTabs)),
          tabs,
        ),
        isTrue,
      );
      expect(identical(tester.widget<TabBarView>(pager), pagerWidget), isTrue);
      await tester.tap(find.byKey(const ValueKey('normal-source-a')));
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(reader.disposed, isFalse);
      await tester.tap(resultRow('山间来信'));
      await settleReader(tester);
      expect(find.byKey(const Key('reader-content')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'fixed source slots animate and follow pages without reflow at scale $scale',
      (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('normal-slots-'),
        ))!;
        final reader = _UiReader(directory, [
          for (var i = 0; i < 8; i++) normalRule('s$i'),
        ]);
        final search = NormalSearchController(reader);
        final controller = TabController(
          length: 8,
          vsync: const TestVSync(),
          initialIndex: 2,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          search.dispose();
          reader.dispose();
          await tester.runAsync(() => directory.delete(recursive: true));
        });
        var metrics = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(390, 844),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 390,
                    child: NotificationListener<ScrollMetricsNotification>(
                      onNotification: (_) {
                        metrics++;
                        return false;
                      },
                      child: NormalSourceTabs(
                        controller: controller,
                        sources: search.sources,
                        onSelected: controller.animateTo,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final strip = tester
            .widget<SingleChildScrollView>(
              find.byKey(const Key('normal-source-strip')),
            )
            .controller!;
        Map<String, double> positions() => {
          for (final id in ['s2', 's3']) ...{
            '$id-left':
                tester.getTopLeft(find.byKey(ValueKey('normal-title-$id'))).dx +
                strip.offset,
            '$id-width': tester
                .getSize(find.byKey(ValueKey('normal-source-$id')))
                .width,
          },
        };
        final before = positions(), beforeMetrics = metrics;
        final offsets = <double>[], sizes = <double>[];
        for (final progress in [.2, .4, .6, .8, .4, .2]) {
          controller.offset = progress;
          await tester.pump();
          expect(positions(), before);
          offsets.add(strip.offset);
          final label = tester.widget<Text>(
            find.byKey(const ValueKey('normal-title-s2')),
          );
          final transform = tester.widget<Transform>(
            find.byKey(const ValueKey('normal-title-scale-s2')),
          );
          sizes.add(label.style!.fontSize! * transform.transform.entry(0, 0));
        }
        expect(offsets[1], greaterThan(offsets[0]));
        expect(offsets[3], greaterThan(offsets[2]));
        expect(offsets[4], closeTo(offsets[1], .01));
        expect(sizes[0], inExclusiveRange(17, 21));
        expect(sizes[3], lessThan(sizes[0]));
        reader.resultCount = 100;
        await tester.runAsync(() => search.start('计数更新'));
        await tester.pumpAndSettle();
        expect(
          search.sources.every((source) => source.books.length == 100),
          isTrue,
        );
        expect(positions(), before);
        expect(
          find
              .descendant(
                of: find.byKey(const ValueKey('normal-source-s2')),
                matching: find.byType(Text),
              )
              .evaluate()
              .map((element) => (element.widget as Text).data)
              .toList(),
          ['s2书源'],
        );
        expect(metrics, beforeMetrics);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'compact rows, wider surface and bottom fade leave the last result accessible',
    (tester) async {
      final reader = await _mountNormal(tester, count: 30);
      final first = resultRow('山间来信 0'), second = resultRow('山间来信 1');
      expect(tester.getSize(first).height, greaterThanOrEqualTo(48));
      expect(
        tester.getTopLeft(second).dy - tester.getTopLeft(first).dy,
        inInclusiveRange(56, 64),
      );
      final panel = tester.getRect(
        find.byKey(const Key('search-results-panel')),
      );
      final dock = tester.getRect(find.byKey(const Key('floating-dock')));
      final fade = tester.getRect(find.byKey(const Key('search-results-fade')));
      expect(panel.left, 10);
      expect(panel.width, greaterThan(dock.width));
      expect(fade.top, closeTo(dock.top - 28, .01));
      expect(fade.bottom, closeTo(panel.bottom, .01));
      expect(
        find.ancestor(
          of: find.byKey(const Key('search-results-fade')),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
      final current = find.byType(CustomScrollView).hitTestable();
      final scroll = tester.widget<CustomScrollView>(current).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final last = resultRow('山间来信 29');
      expect(last, findsOneWidget);
      expect(tester.getRect(last).bottom, lessThan(fade.top));
      final tabs = tester.widget<NormalSourceTabs>(
        find.byType(NormalSourceTabs),
      );
      reader.resultCount = 40;
      await tester.enterText(find.byType(TextField), '新的关键词');
      tester.widget<TextField>(find.byType(TextField)).onSubmitted!('新的关键词');
      await flushReader(tester);
      await settleSearch(tester);
      expect(scroll.offset, 0);
      expect(resultRow('山间来信 0'), findsOneWidget);
      expect(
        identical(
          tester.widget<NormalSourceTabs>(find.byType(NormalSourceTabs)),
          tabs,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
