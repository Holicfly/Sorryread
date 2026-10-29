import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/sync_repository.dart';
import '../../../sync_engine/sync_model.dart';
import '../data/reader_source.dart';
import 'reader_layout.dart';
import 'reader_preferences.dart';

final readerResumeCacheProvider = Provider<ReaderResumeCache>((ref) {
  final cache = ReaderResumeCache();
  ref.onDispose(cache.dispose);
  return cache;
});

/// Owns at most two already-shaped current chapters between reader routes.
/// Taking an entry transfers its TextPainter ownership to the new reader.
class ReaderResumeCache {
  final _entries = <String, ReaderResume>{};
  String? _preferences;
  bool _disposed = false;

  bool remember(String id, ReaderResume entry) {
    if (_disposed) return false;
    final preferences = entry.preferences.toJson().toString();
    if (_preferences != preferences) clear();
    _preferences = preferences;
    _entries.remove(id)?.dispose();
    _entries[id] = entry;
    while (_entries.length > 2) {
      _entries.remove(_entries.keys.first)?.dispose();
    }
    return true;
  }

  ReaderResume? take(ShelfBook book, MediaQueryData metrics) {
    final entry = _entries.remove(book.id);
    if (entry == null) return null;
    final remote = book.position?.effective.payload;
    final comparison = remote == null
        ? 0
        : compareBookPositions(remote, entry.position);
    final unknownPositionChanged =
        comparison == null &&
        remote != null &&
        (remote['chapterUrl'] != entry.position['chapterUrl'] ||
            remote['progress'] != entry.position['progress']);
    if (entry.metrics.size != metrics.size ||
        entry.metrics.viewPadding != metrics.viewPadding ||
        entry.metrics.devicePixelRatio != metrics.devicePixelRatio ||
        entry.metrics.textScaler.scale(20) != metrics.textScaler.scale(20) ||
        (comparison ?? 0) > 0 ||
        unknownPositionChanged) {
      entry.dispose();
      return null;
    }
    return entry;
  }

  void clear() {
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}

class ReaderResume {
  ReaderResume({
    required this.catalog,
    required this.source,
    required this.layout,
    required this.preferences,
    required this.family,
    required this.chapterIndex,
    required this.anchor,
    required this.scrollWithinChapter,
    required this.metrics,
    required this.bottomClearance,
    required this.position,
    this.paperImage,
  });
  final ReaderCatalog catalog;
  final SourceRule source;
  final ReaderLayout layout;
  final ReaderPreferences preferences;
  final String? family;
  final int chapterIndex;
  final TextAnchor anchor;
  final double? scrollWithinChapter;
  final MediaQueryData metrics;
  final double bottomClearance;
  final Map<String, dynamic> position;
  final ui.Image? paperImage;
  void dispose() {
    layout.dispose();
    paperImage?.dispose();
  }
}
