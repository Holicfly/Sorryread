import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/dependencies.dart';
import 'book_source.dart';
import 'reading_history.dart';
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
    this.desktopMilliseconds = 0,
    this.desktopDays = const {},
  }) : days = days ?? {},
       books = books ?? {};
  final int milliseconds;
  final Map<String, int> days;
  final Set<String> books;
  final int desktopMilliseconds;
  final Map<String, int> desktopDays;
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

  String get durationLabel => _durationLabel(milliseconds);
  String durationLabelFor(DateTime day) =>
      _durationLabel(days[localDate(day)] ?? 0);
  ({int phone, int desktop}) durationByDevice({DateTime? day}) {
    final key = day == null ? null : localDate(day);
    final total = key == null ? milliseconds : days[key] ?? 0;
    final desktop = key == null ? desktopMilliseconds : desktopDays[key] ?? 0;
    return (phone: total - desktop, desktop: desktop);
  }

  static String _durationLabel(int milliseconds) => milliseconds < 3600000
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
  StreamSubscription<void>? _desktopReadingSubscription;
  StreamSubscription<String>? _importedBookSubscription;
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
    _desktopReadingSubscription = sync.desktopReadingChanges.stream.listen(
      (_) => statChanges.add(stats),
    );
    _importedBookSubscription = sync.importedBookRemovals.stream.listen((id) {
      if (pins.containsKey(id)) {
        pins = Map.of(pins)..remove(id);
        pinChanges.add(Map.unmodifiable(pins));
      }
      statChanges.add(stats);
    });
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

  Future<void> setPinned(String id, bool active) =>
      _updatePins([id], active, moveExisting: true);

  Future<void> setBooksPinned(Iterable<String> ids, bool active) =>
      _updatePins(ids, active, moveExisting: false);

  Future<void> _updatePins(
    Iterable<String> ids,
    bool active, {
    required bool moveExisting,
  }) => _queue(() async {
    final updated = Map<String, int>.of(pins);
    if (active) {
      var order = 0;
      for (final value in updated.values) {
        if (value > order) order = value;
      }
      for (final id in ids) {
        if (moveExisting || !updated.containsKey(id)) updated[id] = ++order;
      }
    } else {
      for (final id in ids) {
        updated.remove(id);
      }
    }
    await sync.setMeta('local:shelf-pins', jsonEncode(updated));
    pins = updated;
    if (!_closed) pinChanges.add(Map.unmodifiable(pins));
  });

  Future<void> recordReading(
    Map<String, dynamic> metadata,
    DateTime start,
    int durationMs, {
    ReadingPosition? position,
    String bookId = '',
  }) => _queue(() async {
    if (durationMs < 0) throw ArgumentError.value(durationMs, 'durationMs');
    final books = Set<String>.of(stats.books);
    _addBook(books, metadata);
    final days = Map<String, int>.of(stats.days);
    var cursor = start.toLocal(), remaining = durationMs;
    final parts = <(DateTime, int)>[];
    while (remaining > 0) {
      final midnight = DateTime(cursor.year, cursor.month, cursor.day + 1);
      final untilMidnight = midnight.difference(cursor).inMilliseconds;
      final part = remaining < untilMidnight ? remaining : untilMidnight;
      parts.add((cursor, part));
      days.update(localDate(cursor), (n) => n + part, ifAbsent: () => part);
      remaining -= part;
      cursor = midnight;
    }
    final updated = ReadingStats(
      milliseconds: stats.milliseconds + durationMs,
      days: days,
      books: books,
    );
    final committed = await sync.db.transaction(() async {
      if (bookId.startsWith('book:local|')) {
        final hash = bookId.split('/').last;
        if (await sync.importedBooks?.book(hash) == null) return false;
      }
      await sync.setMeta('local:reading-stats', jsonEncode(updated.toJson()));
      final title = (metadata['title'] as String? ?? '').trim();
      if (title.isEmpty) return true;
      final author = (metadata['author'] as String? ?? '').trim();
      final bookKey =
          bookId.startsWith('book:local|') ||
              bookId.startsWith(yesheComicBookPrefix)
          ? bookId
          : '${_normalize(title)}\u001f${_normalize(author)}';
      for (final (wall, duration) in parts) {
        final day = localDate(wall);
        final end = wall
            .add(Duration(milliseconds: duration - 1))
            .toUtc()
            .toIso8601String();
        await sync.db.customStatement(
          'INSERT INTO local_reading_history(day,book_key,title,author,last_read,duration_ms,position_json,is_special,book_id) VALUES(?,?,?,?,?,?,?,?,?) '
          'ON CONFLICT(day,book_key) DO UPDATE SET '
          'duration_ms=local_reading_history.duration_ms+excluded.duration_ms,'
          'title=excluded.title,author=excluded.author,'
          'is_special=MAX(local_reading_history.is_special,excluded.is_special),'
          "book_id=CASE WHEN excluded.book_id<>'' THEN excluded.book_id ELSE local_reading_history.book_id END,"
          'position_json=CASE WHEN excluded.last_read>=local_reading_history.last_read THEN excluded.position_json ELSE local_reading_history.position_json END,'
          'last_read=MAX(local_reading_history.last_read,excluded.last_read)',
          [
            day,
            bookKey,
            title,
            author,
            end,
            duration,
            jsonEncode(position?.toJson()),
            isSpecialLibrarySource(metadata) ? 1 : 0,
            bookId,
          ],
        );
        if (position != null && position.chapterUrl.isNotEmpty) {
          await sync.db.customStatement(
            'INSERT OR IGNORE INTO local_reading_chapters(month,book_key,chapter_key) VALUES(?,?,?)',
            [day.substring(0, 7), bookKey, position.chapterKey],
          );
        }
      }
      return true;
    });
    if (!committed) return;
    stats = updated;
    if (!_closed) statChanges.add(stats);
  });

  Future<ReadingOverview> readingOverview(DateTime now) async {
    final today = now.toLocal();
    final todayKey = localDate(today);
    final firstDay = localDate(
      DateTime(today.year, today.month, today.day - 29),
    );
    final monthKey = todayKey.substring(0, 7);
    final monthStart = '$monthKey-01';
    final rangeStart = firstDay.compareTo(monthStart) < 0
        ? firstDay
        : monthStart;
    final rows = await sync.db
        .customSelect(
          'SELECT * FROM local_reading_history WHERE day>=? AND day<=? ORDER BY day DESC,last_read DESC,book_key',
          variables: [Variable(rangeStart), Variable(todayKey)],
        )
        .get();
    // Earlier versions stored only title/author. Recover classification from
    // retained sync metadata, including books removed from the current shelf.
    final specialKeys = <String>{},
        specialTitles = <String>{},
        unknownAuthorTitles = <String>{};
    if (rows.any((row) => row.read<int>('is_special') == 0)) {
      for (final record in await sync.records()) {
        for (final version in record.versions) {
          final metadata = version.payload;
          if (!isSpecialLibrarySource(metadata)) continue;
          final title = _normalize(metadata['title'] as String? ?? '');
          if (title.isEmpty) continue;
          final author = _normalize(metadata['author'] as String? ?? '');
          specialKeys.add('$title\u001f$author');
          specialTitles.add(title);
          if (author.isEmpty) unknownAuthorTitles.add(title);
        }
      }
    }
    final entries = <ReadingDayEntry>[];
    await sync.db.transaction(() async {
      for (final row in rows) {
        final title = _normalize(row.read<String>('title'));
        final author = _normalize(row.read<String>('author'));
        final special =
            row.read<int>('is_special') == 1 ||
            specialKeys.contains(row.read<String>('book_key')) ||
            (author.isEmpty && specialTitles.contains(title)) ||
            unknownAuthorTitles.contains(title);
        if (special && row.read<int>('is_special') == 0) {
          await sync.db.customStatement(
            'UPDATE local_reading_history SET is_special=1 WHERE day=? AND book_key=?',
            [row.read<String>('day'), row.read<String>('book_key')],
          );
        }
        if (row.read<String>('day').compareTo(firstDay) >= 0) {
          entries.add(ReadingDayEntry.fromRow(row.data, isSpecial: special));
        }
      }
    });
    final desktopRows = await sync.db
        .customSelect(
          'SELECT json FROM desktop_reading WHERE day>=? AND day<=?',
          variables: [Variable(rangeStart), Variable(todayKey)],
        )
        .get();
    final desktop = desktopRows
        .map(
          (row) => DesktopReadingEntry.fromJson(
            jsonDecode(row.read<String>('json')) as Map<String, dynamic>,
          ),
        )
        .toList();
    final knownKeys = <String, Set<String>>{};
    for (final key in stats.books) {
      final split = key.indexOf('\u001f');
      if (split < 0 || split == key.length - 1) continue;
      knownKeys.putIfAbsent(key.substring(0, split), () => {}).add(key);
    }
    String resolveKey(String key) {
      if (!key.endsWith('\u001f')) return key;
      final known = knownKeys[key.substring(0, key.length - 1)];
      return known?.length == 1 ? known!.single : key;
    }

    final bookIds = <String, String>{};
    final dayBookIds = <(String, String), String>{};
    for (final row in rows) {
      final id = row.read<String>('book_id');
      if (id.isEmpty) continue;
      final key = resolveKey(row.read<String>('book_key'));
      bookIds.putIfAbsent(id, () => key);
      dayBookIds[(row.read<String>('day'), id)] = key;
    }
    final desktopIdsByTitle = <String, Set<String>>{};
    for (final entry in desktop) {
      desktopIdsByTitle
          .putIfAbsent(_normalize(entry.title), () => {})
          .add(entry.bookId);
    }
    String desktopKey(DesktopReadingEntry entry) {
      final exact =
          dayBookIds[(entry.day, entry.bookId)] ?? bookIds[entry.bookId];
      if (exact != null) return exact;
      final title = _normalize(entry.title);
      // Several book IDs with this title make a title-only match ambiguous.
      if (desktopIdsByTitle[title]!.length > 1) {
        return '$title\u001f${entry.bookId}';
      }
      return resolveKey('$title\u001f');
    }

    final chapterRows = await sync.db
        .customSelect(
          'SELECT book_key,chapter_key FROM local_reading_chapters WHERE month=?',
          variables: [Variable(monthKey)],
        )
        .get();
    var chapterCount = chapterRows.length;
    var timeline = entries;
    final days = Map<String, int>.of(stats.days);
    if (desktop.isNotEmpty) {
      final merged = <(String, String), ReadingDayEntry>{};
      final chapterAliases = <(String, String), String>{};

      void rememberChapter(String key, ReadingPosition? position) {
        if (position?.chapterIndex != null) {
          chapterAliases[(key, 'url:${position!.chapterUrl}')] =
              position.chapterKey;
        }
      }

      void addEntry(String key, ReadingDayEntry entry) {
        final identity = (entry.day, key);
        final old = merged[identity];
        final latest = old != null && old.lastRead.isAfter(entry.lastRead)
            ? old
            : entry;
        merged[identity] = ReadingDayEntry(
          day: entry.day,
          bookKey: key,
          title: latest.title,
          author: entry.author.isNotEmpty ? entry.author : old?.author ?? '',
          lastRead: latest.lastRead,
          milliseconds: entry.milliseconds + (old?.milliseconds ?? 0),
          position: latest.position ?? old?.position,
          isSpecial: entry.isSpecial || (old?.isSpecial ?? false),
          onPhone: entry.onPhone || (old?.onPhone ?? false),
          onDesktop: entry.onDesktop || (old?.onDesktop ?? false),
        );
      }

      for (final entry in entries) {
        final key = resolveKey(entry.bookKey);
        rememberChapter(key, entry.position);
        addEntry(key, entry);
      }
      for (final entry in desktop) {
        final key = desktopKey(entry);
        rememberChapter(key, entry.position);
        days.update(
          entry.day,
          (value) => value + entry.milliseconds,
          ifAbsent: () => entry.milliseconds,
        );
        if (entry.day.compareTo(firstDay) < 0) continue;
        addEntry(
          key,
          ReadingDayEntry(
            day: entry.day,
            bookKey: key,
            title: entry.title,
            author: '',
            lastRead: entry.lastRead,
            milliseconds: entry.milliseconds,
            position: entry.position,
            isSpecial: isSpecialLibrarySource(entry.json),
            onPhone: false,
            onDesktop: true,
          ),
        );
      }
      timeline = merged.values.toList()
        ..sort((a, b) {
          final byDay = b.day.compareTo(a.day);
          if (byDay != 0) return byDay;
          final byTime = b.lastRead.compareTo(a.lastRead);
          return byTime == 0 ? a.bookKey.compareTo(b.bookKey) : byTime;
        });
      final chapters = <(String, String)>{};
      void addChapter(String key, String chapter) {
        chapters.add((key, chapterAliases[(key, chapter)] ?? chapter));
      }

      for (final row in chapterRows) {
        addChapter(
          resolveKey(row.read<String>('book_key')),
          row.read<String>('chapter_key'),
        );
      }
      for (final entry in desktop) {
        if (entry.day.startsWith(monthKey)) {
          addChapter(desktopKey(entry), entry.position.chapterKey);
        }
      }
      chapterCount = chapters.length;
    }
    var duration = 0;
    for (final entry in days.entries) {
      if (entry.key.startsWith('$monthKey-') &&
          entry.key.compareTo(todayKey) <= 0) {
        duration += entry.value;
      }
    }
    var day = DateTime(today.year, today.month, today.day), streak = 0;
    if ((days[localDate(day)] ?? 0) <= 120000) {
      day = DateTime(day.year, day.month, day.day - 1);
    }
    while (day.year == today.year &&
        day.month == today.month &&
        (days[localDate(day)] ?? 0) > 120000) {
      streak++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return ReadingOverview(
      entries: timeline,
      month: ReadingMonthSummary(
        month: DateTime(today.year, today.month),
        milliseconds: duration,
        chapters: chapterCount,
        streak: streak,
      ),
    );
  }

  Future<ReadingStats> combinedReadingStats() async {
    final local = stats;
    final desktopRows = await sync.db
        .customSelect(
          'SELECT day,SUM(milliseconds) AS duration FROM desktop_reading GROUP BY day',
        )
        .get();
    final days = Map<String, int>.of(local.days);
    final desktopDays = <String, int>{};
    var desktopDuration = 0;
    for (final row in desktopRows) {
      final day = row.read<String>('day');
      final milliseconds = row.read<int>('duration');
      desktopDays[day] = milliseconds;
      days[day] = (days[day] ?? 0) + milliseconds;
      desktopDuration += milliseconds;
    }
    return ReadingStats(
      milliseconds: local.milliseconds + desktopDuration,
      days: days,
      books: local.books,
      desktopMilliseconds: desktopDuration,
      desktopDays: desktopDays,
    );
  }

  Stream<void> get readingUpdates => Stream.multi((sink) {
    final subscription = statChanges.stream.listen((_) => sink.add(null));
    sink.onCancel = subscription.cancel;
    sink.add(null);
  });

  Future<void> close() async {
    _closed = true;
    await _desktopReadingSubscription?.cancel();
    await _importedBookSubscription?.cancel();
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
    this.bookId = '',
  }) : now = now ?? DateTime.now,
       _elapsedOverride = elapsed;
  final LocalLibrary library;
  final Map<String, dynamic> metadata;
  final String bookId;
  final DateTime Function() now;
  final int Function()? _elapsedOverride;
  final _watch = Stopwatch()..start();
  bool _active = false;
  int _lastElapsed = 0;
  DateTime? _lastWall;
  Future<void> _pending = Future.value();
  int get _elapsed => _elapsedOverride?.call() ?? _watch.elapsedMilliseconds;
  ReadingPosition? _position;

  void updatePosition(ReadingPosition position) {
    if (_position?.chapterUrl != position.chapterUrl) checkpoint().ignore();
    _position = position;
  }

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
      _pending = library.recordReading(
        metadata,
        wall,
        delta,
        position: _position,
        bookId: bookId,
      );
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
  yield* library.readingUpdates.asyncMap((_) => library.combinedReadingStats());
});

final readingOverviewProvider = StreamProvider.autoDispose<ReadingOverview>((
  ref,
) async* {
  ref.watch(localDayProvider);
  final library = await ref.watch(localLibraryProvider.future);
  yield* library.readingUpdates.asyncMap(
    (_) => library.readingOverview(DateTime.now()),
  );
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
