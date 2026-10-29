import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/features/profile/data/daily_saying.dart';

import 'support/test_runtime.dart';

class QuoteAdapter implements HttpClientAdapter {
  int calls = 0;
  bool fail = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      fail ? '{}' : jsonEncode({'text': '山间有风，书中有远方。'}),
      fail ? 503 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('pin order and statistics are local, persistent and independent of sync history', () async {
    final sync = await testRepository(books: 2);
    final library = LocalLibrary(sync);
    await library.initialize();
    addTearDown(() async {
      await library.close();
      await sync.close();
    });
    final sequence = await sync.meta('seq');
    final records = (await sync.records()).length;
    expect(library.stats.bookCount, 2);
    expect(library.stats.milliseconds, 0);
    await Future.wait([
      library.setPinned('a', true),
      library.setPinned('b', true),
    ]);
    expect(library.pins['b'], greaterThan(library.pins['a']!));
    await library.setPinned('a', true);
    expect(library.pins['a'], greaterThan(library.pins['b']!));
    await library.setPinned('a', false);
    expect(library.pins.containsKey('a'), isFalse);
    await library.recordReading(
      {'title': '测试书籍 0', 'author': '作者甲'},
      DateTime(2026, 10, 27),
      121000,
    );
    expect(library.stats.bookCount, 2); // Upgrade old unknown-author identity.
    await library.recordReading(
      {'title': '测试书籍 0', 'author': '作者甲', 'sourceId': 'other'},
      DateTime(2026, 10, 27),
      0,
    );
    expect(library.stats.bookCount, 2);
    final reopened = LocalLibrary(sync);
    await reopened.initialize();
    expect(reopened.pins.keys, ['b']);
    expect(reopened.stats.milliseconds, 121000);
    expect(await sync.meta('seq'), sequence);
    expect(await sync.records(), hasLength(records));
    await reopened.close();
  });
  test('session excludes background and loading, and requires strictly more than two minutes', () async {
    final sync = await testRepository();
    final library = LocalLibrary(sync);
    await library.initialize();
    addTearDown(() async {
      await library.close();
      await sync.close();
    });
    var time = DateTime(2026, 10, 27, 10), elapsed = 0;
    void advance(int ms) {
      elapsed += ms;
      time = time.add(Duration(milliseconds: ms));
    }

    final session = ReadingSession(
      library,
      {'title': '山间来信'},
      now: () => time,
      elapsed: () => elapsed,
    );
    advance(30000); // Loading: the session is not active yet.
    session.resume();
    advance(60000);
    await session.pause();
    advance(300000); // Background time must never count.
    session.resume();
    advance(60000);
    await session.checkpoint();
    expect(library.stats.milliseconds, 120000);
    expect(library.stats.streak(time), 0);
    advance(1);
    await session.pause();
    expect(library.stats.milliseconds, 120001);
    expect(library.stats.streak(time), 1);
    await session.pause();
    expect(library.stats.milliseconds, 120001);
    expect(library.stats.bookCount, 1);
  });
  test('midnight divides duration by local day; streak survives until a missed day', () async {
    final sync = await testRepository();
    final library = LocalLibrary(sync);
    await library.initialize();
    addTearDown(() async {
      await library.close();
      await sync.close();
    });
    await library.recordReading(
      {'title': '湖畔故事'},
      DateTime(2026, 10, 26, 23, 59),
      181001,
    );
    expect(library.stats.days['2026-10-26'], 60000);
    expect(library.stats.days['2026-10-27'], 121001);
    expect(library.stats.streak(DateTime(2026, 10, 28)), 1);
    expect(library.stats.streak(DateTime(2026, 10, 29)), 0);
    await library.recordReading(
      {'title': '湖畔故事'},
      DateTime(2026, 10, 26),
      61001,
    );
    expect(library.stats.streak(DateTime(2026, 10, 27)), 2);
  });
  test(
    'daily quote is cached once per day and preserves last text offline',
    () async {
      final sync = await testRepository();
      addTearDown(sync.close);
      final adapter = QuoteAdapter();
      final repo = DailySayingRepository(sync);
      repo.http.httpClientAdapter = adapter;
      addTearDown(repo.dispose);
      final values = await Future.wait([
        repo.load('2026-10-27'),
        repo.load('2026-10-27'),
      ]);
      expect(values.first.text, '山间有风，书中有远方。');
      expect(adapter.calls, 1);
      await repo.load('2026-10-27');
      expect(adapter.calls, 1);
      adapter.fail = true;
      final stale = await repo.load('2026-10-28');
      expect(stale.text, values.first.text);
      expect(stale.date, '2026-10-27');
      expect(stale.cached, isTrue);
      expect(adapter.calls, 2);
    },
  );
}
