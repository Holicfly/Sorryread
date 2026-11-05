// Runs only in the .dev package with synthetic books and an isolated database.
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/features/discover/data/discover_repository.dart';
import 'package:sorryread_mobile/features/discover/presentation/search_results_surface.dart';
import 'package:sorryread_mobile/features/discover/presentation/normal_source_tabs.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_preferences.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import '../test/app_shell_test.dart' show StaticSyncController;
import '../test/normal_search_test.dart' show normalRule;
import '../test/support/test_runtime.dart';

class _ReviewReader extends ReaderRepository {
  _ReviewReader(super.directory, super.rules);
  bool slowDone = false;
  @override
  Future<(String, String)> fetchSearch(
    SourceRule source,
    String url, {
    String method = 'GET',
    Map<String, String>? form,
    CancelToken? cancelToken,
  }) async {
    if (source.id == 's0') {
      await Future<void>.delayed(const Duration(seconds: 3));
      slowDone = true;
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (source.id != 's0' && source.id != 's7') return ('没有找到相关小说', url);
    return (
      '<table id="results">${List.generate(30, (i) => '<tr><td><a href="/book/$i">${source.id == 's7' ? '山间来信' : '湖畔故事'} ${i + 1}</a></td><td>作者：林间</td></tr>').join()}</table>',
      url,
    );
  }

  @override
  Future<String> fetch(SourceRule source, String url) async =>
      url.contains('/chapter/')
      ? '<h1>第一章 山间清晨</h1><div id="content">${List.generate(50, (i) => '<p>第$i 段：窗外的树叶轻轻摇动，阳光穿过枝叶，在书页上留下细碎的光影。山间有风，书中有远方。</p>').join()}</div>'
      : '<div id="chapters"><a href="/chapter/1">第一章 山间清晨</a><a href="/chapter/2">第二章 湖畔故事</a></div>';
}

class _OtherResults extends DiscoverRepository {
  _OtherResults(super.reader);
  @override
  Future<DiscoverBatch> fetch(DiscoverMode mode, String url) async =>
      DiscoverBatch(
        [
          for (var i = 0; i < 16; i++)
            DiscoverBook('山海之间 ${i + 1}', 'https://s0.invalid/book/$i', mode),
        ],
        null,
        total: 16,
      );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('v0213 dock, linked source paging and reader tools on Android', (
    tester,
  ) async {
    final root = Directory(
      '${(await getApplicationSupportDirectory()).path}/v0213-review',
    );
    await root.create(recursive: true);
    final report = <String, dynamic>{'passed': false, 'phase': 'setup'};
    Future<void> phase(String value) async {
      report['phase'] = value;
      await File('${root.path}/result.json')
          .writeAsString(jsonEncode(report), flush: true);
    }

    await phase('setup');
    final previousReporter = reportTestException;
    reportTestException = (details, description) {
      report['exception'] = details.exceptionAsString();
      report['stack'] = '${details.stack}';
      previousReporter(details, description);
    };
    addTearDown(() async {
      reportTestException = previousReporter;
      report['failures'] = binding.failureMethodsDetails
          .map((failure) => failure.details)
          .toList();
      await File('${root.path}/result.json')
          .writeAsString(jsonEncode(report), flush: true);
    });
    final sync = await testRepository();
    final reader = _ReviewReader(Directory('${root.path}/reader'), [
      for (var i = 0; i < 8; i++) normalRule('s$i'),
    ]);
    await reader.directory.create(recursive: true);
    await reader.write(
      'preferences',
      const ReaderPreferences(mode: PageMode.scroll).toJson(),
    );
    final book = const DiscoverBook(
      '阅读工具栏验收',
      'https://s0.invalid/book/1',
      DiscoverMode.normal,
      sourceId: 's0',
      sourceName: '合成书源',
    ).toShelfBook();
    await sync.setFavorite(book, true);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      reader.dispose();
      await sync.close();
    });
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 100 && !ready(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue);
    }

    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('v0213-review')),
      );
      final frame = await boundary.toImage(pixelRatio: 2);
      final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
      await File('${root.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      frame.dispose();
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncRepositoryProvider.overrideWith((ref) async => sync),
          readerRepositoryProvider.overrideWith((ref) async {
            ref.keepAlive();
            return reader;
          }),
          discoverRepositoryProvider.overrideWith(
            (ref) async => _OtherResults(reader),
          ),
          peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
          backgroundSyncEnabledProvider.overrideWithValue(false),
          syncControllerProvider.overrideWith(
            () => StaticSyncController(const SyncViewState()),
          ),
        ],
        child: const RepaintBoundary(
          key: Key('v0213-review'),
          child: ReaderApp(),
        ),
      ),
    );
    await until(() => find.text(book.title).evaluate().isNotEmpty);
    await capture('shelf-dock');
    final dock = tester.getRect(find.byKey(const Key('floating-dock')));
    report['dockBounds'] = [dock.left, dock.top, dock.width, dock.height];
    await phase('dock-check');
    expect(dock.height, 64);
    expect(dock.left, greaterThan(0));
    final router = ProviderScope.containerOf(
      tester.element(find.byType(ReaderApp)),
    ).read(appRouterProvider);
    router.go('/discover/results?mode=normal&q=合成验收');
    await phase('normal-search');
    await until(
      () =>
          find.byType(NormalSourceTabs).evaluate().isNotEmpty &&
          tester
                  .widget<NormalSourceTabs>(find.byType(NormalSourceTabs))
                  .controller
                  .index ==
              7,
    );
    final tabs = tester
        .widget<NormalSourceTabs>(find.byType(NormalSourceTabs))
        .controller;
    await phase('first-source');
    await until(
      () => find
          .byKey(const ValueKey('normal-source-s7'))
          .hitTestable()
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('normal-source-s7')).hitTestable(),
      findsOneWidget,
    );
    final pager = find.byKey(const Key('normal-results-pager'));
    await phase('first-source-swipe');
    await tester.drag(pager, const Offset(300, 0));
    await until(() => tabs.index == 6);
    expect(tabs.index, 6);
    await until(() => reader.slowDone);
    expect(
      tabs.index,
      6,
    ); // The late result must not take over a manual choice.
    await phase('source-scroll-retention');
    Future<void> select(int i) async {
      final label = find.byKey(ValueKey('normal-source-s$i'));
      await tester.ensureVisible(label);
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(tabs.index, i);
    }

    await select(0);
    final list = find.byKey(const PageStorageKey('normal-search-results-0-0'));
    await tester.drag(list, const Offset(0, -340));
    await tester.pumpAndSettle();
    final before = tester.widget<CustomScrollView>(list).controller!.offset;
    expect(before, greaterThan(250));
    await select(7);
    await select(0);
    expect(
      tester.widget<CustomScrollView>(list).controller!.offset,
      closeTo(before, 1),
    );
    final finger = await tester.startGesture(tester.getCenter(pager));
    // Cross touch slop first, then move again as a finger does on the device.
    await finger.moveBy(const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 30));
    await finger.moveBy(const Offset(-120, 0));
    await tester.pump(const Duration(milliseconds: 40));
    expect(tabs.animation!.value, inExclusiveRange(0, 1));
    await finger.moveBy(const Offset(140, 0));
    await finger.up();
    await tester.pumpAndSettle();
    expect(tabs.index, 0);
    await select(7);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(SearchResultDivider), findsWidgets);
    await capture('normal-results');
    await phase('other-results');
    router.go('/discover/results?mode=mh&q=合成验收');
    await until(
      () => find.widgetWithText(ListTile, '山海之间 1').evaluate().isNotEmpty,
    );
    expect(find.byType(SearchResultsSurface), findsOneWidget);
    expect(find.byType(SearchResultDivider), findsWidgets);
    await capture('other-results');
    await phase('reader-tools');
    router.go('/bookshelf');
    await tester.pumpAndSettle();
    await tester.tap(find.text(book.title).last);
    await until(
      () => find.byKey(const Key('reader-content')).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    final body = find.byKey(const Key('reader-content'));
    await tester.tapAt(tester.getCenter(body));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('reader-bottom-tools'))).height,
      lessThanOrEqualTo(106),
    );
    await capture('reader-tools');
    await tester.drag(
      find.byKey(const Key('reader-progress')),
      const Offset(25, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('目录').hitTestable(), findsOneWidget);
    await tester.drag(body, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(find.text('目录').hitTestable(), findsNothing);
    expect(find.byTooltip('返回书架').hitTestable(), findsNothing);
    await capture('reader-hidden');
    expect(tester.takeException(), isNull);
    report.addAll({
      'passed': true,
      'dockHeight': dock.height,
      'sourceScrollRetained': before,
      'firstSource': 7,
      'manualSourceRetained': 6,
    });
    await phase('complete');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
