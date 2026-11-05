import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/data/book_source.dart';
import 'package:sorryread_mobile/data/reading_history.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';

import 'support/test_runtime.dart';

const metadata = {'title': '山间来信', 'author': '作者甲'};
ReadingPosition position(int chapter, {double progress = .5}) =>
    ReadingPosition(
      chapterUrl: 'https://example.invalid/chapter/$chapter',
      chapterTitle: '章节 $chapter',
      chapterIndex: chapter,
      chapterCount: 100,
      progress: progress,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalLibrary> library() async {
    final sync = await testRepository();
    final local = LocalLibrary(sync);
    await local.initialize();
    addTearDown(() async {
      await local.close();
      await sync.close();
    });
    return local;
  }

  test('special classification matches source IDs and legacy hosts, and persists across reopening', () async {
    final local = await library();
    final day = DateTime(2026, 11, 2, 12);
    final sources = [
      {'sourceId': '18mh'},
      {'sourceId': ' YESHE '},
      {'sourceId': 'legacy', 'detailUrl': 'https://m.18mh.net/book/1'},
      {'detailUrl': 'https://yeshezy1.com/book/1'},
      {
        'sourceId': 'ordinary',
        'detailUrl': 'https://18mh.net.example.invalid/book/1',
      },
    ];
    for (var i = 0; i < sources.length; i++) {
      await local.recordReading(
        {...metadata, 'title': '记录 $i', ...sources[i]},
        day,
        60000,
      );
      expect(isSpecialLibrarySource(sources[i]), i < 4);
    }
    final reopened = LocalLibrary(local.sync);
    await reopened.initialize();
    final overview = await reopened.readingOverview(day);
    expect(overview.entries.where((entry) => entry.isSpecial), hasLength(4));
    expect(
      overview.entries.singleWhere((entry) => entry.title == '记录 4').isSpecial,
      isFalse,
    );
    expect(overview.month.milliseconds, 300000);
    await reopened.close();
  });

  test('version 2 history is backfilled from retained special metadata without changing reading data or sync sequence', () async {
    final db = SyncDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute('PRAGMA user_version=2');
          for (final sql in [
            'CREATE TABLE sync_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
            'CREATE TABLE sync_records(entity TEXT NOT NULL,field_group TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(entity,field_group))',
            'CREATE TABLE sync_changes(origin TEXT NOT NULL,seq INTEGER NOT NULL,json TEXT NOT NULL,PRIMARY KEY(origin,seq))',
            'CREATE TABLE sync_received(origin TEXT PRIMARY KEY,seq INTEGER NOT NULL)',
            'CREATE TABLE sync_logs(id INTEGER PRIMARY KEY AUTOINCREMENT,time_utc TEXT NOT NULL,success INTEGER NOT NULL,message TEXT NOT NULL)',
            'CREATE TABLE local_reading_history(day TEXT NOT NULL,book_key TEXT NOT NULL,title TEXT NOT NULL,author TEXT NOT NULL,last_read TEXT NOT NULL,duration_ms INTEGER NOT NULL,position_json TEXT NOT NULL,PRIMARY KEY(day,book_key))',
            'CREATE TABLE local_reading_chapters(month TEXT NOT NULL,book_key TEXT NOT NULL,chapter_key TEXT NOT NULL,PRIMARY KEY(month,book_key,chapter_key))',
          ]) {
            raw.execute(sql);
          }
          raw.execute(
            'INSERT INTO local_reading_history VALUES(?,?,?,?,?,?,?)',
            [
              '2026-11-02',
              '旧特殊记录\u001f',
              '旧特殊记录',
              '',
              '2026-11-02T04:00:00Z',
              600000,
              'null',
            ],
          );
          raw.execute('INSERT INTO sync_meta VALUES(?,?)', [
            'local:reading-stats',
            jsonEncode(
              ReadingStats(
                milliseconds: 600000,
                days: {'2026-11-02': 600000},
                books: {'旧特殊记录\u001f'},
              ).toJson(),
            ),
          ]);
        },
      ),
    );
    final sync = SyncRepository(db);
    await sync.initialize();
    await sync.localChange('book:legacy|https://m.18mh.net/book/1', 'recent', {
      'kind': 'book',
      'title': '旧特殊记录',
      'author': '作者甲',
      'sourceId': 'legacy',
      'sourceName': '旧来源',
      'detailUrl': 'https://m.18mh.net/book/1',
      'chapterUrl': '',
      'chapterTitle': '',
      'progress': 0,
      'active': false,
    });
    final local = LocalLibrary(sync);
    await local.initialize();
    addTearDown(() async {
      await local.close();
      await sync.close();
    });
    final sequence = await sync.meta('seq');
    final overview = await local.readingOverview(DateTime(2026, 11, 2));
    expect(overview.entries.single.isSpecial, isTrue);
    expect(overview.entries.single.title, '旧特殊记录');
    expect(overview.entries.single.milliseconds, 600000);
    expect(overview.month.milliseconds, 600000);
    expect(await sync.meta('seq'), sequence);
    await db.customStatement('DELETE FROM sync_records');
    final reopened = LocalLibrary(sync);
    await reopened.initialize();
    expect(
      (await reopened.readingOverview(DateTime(2026, 11, 2)))
          .entries
          .single
          .isSpecial,
      isTrue,
    );
    await reopened.close();
  });

  test('same book and local day merge; actual latest chapter wins over synced maximum', () async {
    final local = await library();
    final day = DateTime(2026, 11, 2, 10);
    final sequence = await local.sync.meta('seq');
    await local.recordReading(metadata, day, 60000, position: position(20));
    await local.recordReading(
      {...metadata, 'sourceId': 'another-source'},
      day.add(const Duration(hours: 1)),
      120001,
      position: position(3),
    );
    await local.recordReading(
      metadata,
      day.add(const Duration(hours: 2)),
      60000,
      position: position(3, progress: .8),
    );
    await local.recordReading(metadata, day, 0, position: position(99));
    final overview = await local.readingOverview(day);
    expect(overview.entries, hasLength(1));
    expect(overview.entries.single.milliseconds, 240001);
    expect(overview.entries.single.position!.chapterIndex, 3);
    expect(
      overview.entries.single.position!.bookProgress,
      closeTo(.038, .0001),
    );
    expect(overview.month.chapters, 2);
    expect(overview.month.streak, 1);
    expect(await local.sync.meta('seq'), sequence);
    expect(await local.sync.records(), isEmpty);
    final reopened = LocalLibrary(local.sync);
    await reopened.initialize();
    expect(
      (await reopened.readingOverview(day)).entries.single.milliseconds,
      240001,
    );
    await reopened.close();
  });

  test('30 local calendar days include today; month totals include the 31st day outside the timeline', () async {
    final local = await library();
    for (final day in [1, 2, 30, 31]) {
      await local.recordReading(
        metadata,
        DateTime(2026, 10, day, 12),
        180000,
        position: position(day),
      );
    }
    await local.recordReading(
      metadata,
      DateTime(2026, 9, 30, 12),
      600000,
      position: position(90),
    );
    final overview = await local.readingOverview(DateTime(2026, 10, 31, 23));
    expect(overview.entries.map((e) => e.day), [
      '2026-10-31',
      '2026-10-30',
      '2026-10-02',
    ]);
    expect(overview.month.milliseconds, 720000);
    expect(overview.month.chapters, 4);
    expect(overview.month.streak, 2);
    final next = await local.readingOverview(DateTime(2026, 11, 1));
    expect(next.month.milliseconds, 0);
    expect(next.month.chapters, 0);
    expect(next.month.streak, 0);
  });

  test('midnight splits time and distinct chapter membership across months; exactly 2 minutes does not qualify', () async {
    final local = await library();
    await local.recordReading(
      metadata,
      DateTime(2026, 10, 31, 23, 59),
      180000,
      position: position(5),
    );
    final overview = await local.readingOverview(DateTime(2026, 11, 1, 12));
    expect(overview.entries.map((e) => e.milliseconds), [120000, 60000]);
    expect(overview.entries.first.lastRead.day, 1);
    expect(overview.entries.last.lastRead.day, 31);
    expect(overview.month.milliseconds, 120000);
    expect(overview.month.chapters, 1);
    expect(overview.month.streak, 0);
    await local.recordReading(
      metadata,
      DateTime(2026, 11, 1, 12),
      1,
      position: position(5),
    );
    expect(
      (await local.readingOverview(DateTime(2026, 11, 2))).month.streak,
      1,
    );
  });

  test('visible chapter changes checkpoint the previous chapter; loading and background create no time', () async {
    final local = await library();
    var wall = DateTime(2026, 11, 2, 10), elapsed = 0;
    void advance(int ms) {
      elapsed += ms;
      wall = wall.add(Duration(milliseconds: ms));
    }

    final session = ReadingSession(
      local,
      metadata,
      now: () => wall,
      elapsed: () => elapsed,
    );
    session.updatePosition(position(1));
    advance(30000);
    session.resume();
    advance(60000);
    session.updatePosition(position(1, progress: .9));
    advance(60000);
    session.updatePosition(position(2));
    advance(1000);
    await session.pause();
    advance(300000);
    session.resume();
    advance(60000);
    await session.pause();
    final overview = await local.readingOverview(wall);
    expect(overview.entries.single.milliseconds, 181000);
    expect(overview.entries.single.position!.chapterIndex, 2);
    expect(overview.month.chapters, 2);
    expect(overview.month.streak, 1);
  });

  test('version 1 migration preserves old daily duration without inventing timeline or chapters', () async {
    final saved = jsonEncode(
      ReadingStats(
        milliseconds: 420000,
        days: {'2026-11-02': 420000},
        books: {'山间来信\u001f作者甲'},
      ).toJson(),
    );
    final db = SyncDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute('PRAGMA user_version=1');
          for (final sql in [
            'CREATE TABLE sync_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
            'CREATE TABLE sync_records(entity TEXT NOT NULL,field_group TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(entity,field_group))',
            'CREATE TABLE sync_changes(origin TEXT NOT NULL,seq INTEGER NOT NULL,json TEXT NOT NULL,PRIMARY KEY(origin,seq))',
            'CREATE TABLE sync_received(origin TEXT PRIMARY KEY,seq INTEGER NOT NULL)',
            'CREATE TABLE sync_logs(id INTEGER PRIMARY KEY AUTOINCREMENT,time_utc TEXT NOT NULL,success INTEGER NOT NULL,message TEXT NOT NULL)',
          ]) {
            raw.execute(sql);
          }
          raw.execute('INSERT INTO sync_meta VALUES(?,?)', [
            'local:reading-stats',
            saved,
          ]);
        },
      ),
    );
    final sync = SyncRepository(db);
    await sync.initialize();
    final local = LocalLibrary(sync);
    await local.initialize();
    addTearDown(() async {
      await local.close();
      await sync.close();
    });
    final overview = await local.readingOverview(DateTime(2026, 11, 2));
    expect(overview.month.milliseconds, 420000);
    expect(overview.month.chapters, 0);
    expect(overview.entries, isEmpty);
    expect(local.stats.bookCount, 1);
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      ),
      4,
    );
    await local.recordReading(
      metadata,
      DateTime(2026, 11, 2, 12),
      60000,
      position: position(1),
    );
    expect(
      (await local.readingOverview(DateTime(2026, 11, 2))).month.milliseconds,
      480000,
    );
  });
}
