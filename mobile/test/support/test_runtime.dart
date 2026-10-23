import 'package:drift/native.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/sync_engine/sync_model.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

class MemoryPeerStorage implements PeerStorage {
  LinkedPeer? peer;
  @override
  Future<LinkedPeer?> read() async => peer;
  @override
  Future<void> write(LinkedPeer value) async {
    peer = value;
  }

  @override
  Future<void> delete() async {
    peer = null;
  }
}

Future<SyncRepository> testRepository({int books = 0}) async {
  final repo = SyncRepository(SyncDatabase(NativeDatabase.memory()));
  await repo.initialize();
  const origin = '11111111111111111111111111111111';
  for (var index = 0; index < books; index++) {
    final id = 'book:test|https://example.invalid/book/$index';
    final payload = <String, dynamic>{
      'kind': 'book',
      'title': '测试书籍 $index',
      'sourceId': 'test',
      'sourceName': '合成测试来源',
      'detailUrl': 'https://example.invalid/book/$index',
      'chapterUrl': 'https://example.invalid/chapter/$index',
      'chapterTitle': '测试章节',
      'progress': .25,
      'active': true,
      'updatedUtc': '2026-10-22T00:00:00Z',
    };
    await repo.applySnapshot(origin, index * 2 + 2, [
      SyncRecord(id, 'recent', [
        SyncChange(
          entityId: id,
          group: 'recent',
          origin: origin,
          seq: '${index * 2 + 1}',
          clock: {origin: '${index * 2 + 1}'},
          payload: {...payload, 'progress': 0},
        ),
      ]),
      SyncRecord(id, 'position', [
        SyncChange(
          entityId: id,
          group: 'position',
          origin: origin,
          seq: '${index * 2 + 2}',
          clock: {origin: '${index * 2 + 2}'},
          payload: payload,
        ),
      ]),
    ]);
  }
  return repo;
}
