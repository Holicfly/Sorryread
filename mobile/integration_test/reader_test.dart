import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;
import 'dart:ui' show FramePhase;

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/features/reader/data/reader_platform.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_cover.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_settings_sheet.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_curl.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import '../test/reader_parsing_test.dart' show FixtureReaderRepository;
import '../test/support/test_runtime.dart';
import '../test/app_shell_test.dart' show StaticSyncController;

import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('CAPTURE_SCREENSHOTS');
  var imageReady = false;
  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    if (!imageReady) {
      await binding.convertFlutterSurfaceToImage();
      imageReady = true;
      await tester.pumpAndSettle();
    }
    await binding.takeScreenshot(name);
  }

  Future<void> loaded(WidgetTester tester) async {
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byKey(const Key('reader-content')).evaluate().isNotEmpty) {
        await tester.pumpAndSettle();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('阅读页加载超时');
  }

  testWidgets(
    'Android reading: native battery, layout, settings, scroll, chapter switch and persistence',
    (tester) async {
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/reader-device-test',
      );
      await dir.create(recursive: true);
      final repo = await testRepository();
      final payload = <String, dynamic>{
        'kind': 'book',
        'title': '山间来信 · 阅读验收',
        'sourceId': 'test',
        'sourceName': '合成排版样例',
        'detailUrl': 'https://example.invalid/book/1',
        'chapterUrl': '',
        'chapterTitle': '',
        'progress': 0,
        'active': true,
        'updatedUtc': DateTime.now().toUtc().toIso8601String(),
      };
      const id = 'book:test|https://example.invalid/book/1';
      await repo.localChange(id, 'favorite', payload);
      for (var i = 0; i < 6; i++) {
        final sourceId = i == 5 ? '18mh' : 'test';
        final extra = {
          ...payload,
          'title': i == 5
              ? '分组验收样例'
              : ['人间草木', '山海之间', '竹林听风', '湖上来信', '海风与云'][i],
          'sourceId': sourceId,
          'detailUrl': 'https://example.invalid/book/extra-$i',
        };
        await repo.localChange(
          'book:$sourceId|${extra['detailUrl']}',
          'favorite',
          extra,
        );
      }
      final source = SourceRule({
        'id': 'test',
        'baseUrl': 'https://example.invalid',
        'dynamic': false,
        'detail': <String, dynamic>{},
        'catalog': {'itemSelector': '#chapters a'},
        'chapter': {'contentSelector': '#content', 'titleSelector': 'h1'},
      });
      final reader = FixtureReaderRepository(
        dir,
        [source],
        {
          'https://example.invalid/book/1': '<div id="chapters"><a href="/chapter/1">第一章 山间来信</a><a href="/chapter/2">第二章 雨后的路</a><a href="/chapter/3">第三章 灯火</a></div>',
          for (var i = 1; i <= 3; i++)
            'https://example.invalid/chapter/$i':
                '<h1>第$i章 ${['山间来信', '雨后的路', '灯火'][i - 1]}</h1><div id="content">${List.generate(18, (p) => '<p>${['山里的清晨，总是从一阵轻风开始。窗外的树叶轻轻摇动，阳光穿过枝叶，在书页上留下细碎的光影。', '我把昨天没有读完的信重新展开。纸上的文字安静而清晰，像一条缓缓流过山谷的小溪。', '远处传来鸟鸣，桌上的茶还冒着热气。这是一个适合读书的早晨，时间仿佛也慢了下来。'][p % 3]}</p>').join()}</div>',
        },
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 200));
        reader.dispose();
        await repo.close();
        await dir.delete(recursive: true);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncRepositoryProvider.overrideWith((ref) async => repo),
            readerRepositoryProvider.overrideWith((ref) async => reader),
            peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
            backgroundSyncEnabledProvider.overrideWithValue(false),
            syncControllerProvider.overrideWith(
              () => StaticSyncController(
                SyncViewState(
                  peer: LinkedPeer(
                    serverId: '1' * 32,
                    name: '验收用电脑',
                    endpoints: ['https://192.168.1.2:12345'],
                    pin: '2' * 64,
                    credential: '3' * 64,
                  ),
                  connected: true,
                ),
              ),
            ),
          ],
          child: const ReaderApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏 6'), findsOneWidget);
      await screenshot(tester, 'bookshelf-covers');
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const Key('shelf-tab-favorites')));
        await tester.pump(const Duration(milliseconds: 90));
      }
      await tester.pumpAndSettle();
      expect(find.text('收藏 1'), findsOneWidget);
      expect(find.text('分组验收样例'), findsWidgets);
      await screenshot(tester, 'bookshelf-hidden-group');
      expect(await repo.books(), hasLength(7));
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const Key('shelf-tab-favorites')));
        await tester.pump(const Duration(milliseconds: 90));
      }
      await tester.pumpAndSettle();
      final cover = find.byWidgetPredicate(
        (w) => w is BookCover && w.title == payload['title'],
      );
      await Scrollable.ensureVisible(tester.element(cover), alignment: .2);
      await tester.pumpAndSettle();
      await tester.tap(cover);
      await loaded(tester);
      expect(find.text('目录').hitTestable(), findsNothing);
      final level = await ReaderPlatform().battery();
      expect(level, inInclusiveRange(0, 100));
      expect(
        await ReaderPlatform().decode(
          'GB18030',
          Uint8List.fromList([0xD6, 0xD0, 0xCE, 0xC4]),
        ),
        '中文',
      );
      await screenshot(tester, 'reader-fullscreen');
      final rect = tester.getRect(find.byKey(const Key('reader-content')));
      final footerBefore = tester.getTopLeft(find.text('$level%'));
      await tester.tapAt(Offset(rect.right - 10, rect.center.dy));
      if (capture) {
        final controller =
            tester
                    .widget<AnimatedBuilder>(
                      find.descendant(
                        of: find.byKey(const Key('reader-content')),
                        matching: find.byType(AnimatedBuilder),
                      ),
                    )
                    .animation
                as AnimationController;
        controller.stop();
        controller.value = .5;
        await tester.pump();
        final curl = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is PaperCurlPainter,
        );
        expect(tester.getSize(curl), rect.size);
        await screenshot(tester, 'reader-curl');
        controller.forward();
      }
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('$level%')), footerBefore);
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      expect(find.text('目录').hitTestable(), findsOneWidget);
      await screenshot(tester, 'reader-toolbar');
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      await screenshot(tester, 'reader-settings');
      expect(find.byType(ReaderSettingsSheet), findsOneWidget);
      await tester.tap(find.text('A⁺'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('系统字体 ›'));
      await tester.pumpAndSettle();
      await screenshot(tester, 'reader-fonts');
      expect(find.text('方正黑体'), findsNothing);
      expect(find.text('方正楷体'), findsNothing);
      await tester.tap(find.text('霞鹜文楷'));
      for (
        var attempt = 0;
        attempt < 100 && find.byType(ReaderFontSheet).evaluate().isNotEmpty;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('霞鹜文楷 ›'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('墨黑'));
      await tester.pumpAndSettle();
      await screenshot(tester, 'reader-black-settings');
      await tester.tap(find.text('上下滑动'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('PROFILE_READER')) {
        final slow = await measureScrollScenario(tester, 'slow-drag', () async {
          for (var i = 0; i < 4; i++) {
            await tester.timedDrag(
              find.byKey(const Key('reader-content')),
              Offset(0, i < 2 ? -180 : 180),
              const Duration(seconds: 3),
              frequency: 120,
            );
            await tester.pumpAndSettle();
          }
        });
        final fling = await measureScrollScenario(tester, 'fling', () async {
          for (var i = 0; i < 12; i++) {
            await tester.fling(
              find.byKey(const Key('reader-content')),
              Offset(0, i < 6 ? -480 : 480),
              1000,
            );
            await tester.pumpAndSettle();
          }
        });
        Map<String, dynamic>? nativeInput;
        if (const bool.fromEnvironment('PROFILE_NATIVE_INPUT')) {
          nativeInput = await measureScrollScenario(
            tester,
            'android-input',
            () async {
              // Host sends Android MotionEvents during this window; no tester drag.
              // Keep screenshot conversion disabled for rendering measurements.
              debugPrint('READER_NATIVE_INPUT_READY');
              await Future<void>.delayed(const Duration(seconds: 35));
            },
          );
        }
        binding.reportData = {
          ...?binding.reportData,
          'scrollProfile': {
            'measurement': 'Flutter framework timings; presentation/input traces must be collected separately',
            'resamplingEnabled': GestureBinding.instance.resamplingEnabled,
            'scenarios': {
              'slowDrag': slow,
              'fling': fling,
              'androidInput': ?nativeInput,
            },
          },
        };
      }
      await tester.tapAt(Offset(rect.left + 8, rect.center.dy));
      await tester.pumpAndSettle();
      expect(find.text('目录').hitTestable(), findsOneWidget);
      await tester.tap(find.text('夜间').hitTestable());
      await tester.pumpAndSettle();
      await screenshot(tester, 'reader-night');
      await tester.tap(find.text('目录').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('正在读'), findsOneWidget);
      final active = tester.widget<ListTile>(
        find.byWidgetPredicate((w) => w is ListTile && w.selected),
      );
      expect(active.selectedTileColor, Colors.transparent);
      await screenshot(tester, 'reader-black-catalog');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('日间').hitTestable());
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('reader-content')),
        const Offset(0, -650),
      );
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        (await repo.record(
          id,
          'position',
        ))?.effective.payload['paragraphIndex'],
        greaterThan(0),
      );
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      await tester.tap(find.text('目录').hitTestable());
      await tester.pumpAndSettle();
      await screenshot(tester, 'reader-catalog');
      await tester.tap(find.text('第二章 雨后的路'));
      await loaded(tester);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      expect(scroll.offset, closeTo(0, 1));
      await tester.drag(
        find.byKey(const Key('reader-content')),
        const Offset(0, 220),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(-50));
      await screenshot(tester, 'reader-previous-chapter');
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回书架').hitTestable());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bookshelf-tabs')), findsOneWidget);
      final position = (await repo.record(id, 'position'))!.effective.payload;
      expect(position['chapterUrl'], 'https://example.invalid/chapter/2');
      expect((await reader.read('preferences'))!['font'], 'wenkai');
      expect(position['chapterCount'], 3);
      expect(position['chapterIndex'], 1);
      final shelfBook = (await repo.books()).singleWhere((b) => b.id == id);
      expect(
        shelfBook.bookProgress,
        closeTo((1 + (position['progress'] as num)) / 3, .0001),
      );
      await Scrollable.ensureVisible(tester.element(cover), alignment: .2);
      await tester.pumpAndSettle();
      await tester.tap(cover);
      await loaded(tester);
      expect(find.byKey(const Key('reader-chapter-status')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reader-chapter-status')))
            .data,
        '第二章 雨后的路',
      );
      // Recent sync preview and the full-day record route use the app's theme.
      for (final message in [
        '手机 → 电脑 · 《山间来信》\n书架收藏 · 已收藏',
        '电脑 → 手机 · 《雨后的路》\n最近阅读 · 更新记录',
        '手机 → 电脑 · 《山间来信》\n阅读进度 · 第二章 雨后的路 · 38.5%',
      ]) {
        await repo.log(true, message);
      }
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderApp)),
      );
      container.read(appRouterProvider).go('/profile/sync');
      await tester.pumpAndSettle();
      await screenshot(tester, 'sync-recent');
      await tester.ensureVisible(find.text('更多记录'));
      await tester.tap(find.text('更多记录'));
      await tester.pumpAndSettle();
      expect(find.text('最近 24 小时同步记录'), findsOneWidget);
      await screenshot(tester, 'sync-records');
      binding.reportData = {
        ...?binding.reportData,
        'battery': level,
        'nativeGbk': true,
        'settingsPersisted': true,
        'positionRestored': true,
        'bundledFontOffline': true,
        'sourceGroupsIsolated': true,
        'bookProgress': shelfBook.bookProgress,
        'visibleCoverDesign': tester
            .widgetList<BookCover>(find.byType(BookCover))
            .map((w) => w.design)
            .toList(),
      };
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android live source: real catalog, merged paragraphs and offline cache',
    (tester) async {
      final rules =
          (jsonDecode(await rootBundle.loadString('assets/reader_sources.json'))
                  as List)
              .map((e) => SourceRule(Map<String, dynamic>.from(e as Map)))
              .toList();
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/reader-live-test',
      );
      final repo = ReaderRepository(dir, rules);
      addTearDown(() async {
        repo.dispose();
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final source = repo.source(
        'wodushu',
        'https://www.wodushu.com/book/186078/',
      );
      final catalog = await repo.catalog(
        source,
        'https://www.wodushu.com/book/186078/',
      );
      expect(catalog.chapters.length, greaterThan(1));
      final chapter = await repo.chapter(
        source,
        catalog.chapters.first,
        catalog.chapters,
      );
      expect(chapter.paragraphs.length, greaterThan(1));
      expect(chapter.text.runes.length, greaterThan(100));
      repo.http.close(force: true);
      expect(
        (await repo.chapter(
          source,
          catalog.chapters.first,
          catalog.chapters,
        )).hash,
        chapter.hash,
      );
      binding.reportData = {
        ...binding.reportData ?? {},
        'liveCatalogChapters': catalog.chapters.length,
        'liveParagraphs': chapter.paragraphs.length,
        'liveCharacters': chapter.text.runes.length,
        'offlineCache': true,
      };
    },
    skip: !const bool.fromEnvironment('RUN_READER_LIVE'),
  );
}

/// Capture raw timestamps to correlate with a device trace. Neither totalSpan
/// nor UI/raster budget counts alone prove that a frame was presented on time.
Future<Map<String, dynamic>> measureScrollScenario(
  WidgetTester tester,
  String name,
  Future<void> Function() action,
) async {
  final frames = <FrameTiming>[];
  void collect(List<FrameTiming> values) => frames.addAll(values);
  final trace = developer.TimelineTask()..start('reader.scroll.$name');
  SchedulerBinding.instance.addTimingsCallback(collect);
  try {
    await action();
    await Future<void>.delayed(const Duration(milliseconds: 350));
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(collect);
    trace.finish();
  }
  expect(frames.length, greaterThan(30));
  double percentile(List<double> values, double p) {
    values.sort();
    return values[(values.length * p).floor().clamp(0, values.length - 1)];
  }

  final refresh = tester.view.display.refreshRate;
  final budget = 1000 / refresh;
  final build = frames
      .map((f) => f.buildDuration.inMicroseconds / 1000)
      .toList();
  final raster = frames
      .map((f) => f.rasterDuration.inMicroseconds / 1000)
      .toList();
  return {
    'frames': frames.length,
    'displayReportedRefreshRateHz': refresh,
    'buildP95Ms': percentile(build, .95),
    'buildP99Ms': percentile(build, .99),
    'rasterP95Ms': percentile(raster, .95),
    'rasterP99Ms': percentile(raster, .99),
    'buildMaxMs': build.last,
    'rasterMaxMs': raster.last,
    'frameworkOverBudgetFrames': frames
        .where(
          (f) =>
              f.buildDuration.inMicroseconds / 1000 > budget ||
              f.rasterDuration.inMicroseconds / 1000 > budget,
        )
        .length,
    'rawFrameworkSamples': [
      for (final f in frames)
        {
          'vsyncStartUs': f.timestampInMicroseconds(FramePhase.vsyncStart),
          'buildUs': f.buildDuration.inMicroseconds,
          'rasterUs': f.rasterDuration.inMicroseconds,
          'vsyncOverheadUs': f.vsyncOverhead.inMicroseconds,
          'totalSpanUs': f.totalSpan.inMicroseconds,
        },
    ],
  };
}
