import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../sync_engine/sync_model.dart';
import 'book_source.dart';
import 'reading_history.dart';

class SyncDatabase extends GeneratedDatabase {
  SyncDatabase(super.executor);
  @override
  int get schemaVersion => 4;
  static const _desktopReadingTable =
      'CREATE TABLE desktop_reading(day TEXT NOT NULL,server TEXT NOT NULL,book_id TEXT NOT NULL,chapter_url TEXT NOT NULL,json TEXT NOT NULL,milliseconds INTEGER NOT NULL,PRIMARY KEY(day,server,book_id,chapter_url))';
  static const _localReadingTables = [
    'CREATE TABLE local_reading_history(day TEXT NOT NULL,book_key TEXT NOT NULL,title TEXT NOT NULL,author TEXT NOT NULL,last_read TEXT NOT NULL,duration_ms INTEGER NOT NULL,position_json TEXT NOT NULL,is_special INTEGER NOT NULL DEFAULT 0,book_id TEXT NOT NULL DEFAULT \'\',PRIMARY KEY(day,book_key))',
    'CREATE TABLE local_reading_chapters(month TEXT NOT NULL,book_key TEXT NOT NULL,chapter_key TEXT NOT NULL,PRIMARY KEY(month,book_key,chapter_key))',
  ];
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
        ..._localReadingTables,
        _desktopReadingTable,
      ]) {
        await customStatement(sql);
      }
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        for (final sql in _localReadingTables) {
          await customStatement(sql);
        }
      }
      if (from >= 2 && from < 3) {
        await customStatement(
          'ALTER TABLE local_reading_history ADD COLUMN is_special INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (from < 4) {
        await customStatement(_desktopReadingTable);
        if (from >= 2) {
          await customStatement(
            "ALTER TABLE local_reading_history ADD COLUMN book_id TEXT NOT NULL DEFAULT ''",
          );
        }
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA busy_timeout=5000');
      await customStatement('PRAGMA journal_mode=WAL');
      await customStatement(
        'CREATE INDEX IF NOT EXISTS sync_logs_time ON sync_logs(julianday(time_utc))',
      );
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

  bool get conflicted => position?.hasPositionConflict ?? false;
  double get progress =>
      (position?.effective.payload['progress'] as num?)?.toDouble() ?? 0;

  // Chapter-local progress remains the restore/sync contract with desktop.
  // Extra fields are usable only for the chapter they describe: an older peer
  // may preserve them while moving to a different chapter.
  double? get bookProgress {
    if (position == null) return 0;
    final p = position!.effective.payload;
    final index = p['chapterIndex'], count = p['chapterCount'];
    if (index is! int ||
        count is! int ||
        count <= 0 ||
        index < 0 ||
        index >= count ||
        p['bookProgressChapterUrl'] != p['chapterUrl']) {
      return null;
    }
    return ((index + progress.clamp(0, 1)) / count).clamp(0, 1);
  }

  bool get is18mh => is18mhLibrarySource(metadata);
  bool get isSpecialSource => isSpecialLibrarySource(metadata);
}

class SyncRepository {
  SyncRepository(this.db);
  final SyncDatabase db;
  late final String deviceId;
  final changes = StreamController<void>.broadcast();
  // Remote projections refresh the shelf, but must not schedule another upload.
  final localChanges = StreamController<void>.broadcast();
  final remotePositionAdvances = StreamController<SyncChange>.broadcast();
  final logChanges = StreamController<void>.broadcast();
  final desktopReadingChanges = StreamController<void>.broadcast();
  Timer? _logExpiry;
  bool _readerScrolling = false, _pendingProjection = false;
  final _decodedRecords = <String, (String, SyncRecord)>{};

  void setReaderScrolling(bool active) {
    _readerScrolling = active;
    if (!active && _pendingProjection) {
      _pendingProjection = false;
      notifyChanges();
    }
  }

  // Persist/merge immediately, but don't rebuild hidden shelves or recompute
  // conflict projections in the middle of a drag or its ballistic continuation.
  void notifyChanges() {
    if (_readerScrolling) {
      _pendingProjection = true;
    } else if (!changes.isClosed) {
      changes.add(null);
    }
  }

  SyncRecord _decodeRecord(String json) {
    final value = SyncRecord.fromJson(jsonDecode(json) as Json);
    return value;
  }

  SyncRecord _cachedRecord(String entity, String group, String json) {
    final key = '$entity/$group';
    final cached = _decodedRecords.remove(key);
    final value = cached?.$1 == json ? cached!.$2 : _decodeRecord(json);
    _decodedRecords[key] = (json, value);
    if (_decodedRecords.length > 512) {
      _decodedRecords.remove(_decodedRecords.keys.first);
    }
    return value;
  }

  Future<void> initialize() async {
    await db.transaction(() async {
      deviceId = await meta('deviceId') ?? randomId();
      await setMeta('deviceId', deviceId);
      if (await meta('seq') == null) await setMeta('seq', '0');
    });
    await pruneLogs();
    _logExpiry = Timer.periodic(const Duration(minutes: 1), (_) async {
      await pruneLogs();
      if (!logChanges.isClosed) logChanges.add(null);
    });
  }

  Future<void> close() async {
    _logExpiry?.cancel();
    _decodedRecords.clear();
    await remotePositionAdvances.close();
    await localChanges.close();
    await logChanges.close();
    await desktopReadingChanges.close();
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

  Future<int> desktopReadingCursor(String server) async =>
      int.tryParse(await meta('desktop-reading:$server') ?? '') ?? 0;

  Future<void> applyDesktopReading(
    String server,
    List<DesktopReadingEntry> entries, {
    Future<void> Function()? guard,
  }) async {
    if (entries.isEmpty) return;
    final changed = await db.transaction(() async {
      await guard?.call();
      final initial = await desktopReadingCursor(server);
      var cursor = initial;
      var previous = 0;
      for (final entry in entries) {
        if (entry.revision <= previous) {
          throw const FormatException('Desktop reading revisions out of order');
        }
        previous = entry.revision;
        if (entry.revision <= cursor) continue;
        await db.customStatement(
          'INSERT INTO desktop_reading VALUES(?,?,?,?,?,?) '
          'ON CONFLICT(day,server,book_id,chapter_url) DO UPDATE SET '
          'json=excluded.json,milliseconds=excluded.milliseconds',
          [
            entry.day,
            server,
            entry.bookId,
            entry.position.chapterUrl,
            jsonEncode(entry.json),
            entry.milliseconds,
          ],
        );
        cursor = entry.revision;
      }
      if (cursor != initial) {
        await setMeta('desktop-reading:$server', '$cursor');
      }
      await guard?.call();
      return cursor != initial;
    });
    if (changed && !desktopReadingChanges.isClosed) {
      desktopReadingChanges.add(null);
    }
  }

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
        : _cachedRecord(entity, group, row.read<String>('json'));
  }

  Future<List<SyncRecord>> records({String? group}) async =>
      (await db
              .customSelect(
                'SELECT entity,field_group,json FROM sync_records ${group == null ? '' : 'WHERE field_group=?'} ORDER BY entity,field_group',
                variables: group == null ? [] : [Variable(group)],
              )
              .get())
          .map(
            (r) => _cachedRecord(
              r.read<String>('entity'),
              r.read<String>('field_group'),
              r.read<String>('json'),
            ),
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
  }) => _writeLocalChanges([(entity, group, payload)], resolve: resolve);

  Future<void> _writeLocalChanges(
    Iterable<(String, String, Json)> entries, {
    bool resolve = false,
    bool skipUnchanged = false,
  }) async {
    var changed = false;
    await db.transaction(() async {
      for (final (entity, group, payload) in entries) {
        final old = await record(entity, group);
        if (skipUnchanged &&
            (old?.effective.payload['active'] == true) == payload['active']) {
          continue;
        }
        if (group == 'position' &&
            payload['kind'] == 'book' &&
            old != null &&
            old.positions.any(
              (v) => (compareBookPositions(v.payload, payload) ?? -1) > 0,
            )) {
          continue;
        }
        Iterable<SyncChange> observed = old?.versions ?? [];
        if (!resolve &&
            group == 'position' &&
            payload['kind'] != 'book' &&
            observed.length > 1) {
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
        changed = true;
      }
    });
    if (changed) {
      notifyChanges();
      localChanges.add(null);
    }
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

  Future<List<SyncChange>> applyRemote(
    String origin,
    List<SyncChange> events, {
    Future<void> Function()? guard,
  }) async {
    if (events.length > 128) throw const FormatException('同步批次过大');
    final updated = <String, SyncChange>{};
    final advanced = <String, SyncChange>{};
    await db.transaction(() async {
      await guard?.call();
      var cursor = await received(origin);
      for (final event in events) {
        event.validate();
        if (event.origin != origin) throw const FormatException('设备身份不一致');
        final seq = sequence(event.seq);
        if (seq <= cursor) continue;
        if (seq != cursor + 1) throw const FormatException('同步序号不连续，请重新对账');
        final old = await record(event.entityId, event.group);
        final next = mergeRecord(old, event);
        if (_advanced(old, next)) advanced[event.entityId] = next.effective;
        await _writeRecord(next);
        if (jsonEncode(old?.toJson()) != jsonEncode(next.toJson())) {
          updated['${event.entityId}/${event.group}'] = next.effective;
        }
        cursor = seq;
      }
      await _setReceived(origin, cursor);
    });
    notifyChanges();
    for (final value in advanced.values) {
      remotePositionAdvances.add(value);
    }
    return updated.values.toList();
  }

  Future<List<SyncChange>> applySnapshot(
    String origin,
    int watermark,
    List<SyncRecord> snapshot, {
    Future<void> Function()? guard,
  }) async {
    final updated = <SyncChange>[];
    final advanced = <SyncChange>[];
    await db.transaction(() async {
      await guard?.call();
      for (final state in snapshot) {
        var current = await record(state.entityId, state.group);
        final old = current;
        final before = jsonEncode(current?.toJson());
        for (final event in [...state.versions, ...?state.positionFrontier]) {
          current = mergeRecord(current, event);
        }
        if (_advanced(old, current!)) advanced.add(current.effective);
        await _writeRecord(current);
        if (before != jsonEncode(current.toJson())) {
          updated.add(current.effective);
        }
      }
      await _setReceived(origin, watermark);
      await setMeta('snapshot:$origin', '1');
    });
    notifyChanges();
    for (final value in advanced) {
      remotePositionAdvances.add(value);
    }
    return updated;
  }

  bool _advanced(SyncRecord? old, SyncRecord next) =>
      next.group == 'position' &&
      next.effective.payload['kind'] == 'book' &&
      !next.hasPositionConflict &&
      (old == null ||
          (compareBookPositions(
                    next.effective.payload,
                    old.effective.payload,
                  ) ??
                  0) >
              0);

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
    var running = false, again = false;
    Future<void> drain() async {
      do {
        again = false;
        try {
          final value = await books();
          if (!controller.isClosed) controller.add(value);
        } catch (error, stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        }
      } while (again && !controller.isClosed);
      running = false;
    }

    void refresh() {
      again = true;
      if (running) return;
      running = true;
      unawaited(drain());
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

  Json _shelfActionPayload(ShelfBook book, bool active) => {
    ...book.metadata,
    'chapterUrl': '',
    'chapterTitle': '',
    'progress': 0,
    'active': active,
  };

  Future<void> setFavorite(ShelfBook book, bool active) =>
      localChange(book.id, 'favorite', _shelfActionPayload(book, active));
  Future<void> removeRecent(ShelfBook book) =>
      localChange(book.id, 'recent', _shelfActionPayload(book, false));

  Future<void> setFavorites(Iterable<ShelfBook> books, bool active) =>
      _writeLocalChanges(
        books.map(
          (book) => (book.id, 'favorite', _shelfActionPayload(book, active)),
        ),
        skipUnchanged: true,
      );
  Future<void> removeRecentBooks(Iterable<ShelfBook> books) =>
      _writeLocalChanges(
        books.map(
          (book) => (book.id, 'recent', _shelfActionPayload(book, false)),
        ),
        skipUnchanged: true,
      );
  Future<void> resolvePosition(SyncRecord record, SyncChange choice) =>
      localChange(record.entityId, 'position', choice.payload, resolve: true);

  Future<void> log(bool success, String message) =>
      logBatch(success, [message]);

  Future<void> logBatch(bool success, Iterable<String> messages) async {
    await db.transaction(() async {
      final time = DateTime.now().toUtc().toIso8601String();
      for (final message in messages) {
        await db.customStatement(
          'INSERT INTO sync_logs(time_utc,success,message) VALUES(?,?,?)',
          [
            time,
            success ? 1 : 0,
            message.substring(0, min(message.length, 2048)),
          ],
        );
      }
      await pruneLogs();
      if (success) {
        await setMeta('lastSuccess', DateTime.now().toUtc().toIso8601String());
      }
    });
    if (!logChanges.isClosed) logChanges.add(null);
  }

  Future<void> pruneLogs() => db.customStatement(
    'DELETE FROM sync_logs WHERE julianday(time_utc) <= julianday(?)',
    [
      DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 1))
          .toIso8601String(),
    ],
  );

  Future<List<Json>> logs() async {
    await pruneLogs();
    return (await db
            .customSelect('SELECT * FROM sync_logs ORDER BY id DESC')
            .get())
        .map((r) => r.data)
        .toList();
  }

  Stream<List<Json>> watchLogs() {
    late StreamController<List<Json>> controller;
    StreamSubscription<void>? subscription;
    Future<void> pending = Future.value();
    void refresh() {
      pending = pending.then((_) async {
        try {
          final value = await logs();
          if (!controller.isClosed) controller.add(value);
        } catch (error, stack) {
          if (!controller.isClosed) controller.addError(error, stack);
        }
      });
    }

    controller = StreamController(
      onListen: () {
        subscription = logChanges.stream.listen((_) => refresh());
        refresh();
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }
}
