import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../sync_engine/sync_model.dart';

class SyncDatabase extends GeneratedDatabase {
  SyncDatabase(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      for (final sql in [
        'CREATE TABLE sync_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
        'CREATE TABLE sync_records(entity TEXT NOT NULL,field_group TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(entity,field_group))',
        'CREATE TABLE sync_changes(origin TEXT NOT NULL,seq INTEGER NOT NULL,json TEXT NOT NULL,PRIMARY KEY(origin,seq))',
        'CREATE TABLE sync_received(origin TEXT PRIMARY KEY,seq INTEGER NOT NULL)',
        'CREATE TABLE sync_logs(id INTEGER PRIMARY KEY AUTOINCREMENT,time_utc TEXT NOT NULL,success INTEGER NOT NULL,message TEXT NOT NULL)',
      ]) {
        await customStatement(sql);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA busy_timeout=5000');
      await customStatement('PRAGMA journal_mode=WAL');
    },
  );
}

String randomId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

class ShelfBook {
  ShelfBook(
    this.id,
    this.metadata,
    this.favorite,
    this.recent,
    this.position, {
    this.recentTime,
  });
  final String id;
  final Json metadata;
  final bool favorite, recent;
  final SyncRecord? position;
  final String? recentTime;
  String get title => metadata['title'] as String;
  String get source => metadata['sourceName'] as String;
  String get readTime {
    final positionTime =
        position?.effective.payload['updatedUtc'] as String? ??
        metadata['updatedUtc'] as String;
    return recentTime != null &&
            DateTime.parse(recentTime!).isAfter(DateTime.parse(positionTime))
        ? recentTime!
        : positionTime;
  }

  bool get conflicted => (position?.versions.length ?? 0) > 1;
  double get progress =>
      (position?.effective.payload['progress'] as num?)?.toDouble() ?? 0;
}

class SyncRepository {
  SyncRepository(this.db);
  final SyncDatabase db;
  late final String deviceId;
  final changes = StreamController<void>.broadcast();

  Future<void> initialize() async {
    await db.transaction(() async {
      deviceId = await meta('deviceId') ?? randomId();
      await setMeta('deviceId', deviceId);
      if (await meta('seq') == null) await setMeta('seq', '0');
    });
  }

  Future<void> close() async {
    await changes.close();
    await db.close();
  }

  Future<String?> meta(String key) async =>
      (await db
              .customSelect(
                'SELECT value FROM sync_meta WHERE key=?',
                variables: [Variable(key)],
              )
              .getSingleOrNull())
          ?.read<String>('value');
  Future<void> setMeta(String key, String value) => db.customStatement(
    'INSERT INTO sync_meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  Future<int> received(String origin) async =>
      (await db
              .customSelect(
                'SELECT seq FROM sync_received WHERE origin=?',
                variables: [Variable(origin)],
              )
              .getSingleOrNull())
          ?.read<int>('seq') ??
      0;
  Future<void> _setReceived(String origin, int seq) => db.customStatement(
    'INSERT INTO sync_received VALUES(?,?) ON CONFLICT(origin) DO UPDATE SET seq=excluded.seq',
    [origin, seq],
  );

  Future<bool> acquireLease(String owner) => db.transaction(() async {
    final until = int.tryParse(await meta('leaseUntil') ?? '0') ?? 0;
    if (until > DateTime.now().millisecondsSinceEpoch) return false;
    await setMeta('leaseOwner', owner);
    await setMeta(
      'leaseUntil',
      '${DateTime.now().millisecondsSinceEpoch + 40000}',
    );
    return true;
  });
  Future<void> renewLease(String owner) => db.transaction(() async {
    if (await meta('leaseOwner') != owner) throw StateError('同步会话已变更');
    await setMeta(
      'leaseUntil',
      '${DateTime.now().millisecondsSinceEpoch + 40000}',
    );
  });
  Future<void> releaseLease(String owner) => db.transaction(() async {
    if (await meta('leaseOwner') == owner) await setMeta('leaseUntil', '0');
  });

  Future<SyncRecord?> record(String entity, String group) async {
    final row = await db
        .customSelect(
          'SELECT json FROM sync_records WHERE entity=? AND field_group=?',
          variables: [Variable(entity), Variable(group)],
        )
        .getSingleOrNull();
    return row == null
        ? null
        : SyncRecord.fromJson(jsonDecode(row.read<String>('json')) as Json);
  }

  Future<List<SyncRecord>> records() async =>
      (await db
              .customSelect(
                'SELECT json FROM sync_records ORDER BY entity,field_group',
              )
              .get())
          .map(
            (r) =>
                SyncRecord.fromJson(jsonDecode(r.read<String>('json')) as Json),
          )
          .toList();
  Future<void> _writeRecord(SyncRecord state) => db.customStatement(
    'INSERT INTO sync_records VALUES(?,?,?) ON CONFLICT(entity,field_group) DO UPDATE SET json=excluded.json',
    [state.entityId, state.group, jsonEncode(state.toJson())],
  );

  Future<void> localChange(
    String entity,
    String group,
    Json payload, {
    bool resolve = false,
  }) async {
    await db.transaction(() async {
      final old = await record(entity, group);
      Iterable<SyncChange> observed = old?.versions ?? [];
      if (!resolve && group == 'position' && observed.length > 1) {
        observed = [
          observed.where((v) => v.origin == deviceId).firstOrNull ??
              observed.first,
        ];
      }
      final seq = sequence(await meta('seq') ?? '0') + 1;
      final clock = joinClocks(observed)..[deviceId] = '$seq';
      final event = SyncChange(
        entityId: entity,
        group: group,
        origin: deviceId,
        seq: '$seq',
        clock: clock,
        payload: {
          ...payload,
          'updatedUtc': DateTime.now().toUtc().toIso8601String(),
        },
      );
      final merged = mergeRecord(old, event);
      await _writeRecord(merged);
      await db.customStatement('INSERT INTO sync_changes VALUES(?,?,?)', [
        deviceId,
        seq,
        jsonEncode(event.toJson()),
      ]);
      await setMeta('seq', '$seq');
    });
    changes.add(null);
  }

  Future<List<SyncChange>> localChangesAfter(int after) async =>
      (await db
              .customSelect(
                'SELECT json FROM sync_changes WHERE origin=? AND seq>? ORDER BY seq LIMIT 128',
                variables: [Variable(deviceId), Variable(after)],
              )
              .get())
          .map(
            (r) =>
                SyncChange.fromJson(jsonDecode(r.read<String>('json')) as Json),
          )
          .toList();

  Future<void> applyRemote(
    String origin,
    List<SyncChange> events, {
    Future<void> Function()? guard,
  }) async {
    if (events.length > 128) throw const FormatException('同步批次过大');
    await db.transaction(() async {
      await guard?.call();
      var cursor = await received(origin);
      for (final event in events) {
        event.validate();
        if (event.origin != origin) throw const FormatException('设备身份不一致');
        final seq = sequence(event.seq);
        if (seq <= cursor) continue;
        if (seq != cursor + 1) throw const FormatException('同步序号不连续，请重新对账');
        await _writeRecord(
          mergeRecord(await record(event.entityId, event.group), event),
        );
        cursor = seq;
      }
      await _setReceived(origin, cursor);
    });
    changes.add(null);
  }

  Future<void> applySnapshot(
    String origin,
    int watermark,
    List<SyncRecord> snapshot, {
    Future<void> Function()? guard,
  }) async {
    await db.transaction(() async {
      await guard?.call();
      for (final state in snapshot) {
        var current = await record(state.entityId, state.group);
        for (final event in state.versions) {
          current = mergeRecord(current, event);
        }
        await _writeRecord(current!);
      }
      await _setReceived(origin, watermark);
      await setMeta('snapshot:$origin', '1');
    });
    changes.add(null);
  }

  Future<(int, List<SyncRecord>)> exportSnapshot() => db.transaction(
    () async => (sequence(await meta('seq') ?? '0'), await records()),
  );

  Future<void> acknowledge(int seq) => db.customStatement(
    'DELETE FROM sync_changes WHERE origin=? AND seq<=?',
    [deviceId, seq],
  );

  Future<List<ShelfBook>> books() async {
    final grouped = <String, Map<String, SyncRecord>>{};
    for (final state in await records()) {
      if (state.entityId.startsWith('book:')) {
        (grouped[state.entityId] ??= {})[state.group] = state;
      }
    }
    final result = <ShelfBook>[];
    for (final entry in grouped.entries) {
      final groups = entry.value;
      final fav = groups['favorite']?.effective.payload['active'] == true;
      final recent = groups['recent']?.effective.payload['active'] == true;
      if (!fav && !recent) continue;
      final metadata =
          (groups['position'] ?? groups['recent'] ?? groups['favorite'])!
              .effective
              .payload;
      result.add(
        ShelfBook(
          entry.key,
          metadata,
          fav,
          recent,
          groups['position'],
          recentTime: recent
              ? groups['recent']?.effective.payload['updatedUtc'] as String?
              : null,
        ),
      );
    }
    result.sort((a, b) {
      final time = DateTime.parse(b.readTime)
          .compareTo(DateTime.parse(a.readTime));
      return time != 0 ? time : a.id.compareTo(b.id);
    });
    return result;
  }

  Stream<List<ShelfBook>> watchBooks() {
    late StreamController<List<ShelfBook>> controller;
    StreamSubscription<void>? subscription;
    Future<void> pending = Future.value();
    void refresh() {
      pending = pending.then((_) async {
        try {
          final value = await books();
          if (!controller.isClosed) controller.add(value);
        } catch (error, stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        }
      });
    }

    controller = StreamController(
      onListen: () {
        subscription = changes.stream.listen((_) => refresh());
        refresh();
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  Future<void> setFavorite(ShelfBook book, bool active) =>
      localChange(book.id, 'favorite', {
        ...book.metadata,
        'chapterUrl': '',
        'chapterTitle': '',
        'progress': 0,
        'active': active,
      });
  Future<void> removeRecent(ShelfBook book) => localChange(book.id, 'recent', {
    ...book.metadata,
    'chapterUrl': '',
    'chapterTitle': '',
    'progress': 0,
    'active': false,
  });
  Future<void> resolvePosition(SyncRecord record, SyncChange choice) =>
      localChange(record.entityId, 'position', choice.payload, resolve: true);

  Future<void> log(bool success, String message) async {
    await db.transaction(() async {
      await db.customStatement(
        'INSERT INTO sync_logs(time_utc,success,message) VALUES(?,?,?)',
        [
          DateTime.now().toUtc().toIso8601String(),
          success ? 1 : 0,
          message.substring(0, min(message.length, 240)),
        ],
      );
      await db.customStatement(
        'DELETE FROM sync_logs WHERE id NOT IN (SELECT id FROM sync_logs ORDER BY id DESC LIMIT 200)',
      );
      if (success) {
        await setMeta('lastSuccess', DateTime.now().toUtc().toIso8601String());
      }
    });
  }

  Future<List<Json>> logs() async =>
      (await db
              .customSelect(
                'SELECT * FROM sync_logs ORDER BY id DESC LIMIT 200',
              )
              .get())
          .map((r) => r.data)
          .toList();
}
