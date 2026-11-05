import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/data/reading_history.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/features/profile/presentation/reading_history_page.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import 'support/test_runtime.dart';

class StaticSyncController extends SyncController {
  StaticSyncController(this.initial);
  final SyncViewState initial;
  @override
  Future<SyncViewState> build() async => initial;
  void setStatus(SyncViewState value) => state = AsyncData(value);
  @override
  Future<void> disconnect() async {
    state = AsyncData(
      state.requireValue.copyWith(paused: true, connected: false),
    );
  }

  @override
  Future<void> reconnect() async {
    state = AsyncData(
      state.requireValue.copyWith(paused: false, connected: true),
    );
  }

  @override
  Future<void> forgetPeer() async {
    state = AsyncData(
      state.requireValue.copyWith(
        clearPeer: true,
        paused: false,
        connected: false,
      ),
    );
  }
}

Finder navigationLabel(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Future<SyncRepository> launch(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
  int bookCount = 9,
  FakeViewPadding safePadding = const FakeViewPadding(top: 24, bottom: 24),
  SyncViewState? syncState,
  bool disableAnimations = false,
  Future<void> Function(SyncRepository)? seed,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = safePadding;
  tester.view.viewPadding = safePadding;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: disableAnimations);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  final repo = (await tester.runAsync(() => testRepository(books: bookCount)))!;
  await tester.runAsync(() async {
    for (final book in await repo.books()) {
      await repo.setFavorite(book, true);
    }
    await seed?.call(repo);
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await repo.close();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        syncRepositoryProvider.overrideWith((ref) async => repo),
        peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
        backgroundSyncEnabledProvider.overrideWithValue(false),
        if (syncState != null)
          syncControllerProvider.overrideWith(
            () => StaticSyncController(syncState),
          ),
      ],
      child: const ReaderApp(),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

GoRouter router(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ReaderApp)))
        .read(appRouterProvider);

void main() {
  testWidgets(
    'dock floats over content; final profile row clears it and keyboard hides it',
    (tester) async {
      await launch(tester);
      final dock = find.byKey(const Key('floating-dock'));
      final rect = tester.getRect(dock);
      expect(rect.left, 16);
      expect(rect.right, 374);
      expect(rect.height, 64);
      expect(rect.bottom, lessThan(844 - 24));
      expect(
        tester
            .getRect(find.byKey(const PageStorageKey('bookshelf-scroll')))
            .bottom,
        greaterThan(rect.bottom),
      );
      await tester.tap(navigationLabel('我的'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('关于应用'),
        300,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('profile-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.drag(
        find.byKey(const PageStorageKey('profile-scroll')),
        const Offset(0, -1000),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('关于应用')).bottom, lessThan(rect.top));
      await tester.tap(navigationLabel('发现'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(dock, findsNothing);
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(dock, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'profile shows today reading above its label and updates duration',
    (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await launch(
        tester,
        seed: (repo) async {
          final library = LocalLibrary(repo);
          await library.initialize();
          await library.recordReading(
            {'title': '测试书籍 0'},
            DateTime(now.year, now.month, now.day - 1, 12),
            const Duration(minutes: 90).inMilliseconds,
          );
          await library.recordReading(
            {'title': '测试书籍 0'},
            today,
            const Duration(minutes: 7).inMilliseconds,
          );
          await library.close();
        },
      );
      await tester.tap(navigationLabel('我的'));
      await tester.pumpAndSettle();
      final todayLabel = find.text('今日阅读');
      final todayStat = find
          .ancestor(of: todayLabel, matching: find.byType(Column))
          .first;
      final todayDuration = find.descendant(
        of: todayStat,
        matching: find.text('7 分钟'),
      );
      expect(todayDuration, findsOneWidget);
      expect(
        tester.getCenter(todayDuration).dy,
        lessThan(tester.getCenter(todayLabel).dy),
      );
      expect(
        tester.getCenter(todayDuration).dx,
        tester.getCenter(todayLabel).dx,
      );
      expect(find.text('1.6 小时'), findsOneWidget);
      expect(find.text('阅读时长'), findsOneWidget);
      expect(find.text('已读书籍'), findsOneWidget);
      expect(find.text('连续阅读'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderApp)),
      );
      await tester.runAsync(() async {
        final library = await container.read(localLibraryProvider.future);
        await library.recordReading(
          {'title': '测试书籍 0'},
          today,
          const Duration(minutes: 5).inMilliseconds,
        );
      });
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: todayStat, matching: find.text('12 分钟')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reading-time cells show device splits independently and reset', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 10);
    final yesterday = DateTime(now.year, now.month, now.day - 1, 10);
    DesktopReadingEntry desktopEntry(
      int revision,
      DateTime date,
      int minutes,
    ) => DesktopReadingEntry.fromJson({
      'revision': revision,
      'day': localDate(date),
      'lastRead': date.toIso8601String(),
      'bookId': 'book:test|https://example.invalid/book/0',
      'title': '测试书籍 0',
      'milliseconds': minutes * 60000,
      'chapterTitle': '测试章节',
      'chapterUrl': 'https://example.invalid/book/0/chapter/1',
      'progress': .5,
    });
    final repo = await launch(
      tester,
      size: const Size(320, 640),
      scale: 2,
      seed: (repo) async {
        final local = LocalLibrary(repo);
        await local.initialize();
        await local.recordReading({'title': '测试书籍 0'}, today, 7 * 60000);
        await local.recordReading({'title': '测试书籍 0'}, yesterday, 24 * 60000);
        await local.close();
        await repo.applyDesktopReading('test-pc', [
          desktopEntry(1, yesterday, 15),
          desktopEntry(2, today, 11),
        ]);
      },
    );
    router(tester).go('/profile');
    await tester.pumpAndSettle();
    final todayCell = find.byKey(const ValueKey('reading-time-今日阅读'));
    final totalCell = find.byKey(const ValueKey('reading-time-阅读时长'));
    Finder cellText(Finder cell, String value) =>
        find.descendant(of: cell, matching: find.text(value));
    await tester.ensureVisible(todayCell);
    await tester.pumpAndSettle();
    expect(cellText(todayCell, '18 分钟'), findsOneWidget);
    expect(cellText(totalCell, '57 分钟'), findsOneWidget);
    final bounds = tester.getRect(todayCell);

    await tester.tap(todayCell);
    await tester.pumpAndSettle();
    expect(tester.getRect(todayCell), bounds);
    expect(cellText(todayCell, '手机'), findsOneWidget);
    expect(cellText(todayCell, '7 分钟'), findsOneWidget);
    expect(cellText(todayCell, '电脑'), findsOneWidget);
    expect(cellText(todayCell, '11 分钟'), findsOneWidget);
    expect(cellText(totalCell, '57 分钟'), findsOneWidget);

    await tester.tap(totalCell);
    await tester.pumpAndSettle();
    expect(cellText(todayCell, '7 分钟'), findsOneWidget);
    expect(cellText(totalCell, '31 分钟'), findsOneWidget);
    expect(cellText(totalCell, '26 分钟'), findsOneWidget);
    await tester.runAsync(
      () => repo.applyDesktopReading('test-pc', [desktopEntry(3, today, 12)]),
    );
    await tester.pumpAndSettle();
    expect(cellText(todayCell, '12 分钟'), findsOneWidget);
    expect(cellText(totalCell, '27 分钟'), findsOneWidget);

    await tester.tap(todayCell);
    await tester.pumpAndSettle();
    expect(cellText(todayCell, '19 分钟'), findsOneWidget);
    expect(cellText(totalCell, '27 分钟'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(cellText(totalCell, '58 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'three tabs retain scroll position; Android back returns to bookshelf',
    (tester) async {
      await launch(tester);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      expect(find.byKey(const Key('bookshelf-tabs')), findsOneWidget);

      final shelf = find.byKey(const PageStorageKey('bookshelf-scroll'));
      await tester.drag(shelf, const Offset(0, -230));
      await tester.pumpAndSettle();
      final offset = tester
          .state<ScrollableState>(
            find.descendant(of: shelf, matching: find.byType(Scrollable)),
          )
          .position
          .pixels;
      expect(offset, greaterThan(0));

      await tester.tap(navigationLabel('我的'));
      await tester.pumpAndSettle();
      expect(
        router(tester).routeInformationProvider.value.uri.path,
        '/profile',
      );
      expect(find.text('本地读者'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        router(tester).routeInformationProvider.value.uri.path,
        '/bookshelf',
      );
      expect(
        tester
            .state<ScrollableState>(
              find.descendant(of: shelf, matching: find.byType(Scrollable)),
            )
            .position
            .pixels,
        closeTo(offset, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('real filters, sync entry and reading history navigation', (
    tester,
  ) async {
    await launch(tester);
    await tester.tap(find.text('最近阅读 9'));
    await tester.pumpAndSettle();
    expect(
      router(tester).routeInformationProvider.value.uri.path,
      '/bookshelf',
    );
    expect(find.text('收藏 9'), findsOneWidget);
    await tester.tap(find.text('与电脑同步'));
    await tester.pumpAndSettle();
    expect(
      router(tester).routeInformationProvider.value.uri.path,
      '/bookshelf/sync',
    );
    expect(find.text('连接新设备'), findsOneWidget);
    expect(find.text('删除当前连接设备'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    router(tester).go('/profile');
    await tester.pumpAndSettle();
    await tester.tap(navigationLabel('我的'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('阅读记录'));
    await tester.tap(find.text('阅读记录'));
    await tester.pumpAndSettle();
    expect(find.byType(ReadingHistoryPage), findsOneWidget);
    expect(find.byKey(const Key('reading-month-dock')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('本地读者'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty library contains no demo books', (tester) async {
    await launch(tester, bookCount: 0);
    expect(find.text('暂无收藏书籍'), findsOneWidget);
    expect(find.text('人间草木'), findsNothing);
    expect(find.text('收藏 0'), findsOneWidget);
  });

  testWidgets(
    'one paired device replaces add row; disconnect differs from forget',
    (tester) async {
      final peer = LinkedPeer(
        serverId: '22222222222222222222222222222222',
        name: '测试电脑',
        endpoints: ['https://192.168.1.2:12345'],
        pin: List.filled(64, 'a').join(),
        credential: List.filled(64, 'b').join(),
      );
      await launch(
        tester,
        syncState: SyncViewState(peer: peer, connected: true),
      );
      await tester.tap(find.text('与电脑同步'));
      await tester.pumpAndSettle();
      expect(find.text('连接新设备'), findsNothing);
      expect(find.text('测试电脑'), findsOneWidget);
      expect(find.text('删除当前连接设备'), findsOneWidget);
      await tester.tap(find.text('断开连接'));
      await tester.pumpAndSettle();
      expect(find.text('重新连接'), findsOneWidget);
      expect(find.text('测试电脑'), findsOneWidget);
      await tester.tap(find.text('重新连接'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除当前连接设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除当前连接设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('连接新设备'), findsOneWidget);
      expect(find.text('测试电脑'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (
      name: 'small screen, 200% text',
      size: const Size(320, 640),
      scale: 2.0,
      brightness: Brightness.light,
    ),
    (
      name: 'dark mode',
      size: const Size(390, 844),
      scale: 1.0,
      brightness: Brightness.dark,
    ),
    (
      name: 'landscape safe area',
      size: const Size(844, 390),
      scale: 1.0,
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets('both pages fit ${scenario.name}', (tester) async {
      await launch(
        tester,
        size: scenario.size,
        scale: scenario.scale,
        brightness: scenario.brightness,
      );
      expect(tester.takeException(), isNull);
      final shelf = find.byKey(const PageStorageKey('bookshelf-scroll'));
      await tester.drag(shelf, const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(navigationLabel('我的'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('关于应用'),
        200,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('profile-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('关于应用').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      router(tester).go('/profile/sync');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
