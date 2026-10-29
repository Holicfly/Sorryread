import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
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
  SyncViewState? syncState,
  Future<void> Function(SyncRepository)? seed,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
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
    'three tabs retain scroll position; Android back returns to bookshelf',
    (tester) async {
      await launch(tester);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      expect(find.text('我的书架'), findsOneWidget);

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

  testWidgets(
    'real filters and sync entry; remaining profile items stay placeholders',
    (tester) async {
      await launch(tester);
      await tester.tap(find.text('最近阅读  9'));
      await tester.pumpAndSettle();
      expect(
        router(tester).routeInformationProvider.value.uri.path,
        '/bookshelf',
      );
      expect(find.text('收藏  9'), findsOneWidget);
      await tester.tap(find.text('与电脑同步'));
      await tester.pumpAndSettle();
      expect(
        router(tester).routeInformationProvider.value.uri.path,
        '/profile/sync',
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
      expect(
        router(tester).routeInformationProvider.value.uri.path,
        '/profile',
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty library contains no demo books', (tester) async {
    await launch(tester, bookCount: 0);
    expect(find.text('暂无收藏书籍'), findsOneWidget);
    expect(find.text('人间草木'), findsNothing);
    expect(find.text('收藏  0'), findsOneWidget);
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
