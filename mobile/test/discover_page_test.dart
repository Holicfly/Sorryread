import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/features/discover/data/discover_repository.dart';
import 'package:sorryread_mobile/features/discover/data/yeshe_index.dart';
import 'package:sorryread_mobile/features/discover/presentation/discover_page.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_page.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import 'app_shell_test.dart' show navigationLabel, router;
import 'reader_page_test.dart'
    show WidgetReaderRepository, flushReader, settleReader;
import 'reader_parsing_test.dart' show testSources;
import 'support/test_runtime.dart';
import 'yeshe_index_test.dart' show FakeYesheIndex;

class PageDiscoverRepository extends DiscoverRepository {
  PageDiscoverRepository(super.reader);
  final requests = <String>[];
  @override
  Future<DiscoverBatch> fetch(DiscoverMode mode, String url) async {
    requests.add(url);
    final night = mode == DiscoverMode.yeshe;
    final second = url.endsWith(night ? '5-2.html' : '/page/2');
    return DiscoverBatch(
      [
        for (var i = second ? 20 : 0; i < (second ? 28 : 20); i++)
          DiscoverBook(
            '${night ? '夜社' : '搜索'}书籍 ${i + 1}',
            night
                ? '$yesheBase/artdetail-${i + 42}.html'
                : 'https://18mh.net/novel/detail/${i + 42}',
            mode,
          ),
      ],
      second
          ? null
          : night
          ? '$yesheBase/arttype/5-2.html'
          : '$url/page/2',
      total: 28,
    );
  }
}

Future<PageDiscoverRepository> mountDiscover(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
  FakeYesheIndex? index,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
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
  final sync = (await tester.runAsync(() => testRepository()))!;
  final dir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('discover-page-'),
  ))!;
  final rules = (await tester.runAsync(testSources))!;
  final reader = WidgetReaderRepository(dir, rules, {
    '$yesheBase/artdetail-42.html':
        '''<div class="detailinfo"><h1>湖畔故事</h1></div>
      <div class="videolist"><a class="link" href="/artrss-42/nid/1.html">第一章</a>
      <a class="link" href="/artrss-42/nid/2.html">第二章</a></div>''',
    for (var i = 1; i <= 2; i++)
      '$yesheBase/artrss-42/nid/$i.html':
          '<div class="picslist"><div class="content">${List.generate(30, (n) => '<p>第$n 段合成正文，用于验证章节入口、记录与阅读排版。</p>').join()}</div></div>',
    'https://18mh.net/novel/detail/42': '''<a class="detail-page__catalog-item" href="/novel_chapter/42/1.html"><span class="detail-page__chapter-title">第一章</span></a>''',
    'https://18mh.net/novel_chapter/42/1.html': '<main class="app-content"><div class="article"><p>合成的小说正文。</p></div></main>',
  });
  final discover = PageDiscoverRepository(reader);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        syncRepositoryProvider.overrideWith((ref) async => sync),
        readerRepositoryProvider.overrideWith((ref) async {
          ref.onDispose(reader.dispose);
          return reader;
        }),
        discoverRepositoryProvider.overrideWith((ref) async => discover),
        yesheIndexRepositoryProvider.overrideWithValue(
          index ?? FakeYesheIndex(),
        ),
        peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
        backgroundSyncEnabledProvider.overrideWithValue(false),
      ],
      child: const RepaintBoundary(
        key: Key('discover-preview'),
        child: ReaderApp(),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flushReader(tester);
    reader.dispose();
    await sync.close();
    await dir.delete(recursive: true);
  });
  await tester.pumpAndSettle();
  await tester.tap(navigationLabel('发现'));
  await flushReader(tester);
  await tester.pumpAndSettle();
  return discover;
}

Future<void> toggle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.tap(find.byKey(const Key('discover-heading')));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<void> screenshot(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('DISCOVER_SCREENSHOTS')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('discover-preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../artifacts/discover-preview/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/sourceHan.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('five taps toggle both ways; tab switch retains mode', (
    tester,
  ) async {
    final repo = await mountDiscover(tester);
    expect(find.text('YS1'), findsNothing);
    await screenshot(tester, 'normal');
    expect(repo.requests, isEmpty);
    await toggle(tester);
    expect(find.text('YS1'), findsOneWidget);
    await screenshot(tester, 'special');
    await tester.tap(navigationLabel('我的'));
    await tester.pumpAndSettle();
    await tester.tap(navigationLabel('发现'));
    await tester.pumpAndSettle();
    expect(find.text('YS1'), findsOneWidget);
    await toggle(tester);
    expect(find.text('YS1'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'search pages append on scroll, preserve list on reader return and finish',
    (tester) async {
      final repo = await mountDiscover(tester);
      await toggle(tester);
      await tester.enterText(find.byType(TextField), '山间来信');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(find.text('搜索书籍 1'), findsOneWidget);
      expect(repo.requests, hasLength(1));
      await screenshot(tester, 'search-results');
      await tester.tap(find.text('搜索书籍 1'));
      await settleReader(tester);
      expect(find.byType(ReaderPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(find.byType(DiscoverResultsPage), findsOneWidget);
      final list = find.byKey(const PageStorageKey('discover-results-scroll'));
      await tester.scrollUntilVisible(
        find.text('搜索书籍 28'),
        450,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(repo.requests, hasLength(2));
      expect(find.text('已展示全部结果'), findsOneWidget);
      await tester.drag(list, const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(repo.requests, hasLength(2));
      await tester.binding.handlePopRoute();
      await flushReader(tester);
      expect(find.byType(DiscoverResultsPage), findsNothing);
      expect(find.widgetWithText(InputChip, '山间来信'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'history editing shows delete controls and clears only the selected source',
    (tester) async {
      await mountDiscover(tester, size: const Size(320, 640), scale: 2);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderApp)),
      );
      await tester.runAsync(() async {
        final history = await container.read(discoverHistoryProvider.future);
        await history.add(DiscoverMode.normal, '普通词条');
        await history.add(DiscoverMode.mh, '第一条');
        await history.add(DiscoverMode.mh, '第二条');
      });
      container.invalidate(discoverHistoryEntriesProvider(DiscoverMode.normal));
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, '普通词条'), findsOneWidget);
      expect(find.byTooltip('删除这条记录'), findsNothing);
      await toggle(tester);
      await flushReader(tester);
      final chip = find.widgetWithText(InputChip, '第一条');
      expect(chip, findsOneWidget);
      expect(find.byTooltip('删除这条记录'), findsNothing);
      await tester.tap(find.byTooltip('管理搜索记录'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('删除这条记录'), findsNWidgets(2));
      await tester.tap(
        find.descendant(of: chip, matching: find.byTooltip('删除这条记录')),
      );
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(chip, findsNothing);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('删除这条记录'), findsNothing);
      await tester.tap(find.byTooltip('管理搜索记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部删除'));
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(find.text('暂无搜索记录'), findsOneWidget);
      await toggle(tester);
      expect(find.widgetWithText(InputChip, '普通词条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'YS1 overlays help and reuses the cache action for detected updates',
    (tester) async {
      final index = FakeYesheIndex()
        ..saved = const YesheIndexStatus({
          'status': 'paused',
          'count': 120,
          'pages': 4,
          'total': 300,
        });
      await mountDiscover(tester, index: index);
      await toggle(tester);
      await tester.tap(find.text('YS1'));
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(find.text('夜社书籍 1'), findsOneWidget);
      await tester.enterText(find.byType(TextField).hitTestable(), '山间');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('山间 0'), findsOneWidget);
      expect(find.text('夜社书籍 1'), findsNothing);
      await tester.tap(find.byTooltip('清空输入'));
      await tester.pumpAndSettle();
      expect(find.text('夜社书籍 1'), findsOneWidget);
      final help = find.byKey(const Key('yeshe-index-help'));
      final hint = find.byKey(const Key('yeshe-index-help-overlay'));
      final action = find.byKey(const Key('yeshe-index-action'));
      final wave = find.byKey(const Key('yeshe-cache-wave'));
      Finder actionIcon(String file) => find.descendant(
        of: action,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName.endsWith('/$file.png'),
        ),
      );
      Finder progress(String value) => find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.value == value,
      );
      expect(find.text('继续缓存'), findsOneWidget);
      expect(actionIcon('ys1_download'), findsOneWidget);
      expect(progress('40%'), findsOneWidget);
      final helpPosition = tester.getRect(help);
      final listPosition = tester.getRect(find.text('夜社书籍 1'));
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(hint, findsOneWidget);
      expect(
        tester.getBottomRight(hint).dy,
        lessThan(tester.getTopLeft(help).dy),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.getRect(help), helpPosition);
      expect(tester.getRect(find.text('夜社书籍 1')), listPosition);
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(hint, findsNothing);
      await tester.tapAt(
        tester.getRect(action).centerRight - const Offset(8, 0),
      );
      await tester.pump();
      expect(find.text('暂停'), findsOneWidget);
      expect(wave, findsOneWidget);
      expect(tester.getRect(wave), tester.getRect(action));
      expect(index.starts, 1);
      index.saved = const YesheIndexStatus({
        'status': 'running',
        'count': 180,
        'pages': 6,
        'total': 300,
      });
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 400));
      expect(progress('60%'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(index.pauses, 1);
      expect(find.text('继续缓存'), findsOneWidget);
      expect(progress('60%'), findsOneWidget);
      expect(wave, findsOneWidget);
      index.saved = const YesheIndexStatus({
        'status': 'complete',
        'count': 300,
        'pages': 10,
        'total': 300,
      });
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('已缓存'), findsOneWidget);
      expect(tester.widget<InkWell>(action).onTap, isNull);
      index.saved = YesheIndexStatus({
        ...index.saved.data,
        'updateAvailable': true,
      });
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('等待更新'), findsOneWidget);
      expect(actionIcon('ys1_update'), findsOneWidget);
      await tester.tap(action);
      await tester.pump();
      expect(find.text('正在更新'), findsOneWidget);
      expect(index.refreshes, 1);
      expect(index.starts, 2);
      index.saved = const YesheIndexStatus({'status': 'idle', 'count': 0});
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('缓存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'night direct chapter opens correct chapter, records recent and remains outside normal shelf',
    (tester) async {
      final repo = await mountDiscover(tester);
      await toggle(tester);
      await tester.tap(find.text('YS1'));
      await flushReader(tester);
      await tester.pumpAndSettle();
      await screenshot(tester, 'night-results');
      await tester.enterText(
        find.byType(TextField).hitTestable(),
        'https://outside.invalid/artdetail-42.html',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('请粘贴 yeshezy1.com 的小说或章节 HTTPS 网址。'), findsOneWidget);
      final reader = repo.reader as WidgetReaderRepository;
      final book = const DiscoverBook(
        '湖畔故事',
        '$yesheBase/artdetail-42.html',
        DiscoverMode.yeshe,
      ).toShelfBook();
      reader.storage['position-${reader.key(book.id)}'] = {
        ...book.metadata,
        'chapterUrl': '$yesheBase/artrss-42/nid/1.html',
        'progress': .5,
      };
      await tester.enterText(
        find.byType(TextField).hitTestable(),
        '$yesheBase/artrss-42/nid/2.html',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settleReader(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reader-chapter-status')))
            .data,
        '第二章',
      );
      await tester.binding.handlePopRoute();
      await flushReader(tester);
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderApp)),
      );
      final sync = await container.read(syncRepositoryProvider.future);
      final books = (await tester.runAsync(sync.books))!;
      expect(books.single.title, '湖畔故事');
      expect(books.single.recent, isTrue);
      expect(books.single.favorite, isFalse);
      expect(books.single.isSpecialSource, isTrue);
      expect(
        books.single.position!.effective.payload['chapterUrl'],
        '$yesheBase/artrss-42/nid/2.html',
      );
      router(tester).go('/bookshelf');
      await tester.pumpAndSettle();
      expect(find.text('最近阅读 0'), findsOneWidget);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const Key('shelf-tab-favorites')));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(find.text('最近阅读 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final scenario in [
    (
      name: 'small-large-text',
      size: const Size(320, 640),
      scale: 2.0,
      brightness: Brightness.light,
    ),
    (
      name: 'dark',
      size: const Size(390, 844),
      scale: 1.0,
      brightness: Brightness.dark,
    ),
    (
      name: 'landscape',
      size: const Size(844, 390),
      scale: 1.0,
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets('discover and results fit ${scenario.name}', (tester) async {
      await mountDiscover(
        tester,
        size: scenario.size,
        scale: scenario.scale,
        brightness: scenario.brightness,
      );
      await toggle(tester);
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'special-${scenario.name}');
      await tester.ensureVisible(find.text('YS1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('YS1'));
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('yeshe-index-action')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'night-${scenario.name}');
    });
  }
}
