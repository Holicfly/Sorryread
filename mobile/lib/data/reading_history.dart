import 'dart:convert';

/// A snapshot of the visible chapter, independent of the synced maximum.
class ReadingPosition {
  const ReadingPosition({
    required this.chapterUrl,
    required this.chapterTitle,
    this.chapterIndex,
    this.chapterCount,
    this.progress = 0,
  });

  final String chapterUrl, chapterTitle;
  final int? chapterIndex, chapterCount;
  final double progress;

  double? get bookProgress {
    final index = chapterIndex, count = chapterCount;
    if (index == null ||
        count == null ||
        count <= 0 ||
        index < 0 ||
        index >= count) {
      return null;
    }
    return ((index + progress.clamp(0, 1)) / count).clamp(0, 1);
  }

  String get chapterLabel {
    if (chapterTitle.isEmpty) {
      return chapterIndex == null ? '' : '第 ${chapterIndex! + 1} 章';
    }
    if (chapterIndex == null ||
        RegExp(r'^第\s*[零一二三四五六七八九十百千万\d]+\s*[章回节]').hasMatch(chapterTitle)) {
      return chapterTitle;
    }
    return '第 ${chapterIndex! + 1} 章 · $chapterTitle';
  }

  String get chapterKey =>
      chapterIndex == null ? 'url:$chapterUrl' : 'index:$chapterIndex';

  Map<String, dynamic> toJson() => {
    'chapterUrl': chapterUrl,
    'chapterTitle': chapterTitle,
    'chapterIndex': chapterIndex,
    'chapterCount': chapterCount,
    'progress': progress,
  };

  factory ReadingPosition.fromJson(Map<String, dynamic> data) =>
      ReadingPosition(
        chapterUrl: data['chapterUrl'] as String,
        chapterTitle: data['chapterTitle'] as String,
        chapterIndex: data['chapterIndex'] as int?,
        chapterCount: data['chapterCount'] as int?,
        progress: (data['progress'] as num).toDouble(),
      );
}

class ReadingDayEntry {
  const ReadingDayEntry({
    required this.day,
    required this.bookKey,
    required this.title,
    required this.author,
    required this.lastRead,
    required this.milliseconds,
    this.isSpecial = false,
    this.onPhone = true,
    this.onDesktop = false,
    this.position,
  });

  final String day, bookKey, title, author;
  final DateTime lastRead;
  final int milliseconds;
  final bool isSpecial;
  final bool onPhone, onDesktop;
  final ReadingPosition? position;

  factory ReadingDayEntry.fromRow(Map<String, dynamic> row, {bool? isSpecial}) {
    final position = jsonDecode(row['position_json'] as String);
    return ReadingDayEntry(
      day: row['day'] as String,
      bookKey: row['book_key'] as String,
      title: row['title'] as String,
      author: row['author'] as String,
      lastRead: DateTime.parse(row['last_read'] as String).toLocal(),
      milliseconds: row['duration_ms'] as int,
      isSpecial: isSpecial ?? row['is_special'] == 1,
      position: position == null
          ? null
          : ReadingPosition.fromJson(position as Map<String, dynamic>),
    );
  }
}

class DesktopReadingEntry {
  DesktopReadingEntry.fromJson(this.json)
    : revision = json['revision'] as int,
      day = json['day'] as String,
      bookId = json['bookId'] as String,
      title = json['title'] as String,
      lastRead = DateTime.parse(json['lastRead'] as String).toLocal(),
      milliseconds = json['milliseconds'] as int,
      position = ReadingPosition.fromJson(json) {
    if (revision <= 0 ||
        milliseconds <= 0 ||
        milliseconds > 100000000 ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day) ||
        DateTime.tryParse(day)?.toIso8601String().split('T').first != day ||
        !bookId.startsWith('book:') ||
        title.trim().isEmpty ||
        position.chapterUrl.isEmpty ||
        !position.progress.isFinite) {
      throw const FormatException('Invalid desktop reading record');
    }
  }

  final Map<String, dynamic> json;
  final int revision, milliseconds;
  final String day, bookId, title;
  final DateTime lastRead;
  final ReadingPosition position;
}

class ReadingMonthSummary {
  const ReadingMonthSummary({
    required this.month,
    this.milliseconds = 0,
    this.chapters = 0,
    this.streak = 0,
  });

  final DateTime month;
  final int milliseconds, chapters, streak;
}

class ReadingOverview {
  const ReadingOverview({required this.entries, required this.month});
  final List<ReadingDayEntry> entries;
  final ReadingMonthSummary month;
}

String readingDuration(int milliseconds) {
  final minutes = milliseconds ~/ 60000;
  if (minutes < 60) return '$minutes 分钟';
  final remainder = minutes % 60;
  return remainder == 0
      ? '${minutes ~/ 60} 小时'
      : '${minutes ~/ 60} 小时 $remainder 分钟';
}
