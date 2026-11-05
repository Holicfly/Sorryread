import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/data/reading_history.dart';
import 'package:sorryread_mobile/sync_engine/sync_coordinator.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import 'support/test_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This opt-in fixture talks to the isolated pinned HTTPS host, not a fake client.
  HttpOverrides.global = null;
  final path = Platform.environment['SORRYREAD_SYNC_TICKET'];
  test(
    'live C# HTTPS / Dart bidirectional state, deletion and farthest progress',
    () async {
      final ticket = PairTicket.parse(
        File(path!).readAsStringSync(),
        allowLoopback: true,
      );
      final repo = SyncRepository(SyncDatabase(NativeDatabase.memory()));
      await repo.initialize();
      final storage = MemoryPeerStorage();
      final engine = SyncCoordinator(repo, storage, allowLoopback: true);
      addTearDown(() async {
        await engine.cancel();
        await repo.close();
      });
      final peer = await engine.pair(ticket);
      expect((await storage.read())!.serverId, ticket.serverId);
      final first = await engine.synchronize(peer, manual: true);
      expect(first, isNotNull);
      expect(first!.watchSupported, isTrue);
      final book = (await repo.books()).single;
      expect(book.favorite, isTrue);
      expect(book.recent, isTrue);
      expect(book.progress, .25);
      expect(await repo.meta('seq'), '0');
      final local = LocalLibrary(repo);
      await local.initialize();
      addTearDown(local.close);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 9);
      final desktop = (await local.readingOverview(today)).entries.single;
      expect(desktop.onDesktop, isTrue);
      expect(desktop.onPhone, isFalse);
      expect(desktop.milliseconds, 120000);
      await local.recordReading(
        {...book.metadata, 'author': '测试作者'},
        today,
        60000,
        bookId: book.id,
        position: ReadingPosition(
          chapterUrl: desktop.position!.chapterUrl,
          chapterTitle: desktop.position!.chapterTitle,
          chapterIndex: 0,
          chapterCount: 10,
        ),
      );
      final overview = await local.readingOverview(today);
      expect(overview.entries.single.onPhone, isTrue);
      expect(overview.entries.single.onDesktop, isTrue);
      expect(overview.month.milliseconds, 180000);
      expect(overview.month.chapters, 1);
      expect(overview.month.streak, 1);
      final stats = await local.combinedReadingStats();
      expect(stats.days[localDate(today)], 180000);
      expect(stats.milliseconds, 180000);
      expect(
        (await repo.records()).any(
          (r) => r.entityId == 'url:https://example.invalid/plain',
        ),
        isTrue,
      );
      await repo.setFavorite(book, false);
      await repo.removeRecent(book);
      await engine.synchronize(peer, manual: true);
      expect(await repo.books(), isEmpty);
      expect(await repo.record(book.id, 'position'), isNotNull);

      // Phone changes its own position while the isolated desktop makes an independent change.
      final old = (await repo.record(book.id, 'position'))!;
      await repo.localChange(book.id, 'position', {
        ...old.effective.payload,
        'progress': .4,
      });
      final command = File('${File(path).parent.path}/command.json');
      command.writeAsStringSync(
        jsonEncode({'kind': 'desktop-read', 'progress': .31}),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (command.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(command.existsSync(), isFalse);
      await engine.synchronize(peer, manual: true);
      final merged = (await repo.record(book.id, 'position'))!;
      expect(merged.hasPositionConflict, isFalse);
      expect(merged.effective.payload['progress'], .4);
      final beforeReread = await repo.meta('seq');
      await repo.localChange(book.id, 'position', {
        ...merged.effective.payload,
        'progress': .1,
      });
      expect(await repo.meta('seq'), beforeReread);
      await engine.synchronize(peer, manual: true);
      expect((await repo.books()).single.progress, .4);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final desktopState = jsonDecode(
        File('${File(path).parent.path}/state.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(desktopState['progress'], .4);

      // Repeated requests leave one book and no new local operations.
      final seq = await repo.meta('seq');
      await engine.synchronize(peer, manual: true);
      expect((await repo.books()).length, 1);
      expect(await repo.meta('seq'), seq);
      final entries = await repo.logs();
      expect(
        entries.any(
          (r) =>
              (r['message'] as String).contains('电脑 → 手机 · 《Synthetic book》'),
        ),
        isTrue,
      );
      expect(
        entries.any(
          (r) =>
              (r['message'] as String).contains('手机 → 电脑') &&
              (r['message'] as String).contains('阅读进度'),
        ),
        isTrue,
      );
      final idle = await engine.synchronize(peer);
      expect(idle!.uploaded + idle.downloaded, 0);
      expect(
        (await repo.logs()).length,
        entries.length,
        reason: 'An idle notification must not flood logs',
      );
      final container = ProviderContainer(
        overrides: [
          syncRepositoryProvider.overrideWith((ref) async => repo),
          peerStorageProvider.overrideWithValue(storage),
          syncCoordinatorProvider.overrideWithValue(engine),
          allowLoopbackSyncProvider.overrideWithValue(true),
          backgroundSyncEnabledProvider.overrideWithValue(false),
        ],
      );
      try {
        await container.read(syncControllerProvider.future);
        final controller = container.read(syncControllerProvider.notifier);
        await controller.synchronize();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final notification = Stopwatch()..start();
        command.writeAsStringSync(
          jsonEncode({'kind': 'desktop-read', 'progress': .66}),
        );
        while (notification.elapsed < const Duration(seconds: 4)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if ((await repo.record(
                book.id,
                'position',
              ))!.effective.payload['progress'] ==
              .66) {
            break;
          }
        }
        expect(
          (await repo.record(
            book.id,
            'position',
          ))!.effective.payload['progress'],
          .66,
          reason: 'Desktop change must arrive through notification before the polling fallback',
        );
        expect(
          container.read(syncControllerProvider).requireValue.busy,
          isFalse,
        );
        final beforeReading = await repo.received(peer.serverId);
        command.writeAsStringSync(jsonEncode({'kind': 'desktop-time'}));
        final timeNotification = Stopwatch()..start();
        while (timeNotification.elapsed < const Duration(seconds: 4)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if ((await local.combinedReadingStats()).milliseconds == 240000) {
            break;
          }
        }
        expect((await local.combinedReadingStats()).milliseconds, 240000);
        expect(await repo.received(peer.serverId), beforeReading);
        await controller.synchronize(manual: true);
        expect((await local.combinedReadingStats()).milliseconds, 240000);
        await controller.disconnect();
        expect(
          container.read(syncControllerProvider).requireValue.paused,
          isTrue,
        );
        command.writeAsStringSync(jsonEncode({'kind': 'desktop-time'}));
        final offlineDeadline = DateTime.now().add(const Duration(seconds: 5));
        while (command.existsSync() &&
            DateTime.now().isBefore(offlineDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(command.existsSync(), isFalse);
        await controller.reconnect();
        expect(
          container.read(syncControllerProvider).requireValue.connected,
          isTrue,
        );
        await controller.synchronize(manual: true);
        expect((await local.combinedReadingStats()).milliseconds, 300000);
      } finally {
        container.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    },
    skip: path == null
        ? 'Set SORRYREAD_SYNC_TICKET to an isolated test-host ticket'
        : false,
  );
}
