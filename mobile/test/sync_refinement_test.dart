import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';
import 'package:sorryread_mobile/sync_engine/sync_coordinator.dart';
import 'package:sorryread_mobile/sync_engine/sync_details.dart';
import 'package:sorryread_mobile/sync_engine/sync_model.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import 'support/test_runtime.dart';

class ControlledSync extends SyncCoordinator {
  ControlledSync(super.repo, super.storage);
  final calls = <({bool manual, Completer<SyncReport?> result})>[];
  @override
  Future<SyncReport?> synchronize(
    LinkedPeer peer, {
    bool manual = false,
    bool discover = true,
    bool eagerDiscovery = false,
    void Function(LinkedPeer)? onConnected,
  }) {
    final result = Completer<SyncReport?>();
    calls.add((manual: manual, result: result));
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'reading coalesces projections while durable changes remain available',
    () async {
      final repo = await testRepository(books: 1);
      addTearDown(repo.close);
      final book = (await repo.books()).single;
      var projections = 0, uploads = 0;
      final projectionSub = repo.changes.stream.listen((_) => projections++);
      final uploadSub = repo.localChanges.stream.listen((_) => uploads++);
      addTearDown(projectionSub.cancel);
      addTearDown(uploadSub.cancel);
      repo.setReaderScrolling(true);
      for (var i = 0; i < 3; i++) {
        await repo.localChange(book.id, 'position', {
          ...book.metadata,
          'progress': .3 + i / 10,
        });
      }
      await Future<void>.delayed(Duration.zero);
      expect(projections, 0);
      expect(uploads, 3);
      expect(
        (await repo.record(book.id, 'position'))!.effective.payload['progress'],
        .5,
      );
      expect(await repo.records(group: 'position'), hasLength(1));
      repo.setReaderScrolling(false);
      await Future<void>.delayed(Duration.zero);
      expect(projections, 1);
      repo.setReaderScrolling(false);
      await Future<void>.delayed(Duration.zero);
      expect(projections, 1);
    },
  );
  test('logs retain all records within 24 hours and prune expired records on reading', () async {
    final repo = await testRepository();
    addTearDown(repo.close);
    final received = <List<Json>>[];
    final subscription = repo.watchLogs().listen(received.add);
    addTearDown(subscription.cancel);
    for (var i = 0; i < 205; i++) {
      await repo.log(true, '合成记录 $i');
    }
    await repo.db.customStatement(
      'INSERT INTO sync_logs(time_utc,success,message) VALUES(?,?,?)',
      [
        DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 25))
            .toIso8601String(),
        1,
        '过期记录',
      ],
    );
    expect(await repo.logs(), hasLength(205));
    final expired = await repo.db
        .customSelect(
          'SELECT count(*) AS n FROM sync_logs WHERE message=?',
          variables: [Variable('过期记录')],
        )
        .getSingle();
    expect(expired.read<int>('n'), 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(received.last.first['message'], '合成记录 204');
  });
  test('detailed messages distinguish shelf, recent, progress and direction; progress is coalesced', () async {
    final repo = await testRepository(books: 1);
    addTearDown(repo.close);
    final book = (await repo.books()).single;
    final details = SyncDetails();
    for (final group in ['favorite', 'recent', 'position']) {
      await repo.localChange(book.id, group, book.metadata);
    }
    details.sent(await repo.localChangesAfter(0));
    await repo.localChange(book.id, 'position', {
      ...book.metadata,
      'chapterTitle': '第十章',
      'progress': .625,
    });
    details.sent(await repo.localChangesAfter(3));
    details.received([book.position!.effective]);
    expect(details.messages, hasLength(4));
    expect(details.messages[0], contains('手机 → 电脑 · 《测试书籍 0》'));
    expect(details.messages[0], contains('书架收藏'));
    expect(details.messages[1], contains('最近阅读'));
    expect(details.messages[2], contains('第十章 · 62.5%'));
    expect(details.messages[3], contains('电脑 → 手机'));
  });
  test(
    'remote applies do not emit local triggers or duplicate applied details',
    () async {
      final repo = await testRepository(books: 1);
      addTearDown(repo.close);
      var local = 0;
      final subscription = repo.localChanges.stream.listen((_) => local++);
      addTearDown(subscription.cancel);
      final (_, records) = await repo.exportSnapshot();
      final origin = records.first.effective.origin;
      expect(await repo.applySnapshot(origin, 2, records), isEmpty);
      expect(local, 0);
      final book = (await repo.books()).single;
      await repo.localChange(book.id, 'position', book.metadata);
      await Future<void>.delayed(Duration.zero);
      expect(local, 1);
    },
  );
  test('automatic sync preserves action state and manual clicks queue one serialized follow-up', () async {
    final repo = await testRepository();
    final storage = MemoryPeerStorage();
    final engine = ControlledSync(repo, storage);
    final container = ProviderContainer(
      overrides: [
        syncRepositoryProvider.overrideWith((ref) async => repo),
        peerStorageProvider.overrideWithValue(storage),
        syncCoordinatorProvider.overrideWithValue(engine),
        backgroundSyncEnabledProvider.overrideWithValue(false),
      ],
    );
    await container.read(syncControllerProvider.future);
    final peer = LinkedPeer(
      serverId: '1' * 32,
      name: '测试电脑',
      endpoints: ['https://127.0.0.1:12345'],
      pin: '2' * 64,
      credential: '3' * 64,
    );
    final controller = container.read(syncControllerProvider.notifier);
    // A paired state avoids real sockets; the coordinator is controlled by completions.
    controller.state = AsyncData(SyncViewState(peer: peer, connected: true));
    final automatic = controller.synchronize();
    expect(engine.calls, hasLength(1));
    expect(container.read(syncControllerProvider).requireValue.busy, isFalse);
    final manual = controller.synchronize(manual: true);
    final duplicate = controller.synchronize(manual: true);
    expect(engine.calls, hasLength(1));
    engine.calls[0].result.complete(SyncReport(peer, 0, 0));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(engine.calls, hasLength(2));
    expect(engine.calls[1].manual, isTrue);
    expect(container.read(syncControllerProvider).requireValue.busy, isTrue);
    engine.calls[1].result.complete(SyncReport(peer, 0, 0));
    await Future.wait([automatic, manual, duplicate]);
    expect(engine.calls, hasLength(2));
    expect(container.read(syncControllerProvider).requireValue.busy, isFalse);
    final leased = controller.synchronize();
    expect(engine.calls, hasLength(3));
    engine.calls[2].result.complete(null);
    await leased;
    await Future<void>.delayed(const Duration(milliseconds: 5200));
    expect(
      engine.calls,
      hasLength(4),
      reason: 'A busy background lease must not drop pending foreground work',
    );
    expect(engine.calls[3].manual, isFalse);
    engine.calls[3].result.complete(SyncReport(peer, 0, 0));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    await repo.close();
  });
}
