import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/sync_engine/sync_coordinator.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import 'support/test_runtime.dart';

void main() {
  final path = Platform.environment['SORRYREAD_SYNC_TICKET'];
  test(
    'live C# HTTPS / Dart bidirectional state, deletion and conflict resolution',
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
      final book = (await repo.books()).single;
      expect(book.favorite, isTrue);
      expect(book.recent, isTrue);
      expect(book.progress, .25);
      expect(await repo.meta('seq'), '0');
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
        'progress': .45,
      });
      final command = File('${File(path).parent.path}/command.json');
      command.writeAsStringSync(
        jsonEncode({'kind': 'desktop-read', 'progress': .8}),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (command.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(command.existsSync(), isFalse);
      await engine.synchronize(peer, manual: true);
      final conflict = (await repo.record(book.id, 'position'))!;
      expect(conflict.versions.length, 2);
      final phone = conflict.versions.singleWhere(
        (v) => v.origin == repo.deviceId,
      );
      await repo.resolvePosition(conflict, phone);
      await engine.synchronize(peer, manual: true);
      expect((await repo.record(book.id, 'position'))!.versions.length, 1);
      expect((await repo.books()).single.progress, .45);

      // Repeated requests leave one book and no new local operations.
      final seq = await repo.meta('seq');
      await engine.synchronize(peer, manual: true);
      expect((await repo.books()).length, 1);
      expect(await repo.meta('seq'), seq);
    },
    skip: path == null
        ? 'Set SORRYREAD_SYNC_TICKET to an isolated test-host ticket'
        : false,
  );
}
