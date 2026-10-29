import 'reader_repository.dart';
import 'reader_source.dart';

/// Raw content is warmed independently of text layout and visible slivers.
class ReaderPreloader {
  ReaderPreloader(this.repository, this.source, this.catalog, this.onReady);
  final ReaderRepository repository;
  final SourceRule source;
  final List<ChapterLink> catalog;
  final void Function(int, ReaderChapter) onReady;
  final chapters = <int, ReaderChapter>{};
  final _running = <int>{};
  final _failed = <int>{};
  List<int> _queue = [];
  int center = 0;
  bool _closed = false;

  void seed(int index, ReaderChapter chapter) {
    chapters[index] = chapter;
  }

  void warm(int index) {
    center = index;
    _queue =
        [
              index - 1,
              index + 1,
              index - 2,
              index + 2,
              index + 3,
              index + 4,
              index + 5,
            ]
            .where(
              (i) =>
                  i >= 0 &&
                  i < catalog.length &&
                  !chapters.containsKey(i) &&
                  !_running.contains(i) &&
                  !_failed.contains(i),
            )
            .toList();
    chapters.removeWhere((i, _) => i < index - 2 || i > index + 5);
    _pump();
  }

  void _pump() {
    if (_closed) return;
    final limit = source.dynamicPage ? 1 : 2;
    while (_running.length < limit && _queue.isNotEmpty) {
      final index = _queue.removeAt(0);
      _running.add(index);
      _load(index);
    }
  }

  Future<void> _load(int index) async {
    try {
      final body = await repository.chapter(source, catalog[index], catalog);
      if (!_closed && index >= center - 2 && index <= center + 5) {
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
    warm(center);
  }

  void dispose() {
    _closed = true;
    _queue.clear();
  }
}
