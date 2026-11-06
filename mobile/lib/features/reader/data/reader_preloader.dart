import 'dart:math' as math;

import 'reader_source.dart';

/// Raw content is warmed independently of text layout and visible slivers.
class ReaderPreloader {
  ReaderPreloader(
    this.catalog,
    this.load,
    this.onReady, {
    required this.parallelism,
  });
  final Future<ReaderChapter> Function(ChapterLink) load;
  final int parallelism;
  final List<ChapterLink> catalog;
  final void Function(int, ReaderChapter) onReady;
  final chapters = <int, ReaderChapter>{};
  final _running = <int>{};
  final _failed = <int>{};
  List<int> _queue = [];
  int center = 0;
  int _before = 2, _after = 5;
  bool _closed = false;

  void seed(int index, ReaderChapter chapter) {
    chapters[index] = chapter;
  }

  void warm(int index, {int before = 2, int after = 5}) {
    center = index;
    _before = math.min(index, before);
    _after = math.min(catalog.length - index - 1, after);
    _queue =
        [
              for (
                var distance = 1;
                distance <= math.max(_before, _after);
                distance++
              ) ...[
                if (distance <= _before) index - distance,
                if (distance <= _after) index + distance,
              ],
            ]
            .where(
              (i) =>
                  !chapters.containsKey(i) &&
                  !_running.contains(i) &&
                  !_failed.contains(i),
            )
            .toList();
    chapters.removeWhere((i, _) => !_inRange(i));
    _pump();
  }

  bool _inRange(int index) =>
      index >= center - _before && index <= center + _after;

  void _pump() {
    if (_closed) return;
    while (_running.length < parallelism && _queue.isNotEmpty) {
      final index = _queue.removeAt(0);
      _running.add(index);
      _load(index);
    }
  }

  Future<void> _load(int index) async {
    try {
      final body = await load(catalog[index]);
      if (!_closed && _inRange(index)) {
        chapters[index] = body;
        onReady(index, body);
      }
    } catch (_) {
      _failed.add(index);
    } finally {
      _running.remove(index);
      _pump();
    }
  }

  void retry() {
    _failed.clear();
    warm(center, before: _before, after: _after);
  }

  void dispose() {
    _closed = true;
    _queue.clear();
  }
}
