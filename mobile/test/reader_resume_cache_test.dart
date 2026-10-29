import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/sync_engine/sync_model.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_layout.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_preferences.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_resume_cache.dart';

const metrics = MediaQueryData(size: Size(390, 844), devicePixelRatio: 3);
const position = {
  'chapterUrl': 'https://fixture.invalid/chapter/2',
  'bookProgressChapterUrl': 'https://fixture.invalid/chapter/2',
  'chapterIndex': 2,
  'chapterCount': 10,
  'progress': .4,
};

ReaderResume entry({
  ReaderPreferences preferences = const ReaderPreferences(),
}) {
  final chapter = ReaderChapter(
    'Chapter',
    'https://fixture.invalid/chapter/2',
    ['Test paragraph.'],
  );
  return ReaderResume(
    catalog: const ReaderCatalog([]),
    source: SourceRule({'id': 'test'}),
    layout: ReaderLayout(
      chapter,
      342,
      800,
      const TextStyle(fontSize: 22),
      TextScaler.noScaling,
    ),
    preferences: preferences,
    family: null,
    chapterIndex: 2,
    anchor: const TextAnchor(0, 4),
    scrollWithinChapter: 123.4,
    metrics: metrics,
    bottomClearance: 12,
    position: position,
  );
}

ShelfBook book(String id, [Map<String, dynamic>? p]) => ShelfBook(
  id,
  {'title': 'Test'},
  true,
  true,
  p == null
      ? null
      : SyncRecord(id, 'position', [
          SyncChange(
            entityId: id,
            group: 'position',
            origin: 'a' * 32,
            seq: '1',
            clock: {'a' * 32: '1'},
            payload: p,
          ),
        ]),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ownership transfer is single use; only two current chapters are retained',
    () {
      final cache = ReaderResumeCache();
      addTearDown(cache.dispose);
      cache.remember('a', entry());
      cache.remember('b', entry());
      cache.remember('c', entry());
      expect(cache.take(book('a'), metrics), isNull);
      final restored = cache.take(book('b'), metrics)!;
      expect(restored.scrollWithinChapter, 123.4);
      expect(cache.take(book('b'), metrics), isNull);
      restored.layout.dispose();
    },
  );
  test('changed viewport, safe margins or typography reject old layout', () {
    final cache = ReaderResumeCache();
    addTearDown(cache.dispose);
    for (final changed in [
      metrics.copyWith(size: const Size(844, 390)),
      metrics.copyWith(viewPadding: const EdgeInsets.only(bottom: 24)),
      metrics.copyWith(textScaler: const TextScaler.linear(1.2)),
      metrics.copyWith(devicePixelRatio: 2),
    ]) {
      cache.remember('a', entry());
      expect(cache.take(book('a'), changed), isNull);
    }
  });
  test('newer and incomparable changed remote positions reject stale paper; older positions do not', () {
    final cache = ReaderResumeCache();
    addTearDown(cache.dispose);
    cache.remember('a', entry());
    expect(
      cache.take(book('a', {...position, 'progress': .6}), metrics),
      isNull,
    );
    cache.remember('a', entry());
    expect(
      cache.take(
        book('a', {
          'chapterUrl': 'https://fixture.invalid/other',
          'progress': .1,
        }),
        metrics,
      ),
      isNull,
    );
    final prepared = entry();
    cache.remember('a', prepared);
    final restored = cache.take(
      book('a', {...position, 'progress': .2}),
      metrics,
    );
    expect(restored, same(prepared));
    restored!.layout.dispose();
  });
  test('preferences invalidate other entries; disposed cache never takes ownership', () {
    final cache = ReaderResumeCache();
    addTearDown(cache.dispose);
    cache.remember('a', entry());
    cache.remember(
      'b',
      entry(preferences: const ReaderPreferences(fontSize: 25)),
    );
    expect(cache.take(book('a'), metrics), isNull);
    cache.dispose();
    final abandoned = entry();
    expect(cache.remember('c', abandoned), isFalse);
    abandoned.layout.dispose();
  });
}
