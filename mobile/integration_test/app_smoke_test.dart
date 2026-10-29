import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/core/discovery/peer_discovery.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import '../test/support/test_runtime.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('CAPTURE_SCREENSHOTS');
  const live = bool.fromEnvironment('RUN_LIVE_SYNC');
  bool surfaceReady = false;

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    if (!surfaceReady) {
      await binding.convertFlutterSurfaceToImage();
      surfaceReady = true;
      await tester.pumpAndSettle();
    }
    await binding.takeScreenshot(name);
  }

  Future<void> mount(
    WidgetTester tester,
    SyncRepository repo,
    PeerStorage storage,
  ) async {
    surfaceReady = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncRepositoryProvider.overrideWith((ref) async => repo),
          peerStorageProvider.overrideWithValue(storage),
          backgroundSyncEnabledProvider.overrideWithValue(false),
          allowLoopbackSyncProvider.overrideWithValue(live),
        ],
        child: const ReaderApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Android: empty shelf, sync page, native camera and private persistence',
    (tester) async {
      final repo = await testRepository();
      await mount(tester, repo, MemoryPeerStorage());
      expect(find.text('我的书架'), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      await screenshot(tester, 'empty-shelf');
      await tester.tap(find.text('与电脑同步'));
      await tester.pumpAndSettle();
      expect(find.text('连接新设备'), findsOneWidget);
      expect(find.text('同步内容'), findsNothing);
      await screenshot(tester, 'unpaired');
      await tester.tap(find.text('连接新设备'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileScanner), findsOneWidget);
      // Give the native camera time to start; no physical QR scan is claimed by this test.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pumpAndSettle();
      final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
      expect(scanner.controller!.value.isRunning, isTrue);
      await screenshot(tester, 'camera');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('连接新设备'), findsOneWidget);
      final mine = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('我的'),
      );
      await tester.tap(mine);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await screenshot(tester, 'profile');
      await tester.pumpWidget(const SizedBox.shrink());
      await repo.close();

      await tester.runAsync(() async {
        final root = await getApplicationSupportDirectory();
        final file = File('${root.path}/sync-integration-only.db');
        final disk = SyncRepository(
          SyncDatabase(NativeDatabase.createInBackground(file)),
        );
        await disk.initialize();
        await disk.setMeta('integration', 'persisted');
        final identity = disk.deviceId;
        await disk.close();
        final reopened = SyncRepository(
          SyncDatabase(NativeDatabase.createInBackground(file)),
        );
        await reopened.initialize();
        expect(reopened.deviceId, identity);
        expect(await reopened.meta('integration'), 'persisted');
        await reopened.close();
        for (final suffix in ['', '-wal', '-shm']) {
          final artifact = File('${file.path}$suffix');
          if (await artifact.exists()) await artifact.delete();
        }
        final secure = SecurePeerStorage(key: 'sorryread.integration-only');
        final fake = LinkedPeer(
          serverId: '1' * 32,
          name: 'Synthetic storage',
          endpoints: ['https://192.168.1.2:1234'],
          pin: '2' * 64,
          credential: '3' * 64,
        );
        await secure.write(fake);
        expect(
          (await SecurePeerStorage(
            key: 'sorryread.integration-only',
          ).read())!.credential,
          fake.credential,
        );
        await secure.delete();
        expect(await secure.read(), isNull);
        final discovery = PeerDiscovery();
        expect(await discovery.find('f' * 32), isEmpty);
        await discovery.stop();
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android: pinned HTTPS, real books, disconnect, restart and delete',
    (tester) async {
      final directory = await getApplicationSupportDirectory();
      final input = File('${directory.path}/sync-ticket.json');
      final repo = await testRepository();
      final storage = SecurePeerStorage(key: 'sorryread.integration-live-only');
      await storage.delete();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await storage.delete();
        await repo.close();
        if (await input.exists()) await input.delete();
      });
      await mount(tester, repo, storage);
      await tester.tap(find.text('与电脑同步'));
      await tester.pumpAndSettle();
      // Host injects a fresh, short-lived synthetic QR payload after this test starts.
      final raw = await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 120));
        while (!await input.exists()) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('Missing isolated test ticket');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        return input.readAsString();
      });
      final ticket = PairTicket.parse(raw!, allowLoopback: true);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderApp)),
      );
      var controller = container.read(syncControllerProvider.notifier);
      await tester.runAsync(() => controller.pair(ticket));
      await tester.pumpAndSettle();
      var status = container.read(syncControllerProvider).requireValue;
      expect(status.connected, isTrue, reason: status.error);
      expect(find.text('连接新设备'), findsNothing);
      expect(find.text('删除当前连接设备'), findsOneWidget);
      expect((await repo.books()).single.favorite, isTrue);
      expect((await repo.books()).single.progress, .25);
      expect(
        (await repo.records()).any(
          (r) => r.entityId == 'url:https://example.invalid/plain',
        ),
        isTrue,
      );
      await screenshot(tester, 'paired');
      await tester.tap(find.text('查看同步记录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('同步完成'), findsWidgets);
      await screenshot(tester, 'records');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final shelf = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('书架'),
      );
      await tester.tap(shelf);
      await tester.pumpAndSettle();
      await screenshot(tester, 'synced-shelf');
      await tester.tap(find.text('与电脑同步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('断开连接'));
      await tester.pumpAndSettle();
      expect(
        container.read(syncControllerProvider).requireValue.paused,
        isTrue,
      );
      expect(find.text('重新连接'), findsOneWidget);
      expect(await storage.read(), isNotNull);
      await screenshot(tester, 'disconnected');
      // Re-create the application controller to model a new application run.
      await tester.runAsync(() async {
        container.invalidate(syncControllerProvider);
        await container.read(syncControllerProvider.future);
        controller = container.read(syncControllerProvider.notifier);
        await Future<void>.delayed(const Duration(seconds: 2));
        await controller.synchronize(manual: true);
      });
      await tester.pumpAndSettle();
      status = container.read(syncControllerProvider).requireValue;
      expect(status.paused, isFalse);
      expect(status.connected, isTrue, reason: status.error);
      final book = (await repo.books()).single;
      await tester.runAsync(() async {
        await repo.setFavorite(book, false);
        await repo.removeRecent(book);
        await controller.synchronize(manual: true);
      });
      await tester.pumpAndSettle();
      expect(await repo.books(), isEmpty);
      expect(await repo.record(book.id, 'position'), isNotNull);
      await tester.ensureVisible(find.text('删除当前连接设备'));
      await tester.tap(find.text('删除当前连接设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(find.text('连接新设备'), findsOneWidget);
      expect(await storage.read(), isNull);
      expect(await repo.record(book.id, 'position'), isNotNull);
      expect(tester.takeException(), isNull);
    },
    skip: !live,
  );
}
