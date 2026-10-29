import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/dependencies.dart';
import 'sync_repository.dart';

String localDate(DateTime time) =>
    '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
String _normalize(String value) =>
    value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

class ReadingStats {
  ReadingStats({
    this.milliseconds = 0,
    Map<String, int>? days,
    Set<String>? books,
  }) : days = days ?? {},
       books = books ?? {};
  final int milliseconds;
  final Map<String, int> days;
  final Set<String> books;
  int get bookCount => books.length;
  int streak(DateTime now) {
    var day = DateTime(now.year, now.month, now.day);
    // A day qualifies only after more than two minutes, not at exactly 120 s.
    if ((days[localDate(day)] ?? 0) <= 120000) {
      day = DateTime(day.year, day.month, day.day - 1);
    }
    var count = 0;
    while ((days[localDate(day)] ?? 0) > 120000) {
      count++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return count;
  }

  String get durationLabel => milliseconds < 3600000
      ? '${milliseconds ~/ 60000} 分钟'
      : '${(milliseconds / 3600000).toStringAsFixed(1)} 小时';
  Map<String, dynamic> toJson() => {
    'milliseconds': milliseconds,
    'days': days,
    'books': books.toList(),
  };
  factory ReadingStats.fromJson(Map<String, dynamic> data) => ReadingStats(
    milliseconds: (data['milliseconds'] as num).toInt(),
    days: (data['days'] as Map).map(
      (k, v) => MapEntry(k as String, (v as num).toInt()),
    ),
    books: Set<String>.from(data['books'] as List),
  );
}

/// Local-only settings/statistics: never add these to device sync records.
class LocalLibrary {
  LocalLibrary(this.sync);
  final SyncRepository sync;
  Map<String, int> pins = {};
  ReadingStats stats = ReadingStats();
  final pinChanges = StreamController<Map<String, int>>.broadcast();
  final statChanges = StreamController<ReadingStats>.broadcast();
  Future<void> _tail = Future.value();
  bool _closed = false;

  Future<void> initialize() async {
    final savedPins = await sync.meta('local:shelf-pins');
    if (savedPins != null) {
      pins = (jsonDecode(savedPins) as Map).map(
        (k, v) => MapEntry(k as String, (v as num).toInt()),
      );
    }
    final savedStats = await sync.meta('local:reading-stats');
    if (savedStats != null) {
      stats = ReadingStats.fromJson(
        Map<String, dynamic>.from(jsonDecode(savedStats) as Map),
      );
    } else {
      final readBooks = <String>{};
      for (final book in await sync.books()) {
        if (book.recent || book.position != null) {
          _addBook(readBooks, book.metadata);
        }
      }
      stats = ReadingStats(books: readBooks);
      await sync.setMeta('local:reading-stats', jsonEncode(stats.toJson()));
    }
  }

  static void _addBook(Set<String> books, Map<String, dynamic> metadata) {
    final title = _normalize(metadata['title'] as String? ?? '');
    if (title.isEmpty) return;
    final author = _normalize(metadata['author'] as String? ?? '');
    final prefix = '$title\u001f';
    // Old reading records may have no author. Upgrade the unknown-author key
    // when a source supplies it, without counting the same book twice.
    if (author.isEmpty && books.any((key) => key.startsWith(prefix))) return;
    if (author.isNotEmpty) books.remove(prefix);
    books.add('$prefix$author');
  }

  Future<void> _queue(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> setPinned(String id, bool active) => _queue(() async {
    final updated = Map<String, int>.of(pins);
    if (active) {
      var order = 0;
      for (final value in updated.values) {
        if (value > order) order = value;
      }
      updated[id] = order + 1;
    } else {
      updated.remove(id);
    }
    await sync.setMeta('local:shelf-pins', jsonEncode(updated));
    pins = updated;
    if (!_closed) pinChanges.add(Map.unmodifiable(pins));
  });

  Future<void> recordReading(
    Map<String, dynamic> metadata,
    DateTime start,
    int durationMs,
  ) => _queue(() async {
    if (durationMs < 0) throw ArgumentError.value(durationMs, 'durationMs');
    final books = Set<String>.of(stats.books);
    _addBook(books, metadata);
    final days = Map<String, int>.of(stats.days);
    var cursor = start, remaining = durationMs;
    while (remaining > 0) {
      final midnight = DateTime(cursor.year, cursor.month, cursor.day + 1);
      final untilMidnight = midnight.difference(cursor).inMilliseconds;
      final part = remaining < untilMidnight ? remaining : untilMidnight;
      days.update(localDate(cursor), (n) => n + part, ifAbsent: () => part);
      remaining -= part;
      cursor = midnight;
    }
    final updated = ReadingStats(
      milliseconds: stats.milliseconds + durationMs,
      days: days,
      books: books,
    );
    await sync.setMeta('local:reading-stats', jsonEncode(updated.toJson()));
    stats = updated;
    if (!_closed) statChanges.add(stats);
  });

  Future<void> close() async {
    _closed = true;
    await _tail;
    await pinChanges.close();
    await statChanges.close();
  }
}

/// Monotonic elapsed time avoids inflating totals after a system clock change.
class ReadingSession {
  ReadingSession(
    this.library,
    this.metadata, {
    DateTime Function()? now,
    int Function()? elapsed,
  }) : now = now ?? DateTime.now,
       _elapsedOverride = elapsed;
  final LocalLibrary library;
  final Map<String, dynamic> metadata;
  final DateTime Function() now;
  final int Function()? _elapsedOverride;
  final _watch = Stopwatch()..start();
  bool _active = false;
  int _lastElapsed = 0;
  DateTime? _lastWall;
  Future<void> _pending = Future.value();
  int get _elapsed => _elapsedOverride?.call() ?? _watch.elapsedMilliseconds;

  void resume() {
    if (_active) return;
    _active = true;
    _lastElapsed = _elapsed;
    _lastWall = now();
    _pending = library.recordReading(metadata, _lastWall!, 0);
    _pending.ignore();
  }

  Future<void> checkpoint() {
    if (!_active) return _pending;
    final elapsed = _elapsed;
    final delta = elapsed - _lastElapsed;
    final wall = _lastWall!;
    _lastElapsed = elapsed;
    _lastWall = now();
    if (delta > 0) {
      _pending = library.recordReading(metadata, wall, delta);
      _pending.ignore();
    }
    return _pending;
  }

  Future<void> pause() {
    final result = checkpoint();
    _active = false;
    return result;
  }
}

final localLibraryProvider = FutureProvider<LocalLibrary>((ref) async {
  final library = LocalLibrary(await ref.watch(syncRepositoryProvider.future));
  await library.initialize();
  ref.onDispose(library.close);
  return library;
});
final shelfPinsProvider = StreamProvider<Map<String, int>>((ref) async* {
  final library = await ref.watch(localLibraryProvider.future);
  yield Map.unmodifiable(library.pins);
  yield* library.pinChanges.stream;
});
final readingStatsProvider = StreamProvider<ReadingStats>((ref) async* {
  final library = await ref.watch(localLibraryProvider.future);
  yield library.stats;
  yield* library.statChanges.stream;
});

final localDayProvider = StreamProvider<String>((ref) {
  final changes = StreamController<String>();
  var day = localDate(DateTime.now());
  changes.add(day);
  final timer = Timer.periodic(const Duration(minutes: 1), (_) {
    final next = localDate(DateTime.now());
    if (next != day) {
      day = next;
      changes.add(day);
    }
  });
  ref.onDispose(() {
    timer.cancel();
    changes.close();
  });
  return changes.stream;
});
