import 'dart:async';
import 'dart:io';

import 'package:sorryread_mobile/sync_engine/sync_model.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_font_warmup.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_page.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_preferences.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_settings_sheet.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import 'reader_parsing_test.dart' show testSources, FixtureReaderRepository;
import 'support/test_runtime.dart';

class WidgetReaderRepository extends FixtureReaderRepository {
  WidgetReaderRepository(super.directory, super.rules, super.pages);
  final storage = <String, Map<String, dynamic>>{};
  int positionWrites = 0;
  int catalogRequests = 0;
  final chapterRequests = <String, int>{};
  final delayedPages = <String, Future<void>>{};
  final delayedReads = <String, Future<void>>{};
  @override
  Future<ReaderCatalog> catalog(
    SourceRule source,
    String detailUrl, {
    bool refresh = false,
  }) {
    catalogRequests++;
    return super.catalog(source, detailUrl, refresh: refresh);
  }

  @override
  Future<ReaderChapter> chapter(
    SourceRule source,
    ChapterLink link,
    List<ChapterLink> catalog, {
    bool refresh = false,
  }) {
    chapterRequests.update(link.url, (v) => v + 1, ifAbsent: () => 1);
    return super.chapter(source, link, catalog, refresh: refresh);
  }

  @override
  Future<String> fetch(SourceRule source, String url) async {
    await delayedPages[url];
    return super.fetch(source, url);
  }

  @override
  Future<Map<String, dynamic>?> read(String name) async {
    await delayedReads[name];
    return storage[name];
  }

  @override
  Future<void> write(String name, Map<String, dynamic> value) async {
    if (name.startsWith('position-')) positionWrites++;
    storage[name] = value;
  }
}

Future<void> flushReader(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> settleReader(WidgetTester tester) async {
  for (var i = 0; i < 80; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (find.byKey(const Key('reader-content')).evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 800));
      return;
    }
  }
  fail('Reader did not load');
}

Future<(WidgetReaderRepository, Directory)> mountReader(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
  int startChapter = 0,
  String chapterName = '',
  ReaderPreferences? preferences,
  Map<String, Future<void>> delayedPages = const {},
  Map<String, Future<void>> delayedReads = const {},
  FakeViewPadding safePadding = const FakeViewPadding(),
  bool awaitBody = true,
  Future<void>? fontWarmup,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = safePadding;
  tester.view.viewPadding = safePadding;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('sorryread/reader'),
        (call) async => call.method == 'battery' ? 73 : null,
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('sorryread/reader'),
          null,
        ),
  );
  final repo = (await tester.runAsync(() => testRepository(books: 1)))!;
  if (startChapter > 0) {
    await tester.runAsync(() async {
      final book = (await repo.books()).single;
      await repo.localChange(book.id, 'position', {
        ...book.metadata,
        'chapterUrl': 'https://example.invalid/chapter/$startChapter',
        'chapterTitle': '第${startChapter + 1}章',
        'chapterIndex': startChapter,
        'chapterCount': 10,
        'bookProgressChapterUrl':
            'https://example.invalid/chapter/$startChapter',
        'progress': 0,
      });
    });
  }
  final dir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('reader-widget-'),
  ))!;
  final rules = (await tester.runAsync(testSources))!;
  final source = SourceRule({
    'id': 'test',
    'baseUrl': 'https://example.invalid',
    'dynamic': false,
    'detail': <String, dynamic>{},
    'catalog': {'itemSelector': '#chapters a'},
    'chapter': {'contentSelector': '#content', 'titleSelector': 'h1'},
  });
  final reader = WidgetReaderRepository(
    dir,
    [...rules, source],
    {
      'https://example.invalid/book/0':
          '<div id="chapters">${List.generate(10, (i) => '<a href="/chapter/$i">第${i + 1}章</a>').join()}</div>',
      for (var i = 0; i < 10; i++)
        'https://example.invalid/chapter/$i':
            '<h1>第${i + 1}章 $chapterName</h1><div id="content">${List.generate(24, (p) => '<p>第$p 段：${'这是用于验收排版的合成正文，测试段落和行间距。' * 3}</p>').join()}</div>',
    },
  );
  if (preferences != null) reader.storage['preferences'] = preferences.toJson();
  reader.delayedPages.addAll(delayedPages);
  reader.delayedReads.addAll(delayedReads);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flushReader(tester);
    reader.dispose();
    await repo.close();
    await dir.delete(recursive: true);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (fontWarmup != null)
          readerFontWarmupProvider.overrideWithValue(() => fontWarmup),
        syncRepositoryProvider.overrideWith((ref) async => repo),
        readerRepositoryProvider.overrideWith((ref) async {
          // This fixture is shared across reader re-entry within one test.
          ref.keepAlive();
          ref.onDispose(reader.dispose);
          return reader;
        }),
        peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
        backgroundSyncEnabledProvider.overrideWithValue(false),
      ],
      child: const RepaintBoundary(
        key: Key('reader-review'),
        child: ReaderApp(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('最近阅读  1'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('测试书籍 0').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('测试书籍 0').last);
  if (awaitBody) {
    await settleReader(tester);
  } else {
    for (var i = 0; i < 20 && find.byType(ReaderPage).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
    }
  }
  return (reader, dir);
}

void main() {
  testWidgets(
    'active reader advances remotely across chapters without position echo or duplicate jumps',
    (tester) async {
      await mountReader(
        tester,
        preferences: const ReaderPreferences(mode: PageMode.scroll),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderPage)),
      );
      final sync = await tester.runAsync(
        () => container.read(syncRepositoryProvider.future),
      );
      final book = (await tester.runAsync(sync!.books))!.single;
      await flushReader(tester);
      final before = await tester.runAsync(() => sync.meta('seq'));
      const origin = '33333333333333333333333333333333';
      final event = SyncChange(
        entityId: book.id,
        group: 'position',
        origin: origin,
        seq: '1',
        clock: {origin: '1'},
        payload: {
          ...book.metadata,
          'chapterUrl': 'https://example.invalid/chapter/4',
          'chapterTitle': '第5章',
          'chapterIndex': 4,
          'chapterCount': 10,
          'bookProgressChapterUrl': 'https://example.invalid/chapter/4',
          'progress': .4,
          'contentHash': null,
          'paragraphIndex': null,
          'updatedUtc': '2030-01-01T00:00:00Z',
        },
      );
      await tester.runAsync(() => sync.applyRemote(origin, [event]));
      await flushReader(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reader-chapter-status')))
            .data!
            .trim(),
        '第5章',
      );
      expect(await tester.runAsync(() => sync.meta('seq')), before);
      final body = find.byKey(const Key('reader-content'));
      final controller = tester
          .widget<CustomScrollView>(
            find.descendant(of: body, matching: find.byType(CustomScrollView)),
          )
          .controller!;
      final received = controller.offset;
      controller.jumpTo(received - 100);
      await tester.pumpAndSettle();
      final reread = controller.offset;
      await tester.runAsync(() => sync.applyRemote(origin, [event]));
      await flushReader(tester);
      expect(controller.offset, closeTo(reread, 1));
      expect(
        (await tester.runAsync(() => sync.record(book.id, 'position')))!
            .effective
            .payload['chapterIndex'],
        4,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (var palette = 0; palette < 6; palette++) {
    testWidgets('catalogue and chapter footer use reader palette $palette', (
      tester,
    ) async {
      final preferences = ReaderPreferences(
        palette: palette,
        mode: PageMode.scroll,
      );
      final (reader, _) = await mountReader(
        tester,
        preferences: preferences,
        startChapter: 3,
        chapterName: '山间来信',
      );
      final status = tester.widget<Text>(
        find.byKey(const Key('reader-chapter-status')),
      );
      expect(status.data, '第4章 山间来信');
      final rect = tester.getRect(find.byKey(const Key('reader-content')));
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      await tester.tap(find.text('目录').hitTestable());
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('catalog-chapter-3'));
      final tile = tester.widget<ListTile>(row);
      expect(tile.selected, isTrue);
      expect(tile.selectedTileColor, Colors.transparent);
      expect(find.text('正在读'), findsOneWidget);
      final theme = Theme.of(tester.element(row));
      expect(theme.colorScheme.surface, preferences.background);
      expect(theme.colorScheme.onSurface, preferences.ink);
      final lighter = preferences.ink.computeLuminance();
      final darker = preferences.background.computeLuminance();
      final ratio = (lighter > darker
          ? (lighter + .05) / (darker + .05)
          : (darker + .05) / (lighter + .05));
      expect(ratio, greaterThan(7));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await flushReader(tester);
      final saved = reader.storage.entries
          .firstWhere((e) => e.key.startsWith('position-'))
          .value;
      expect(saved['chapterIndex'], 3);
      expect(saved['chapterCount'], 10);
      expect(saved['bookProgressChapterUrl'], saved['chapterUrl']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'brightness changes and late preloads do not reset an active drag',
    (tester) async {
      final ready = Completer<void>();
      addTearDown(() {
        if (!ready.isCompleted) ready.complete();
      });
      await mountReader(
        tester,
        preferences: const ReaderPreferences(mode: PageMode.scroll),
        delayedPages: {'https://example.invalid/chapter/1': ready.future},
      );
      final body = find.byKey(const Key('reader-content'));
      await tester.tapAt(tester.getCenter(body));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      final sheet = tester.widget<ReaderSettingsSheet>(
        find.byType(ReaderSettingsSheet),
      );
      sheet.onChanged(sheet.preferences.value.copyWith(brightness: .6));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final controller = tester
          .widget<CustomScrollView>(
            find.descendant(of: body, matching: find.byType(CustomScrollView)),
          )
          .controller!;
      final gesture = await tester.startGesture(tester.getCenter(body));
      await gesture.moveBy(const Offset(0, -240));
      await tester.pump(const Duration(milliseconds: 16));
      final before = controller.offset;
      expect(before, greaterThan(100));
      final oldExtent = controller.position.maxScrollExtent;
      ready.complete();
      await flushReader(tester);
      expect(controller.position.maxScrollExtent, greaterThan(oldExtent));
      expect(controller.offset, closeTo(before, .01));
      expect(controller.position.isScrollingNotifier.value, isTrue);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('slow held drag saves after idle, not after a quiet line', (
    tester,
  ) async {
    final (reader, _) = await mountReader(
      tester,
      preferences: const ReaderPreferences(mode: PageMode.scroll),
    );
    await flushReader(tester);
    final body = find.byKey(const Key('reader-content'));
    final gesture = await tester.startGesture(tester.getCenter(body));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));
    final count = reader.positionWrites;
    // A finger can remain on one line for longer than the old 650ms debounce.
    await tester.pump(const Duration(milliseconds: 900));
    expect(reader.positionWrites, count);
    await gesture.moveBy(const Offset(0, -3));
    await tester.pump(const Duration(milliseconds: 900));
    expect(reader.positionWrites, count);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await flushReader(tester);
    expect(reader.positionWrites, greaterThan(count));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'full screen, page taps, sliding toolbars, settings and exit preserve shelf actions',
    (tester) async {
      await mountReader(tester);
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(find.byType(NavigationBar).hitTestable(), findsNothing);
      expect(find.text('目录').hitTestable(), findsNothing);
      final body = find.byKey(const Key('reader-content'));
      final rect = tester.getRect(body);
      await tester.tapAt(Offset(rect.right - 15, rect.center.dy));
      await tester.pumpAndSettle();
      expect(find.text('目录').hitTestable(), findsNothing);
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      expect(find.text('目录').hitTestable(), findsOneWidget);
      expect(find.text('测试书籍 0').hitTestable(), findsOneWidget);
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettingsSheet), findsOneWidget);
      expect(find.text('上下滑动'), findsOneWidget);
      expect(find.text('背景'), findsNothing);
      expect(find.text('开启自动阅读'), findsNothing);
      expect(find.text('字体'), findsNothing);
      expect(find.text('系统字体 ›'), findsOneWidget);
      await tester.tap(find.text('A⁺'));
      await tester.pumpAndSettle();
      expect(find.text('23'), findsOneWidget);
      await tester.tap(find.text('系统字体 ›'));
      await tester.pumpAndSettle();
      for (final font in ['宋体', '黑体', '楷体', '思源黑体', '霞鹜文楷']) {
        expect(find.text(font), findsOneWidget);
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回书架').hitTestable());
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(find.text('我的书架'), findsOneWidget);
      var hapticCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') hapticCount++;
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.longPress(find.text('测试书籍 0').last);
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(hapticCount, 1);
      expect(find.text('加入收藏'), findsOneWidget);
      expect(find.text('移出最近阅读'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'scroll mode opens toolbars on either side; scroll position saves Unicode anchors',
    (tester) async {
      final (reader, _) = await mountReader(tester);
      final body = find.byKey(const Key('reader-content'));
      var rect = tester.getRect(body);
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('上下滑动'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('目录').hitTestable(), findsNothing);
      rect = tester.getRect(body);
      await tester.tapAt(Offset(rect.left + 10, rect.center.dy));
      await tester.pumpAndSettle();
      expect(find.text('目录').hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tapAt(Offset(rect.right - 10, rect.center.dy));
      await tester.pumpAndSettle();
      expect(find.text('目录').hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.drag(body, const Offset(0, -1000));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await flushReader(tester);
      final prefs = await tester.runAsync(() => reader.read('preferences'));
      expect(ReaderPreferences.fromJson(prefs!).mode, PageMode.scroll);
      expect(
        reader.storage.keys.where((f) => f.contains('position-')),
        isNotEmpty,
      );
      final list = tester.widget<CustomScrollView>(
        find.descendant(of: body, matching: find.byType(CustomScrollView)),
      );
      final controller = list.controller!;
      final before = controller.position.maxScrollExtent - 100;
      controller.jumpTo(before);
      await flushReader(tester);
      expect(reader.requested, contains('https://example.invalid/chapter/1'));
      expect(controller.offset, closeTo(before, 1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'chapter jump permits immediate backwards scrolling, with two previous and five following chapters warm',
    (tester) async {
      final (reader, _) = await mountReader(tester, startChapter: 4);
      await flushReader(tester);
      for (var i = 2; i <= 9; i++) {
        expect(
          reader.requested,
          contains('https://example.invalid/chapter/$i'),
        );
      }
      final body = find.byKey(const Key('reader-content'));
      await tester.tapAt(tester.getCenter(body));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('上下滑动'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('目录').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('第4章'));
      await flushReader(tester);
      var scroll = tester
          .widget<CustomScrollView>(
            find.descendant(of: body, matching: find.byType(CustomScrollView)),
          )
          .controller!;
      expect(scroll.offset, closeTo(0, 1));
      expect(scroll.position.minScrollExtent, lessThan(-100));
      // Drag down immediately after choosing a chapter to reveal its predecessor.
      await tester.drag(body, const Offset(0, 220));
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(-50));
      final previous = scroll.offset;
      await flushReader(tester);
      expect(scroll.offset, closeTo(previous, 1));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reader-chapter-status')))
            .data!
            .trim(),
        '第3章',
      );
      // Advance back through the boundary, then repeat via the next chapter button.
      scroll.jumpTo(30);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(body));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一章').hitTestable());
      await flushReader(tester);
      scroll = tester
          .widget<CustomScrollView>(
            find.descendant(of: body, matching: find.byType(CustomScrollView)),
          )
          .controller!;
      expect(scroll.offset, closeTo(0, 1));
      expect(scroll.position.minScrollExtent, lessThan(-100));
      await tester.drag(body, const Offset(0, 220));
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(-50));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reader-chapter-status')))
            .data!
            .trim(),
        '第4章',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final scenario in [
    (size: const Size(320, 640), scale: 2.0, brightness: Brightness.light),
    (size: const Size(844, 390), scale: 1.0, brightness: Brightness.dark),
  ]) {
    testWidgets('reader and sheet fit ${scenario.size} at ${scenario.scale}', (
      tester,
    ) async {
      await mountReader(
        tester,
        size: scenario.size,
        scale: scenario.scale,
        brightness: scenario.brightness,
      );
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('reader-content'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettingsSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
