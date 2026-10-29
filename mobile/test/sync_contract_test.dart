import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/sync_engine/sync_model.dart';

void main() {
  final fixtures = jsonDecode(
    File('../shared/fixtures/sync-v1.json').readAsStringSync(),
  ) as List;
  for (final raw in fixtures) {
    final fixture = raw as Json;
    test('shared contract: ${fixture['name']}', () {
      final changes = (fixture['changes'] as List)
          .map((c) => SyncChange.fromJson(c as Json))
          .toList();
      SyncRecord? forward, backward;
      for (final change in changes) {
        forward = mergeRecord(forward, change);
      }
      for (final change in changes.reversed) {
        backward = mergeRecord(backward, change);
      }
      expect(
        canonicalJson(forward!.toJson()),
        canonicalJson(backward!.toJson()),
      );
      expect(forward.versions.length, fixture['expectedVersions']);
      if (fixture.containsKey('expectedProgress')) {
        expect(
          forward.effective.payload['progress'],
          fixture['expectedProgress'],
        );
        expect(forward.hasPositionConflict, isFalse);
        final restored = SyncRecord.fromJson(
          jsonDecode(jsonEncode(forward.toJson())) as Json,
        );
        expect(
          restored.effective.payload['progress'],
          fixture['expectedProgress'],
        );
      }
      if (fixture.containsKey('expectedChapterIndex')) {
        expect(
          forward.effective.payload['chapterIndex'],
          fixture['expectedChapterIndex'],
        );
      }
      if (fixture.containsKey('expectedActive')) {
        expect(forward.effective.payload['active'], fixture['expectedActive']);
      }
    });
  }

  test(
    'WPF nullable coordinate serialization preserves immutable event identity',
    () {
      final event = SyncChange.fromJson(
        ((fixtures[0] as Json)['changes'] as List).first as Json,
      );
      final roundTrip = SyncChange.fromJson({
        ...event.toJson(),
        'payload': {
          ...event.payload,
          'paragraphIndex': null,
          'characterOffset': null,
          'contentHash': null,
          'chapterIndex': null,
          'chapterCount': null,
          'bookProgressChapterUrl': null,
        },
      });
      final merged = mergeRecord(mergeRecord(null, event), roundTrip);
      expect(merged.versions, hasLength(1));
      final forged = SyncChange.fromJson({
        ...roundTrip.toJson(),
        'payload': {...roundTrip.payload, 'progress': .99},
      });
      expect(() => mergeRecord(merged, forged), throwsFormatException);
    },
  );

  test('snapshot does not delete local records; mutations persist and do not echo remote changes', () async {
    final repo = SyncRepository(SyncDatabase(NativeDatabase.memory()));
    await repo.initialize();
    addTearDown(repo.close);
    final data = (fixtures[0] as Json)['changes'] as List;
    final event = SyncChange.fromJson(data.first as Json);
    await repo.applyRemote(event.origin, [event]);
    expect(await repo.received(event.origin), 1);
    expect(await repo.meta('seq'), '0');
    await repo.applySnapshot(event.origin, 1, []);
    expect(await repo.record(event.entityId, 'position'), isNotNull);
    final payload = {
      ...event.payload,
      'chapterUrl': '',
      'chapterTitle': '',
      'progress': 0,
      'active': true,
    };
    await repo.localChange(event.entityId, 'favorite', payload);
    expect((await repo.books()).single.favorite, isTrue);
    expect((await repo.localChangesAfter(0)).length, 1);
    await repo.setFavorite((await repo.books()).single, false);
    expect(await repo.books(), isEmpty);
    expect(await repo.record(event.entityId, 'position'), isNotNull);
    expect((await repo.localChangesAfter(0)).length, 2);
  });

  test('gap rejection rolls back the complete batch and cursor', () async {
    final repo = SyncRepository(SyncDatabase(NativeDatabase.memory()));
    await repo.initialize();
    addTearDown(repo.close);
    final event = SyncChange.fromJson(
      ((fixtures[0] as Json)['changes'] as List).first as Json,
    );
    final gap = SyncChange.fromJson({
      ...event.toJson(),
      'seq': '3',
      'clock': {event.origin: '3'},
    });
    await expectLater(
      repo.applyRemote(event.origin, [event, gap]),
      throwsFormatException,
    );
    expect(await repo.received(event.origin), 0);
    expect(await repo.record(event.entityId, 'position'), isNull);
  });

  test('acknowledged outbox can be cleared without losing full state; revoked session cannot apply', () async {
    final repo = SyncRepository(SyncDatabase(NativeDatabase.memory()));
    await repo.initialize();
    addTearDown(repo.close);
    final event = SyncChange.fromJson(
      ((fixtures[0] as Json)['changes'] as List).first as Json,
    );
    await expectLater(
      repo.applyRemote(
        event.origin,
        [event],
        guard: () async {
          throw StateError('Revoked session');
        },
      ),
      throwsStateError,
    );
    expect(await repo.received(event.origin), 0);
    expect(await repo.records(), isEmpty);
    await repo.localChange(event.entityId, event.group, event.payload);
    await repo.acknowledge(1);
    expect(await repo.localChangesAfter(0), isEmpty);
    final (seq, records) = await repo.exportSnapshot();
    expect(seq, 1);
    expect(records.single.versions.single.origin, repo.deviceId);
    final book = ShelfBook(
      event.entityId,
      event.payload,
      true,
      true,
      records.single,
      recentTime: '2030-01-01T00:00:00Z',
    );
    expect(book.readTime, '2030-01-01T00:00:00Z');
  });
}
