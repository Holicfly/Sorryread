import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dependencies.dart';
import '../../../data/sync_repository.dart';
import '../../../data/local_library.dart';
import '../../../design_system/components.dart';
import '../../sync/presentation/sync_status_card.dart';
import 'book_cover.dart';
import 'book_opening.dart';
import '../../reader/presentation/reader_page.dart';
import '../../reader/data/reader_font_warmup.dart';

class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});
  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  bool recentOnly = false, _show18mh = false;
  int _titleTaps = 0, _lastTitleTap = -1;
  final _tapClock = Stopwatch()..start();
  final _covers = BookCoverAssignments();
  List<ShelfBook>? _openShelf;
  final _warmRequested = <int>{}, _warmReady = <int>{};
  final _warmTimers = <int, Timer>{};
  final _coverKeys = <String, GlobalKey>{};
  final _coverRasters = <String, (String, ui.Image)>{};
  final _rasterTimers = <String, Timer>{};
  final _rasterPending = <String>{};
  Timer? _fontWarmupTimer;

  @override
  void initState() {
    super.initState();
    // Register only the selected face while the shelf is idle. FontLoader's
    // first native registration can otherwise stall the UI event loop during
    // an opening despite low buildDuration. Tapping never awaits this work.
    _fontWarmupTimer = Timer(const Duration(milliseconds: 160), () async {
      if (!mounted || _openShelf != null) return;
      try {
        await ref.read(readerFontWarmupProvider)();
      } catch (_) {
        // Speculation must not affect normal reader loading or navigation.
      }
    });
  }

  void _queueCoverRaster(String id, String signature, GlobalKey key) {
    if (_coverRasters[id]?.$1 == signature ||
        _rasterTimers.containsKey(id) ||
        _rasterPending.contains(id) ||
        _openShelf != null) {
      return;
    }
    _rasterTimers[id] = Timer(const Duration(milliseconds: 220), () async {
      _rasterTimers.remove(id);
      if (!mounted || _openShelf != null) return;
      final box = key.currentContext?.findRenderObject();
      if (box is! _CoverRenderBoundary || box.size.isEmpty) {
        return;
      }
      _rasterPending.add(id);
      try {
        final captured = box.captureCover();
        if (captured == null) return;
        final image = await captured;
        if (!mounted || _openShelf != null) {
          image.dispose();
          return;
        }
        _coverRasters.remove(id)?.$2.dispose();
        _coverRasters[id] = (signature, image);
        while (_coverRasters.length > 6) {
          _coverRasters.remove(_coverRasters.keys.first)?.$2.dispose();
        }
      } catch (_) {
        // This idle cache is optional; a detached/disposed layer must never
        // prevent opening a book with the normal static cover fallback.
      } finally {
        _rasterPending.remove(id);
      }
    });
  }

  void _warmCovers(Iterable<int> designs) {
    for (final design in designs) {
      if (!_warmRequested.add(design)) continue;
      // Coalesce rebuilds and give the visible thumbnail its first frame first.
      // This timer never gates tapping or route animation.
      _warmTimers[design] = Timer(const Duration(milliseconds: 120), () {
        _warmTimers.remove(design);
        if (!mounted || _openShelf != null) {
          _warmRequested.remove(design);
          return;
        }
        unawaited(
          Future.wait([
            precacheImage(
              ResizeImage(
                AssetImage('assets/covers/cover_${design + 1}.png'),
                width: 1024,
              ),
              context,
            ),
            precacheImage(
              const ResizeImage(
                AssetImage('assets/covers/spine.png'),
                width: 1024,
              ),
              context,
            ),
          ]).then((_) {
            _warmReady.add(design);
          }),
        );
      });
    }
  }

  @override
  void dispose() {
    _fontWarmupTimer?.cancel();
    for (final timer in _warmTimers.values) {
      timer.cancel();
    }
    for (final timer in _rasterTimers.values) {
      timer.cancel();
    }
    for (final value in _coverRasters.values) {
      value.$2.dispose();
    }
    super.dispose();
  }

  void _tapHeading() {
    final now = _tapClock.elapsedMilliseconds;
    _titleTaps = _lastTitleTap >= 0 && now - _lastTitleTap <= 800
        ? _titleTaps + 1
        : 1;
    _lastTitleTap = now;
    if (_titleTaps == 5) {
      _titleTaps = 0;
      setState(() => _show18mh = !_show18mh);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(shelfBooksProvider);
    final books = data.asData?.value ?? <ShelfBook>[];
    final pins = ref.watch(shelfPinsProvider).asData?.value ?? <String, int>{};
    final grouped = books.where((b) => b.isSpecialSource == _show18mh).toList();
    final favorites = grouped.where((b) => b.favorite).toList();
    // Stable tie order follows the existing bookshelf order for unpinned books.
    final order = {
      for (var i = 0; i < favorites.length; i++) favorites[i].id: i,
    };
    favorites.sort((a, b) {
      final pinnedOrder = (pins[b.id] ?? 0).compareTo(pins[a.id] ?? 0);
      return pinnedOrder != 0
          ? pinnedOrder
          : order[a.id]!.compareTo(order[b.id]!);
    });
    final recent = grouped.where((b) => b.recent).take(10).toList();
    final shown = _openShelf ?? (recentOnly ? recent : favorites);
    final designs = _covers.forBooks(shown.map((b) => b.id).toList());
    _warmCovers(designs);
    return PageWidth(
      child: CustomScrollView(
        key: const PageStorageKey('bookshelf-scroll'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            sliver: SliverList.list(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _tapHeading,
                  child: const PageHeading('我的书架'),
                ),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ChoiceChip(
                      label: Text('收藏  ${favorites.length}'),
                      selected: !recentOnly,
                      onSelected: (_) => setState(() => recentOnly = false),
                    ),
                    ChoiceChip(
                      label: Text('最近阅读  ${recent.length}'),
                      selected: recentOnly,
                      onSelected: (_) => setState(() => recentOnly = true),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const SyncStatusCard(),
                const SizedBox(height: 22),
                Text(
                  '${_show18mh ? '18mh / 夜社 · ' : ''}${recentOnly ? '最近阅读' : '收藏书籍'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
          if (data.isLoading)
            const SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
          if (data.hasError)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Text('书架暂时无法加载'),
                    TextButton(
                      onPressed: () => ref.invalidate(shelfBooksProvider),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          if (!data.isLoading && !data.hasError && shown.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 30, 20, 40),
                child: SurfaceBlock(
                  child: Column(
                    children: [
                      Icon(
                        Icons.menu_book_outlined,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        recentOnly ? '暂无最近阅读' : '暂无收藏书籍',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '连接电脑后，收藏和最近阅读会显示在这里。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = (constraints.crossAxisExtent - 28) / 3;
                final scaler = MediaQuery.textScalerOf(context);
                return SliverGrid.builder(
                  itemCount: shown.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 20,
                    mainAxisExtent:
                        width / BookCover.aspectRatio +
                        scaler.scale(15) * 1.5 +
                        scaler.scale(12) * 1.5 +
                        16,
                  ),
                  itemBuilder: (context, index) => Builder(
                    builder: (cardContext) {
                      final id = shown[index].id;
                      final signature =
                          '$id:${shown[index].title}:${_bookProgressLabel(shown[index])}:${designs[index]}:$width';
                      final coverKey = _coverKeys.putIfAbsent(
                        id,
                        () => GlobalKey(),
                      );
                      _queueCoverRaster(id, signature, coverKey);
                      return _CoverBoundary(
                        key: coverKey,
                        child: _BookCard(
                          book: shown[index],
                          design: designs[index],
                          pinned:
                              !recentOnly && pins.containsKey(shown[index].id),
                          onTap: () async {
                            if (_openShelf != null) return;
                            final box =
                                cardContext.findRenderObject() as RenderBox?;
                            final releaseBackdrop = BookShelfBackdrop.hold(
                              context,
                            );
                            var released = false;
                            void release() {
                              if (released) return;
                              released = true;
                              releaseBackdrop();
                              if (mounted) setState(() => _openShelf = null);
                            }

                            final opening = box == null
                                ? null
                                : BookOpening(
                                    box.localToGlobal(Offset.zero) &
                                        Size(
                                          box.size.width,
                                          box.size.width /
                                              BookCover.aspectRatio,
                                        ),
                                    designs[index],
                                    shown[index].title,
                                    _bookProgressLabel(shown[index]),
                                    decodeWidth:
                                        _warmReady.contains(designs[index])
                                        ? 1024
                                        : null,
                                    onClosed: release,
                                    coverImage:
                                        _coverRasters[id]?.$1 == signature
                                        ? _coverRasters[id]!.$2
                                        : null,
                                  );
                            setState(() => _openShelf = List.of(shown));
                            try {
                              // Start the route immediately. A cold tap reuses the
                              // already-visible thumbnail; larger decode is idle work.
                              await context.push(
                                '/reader',
                                extra: ReaderOpenRequest(
                                  shown[index],
                                  opening: opening,
                                ),
                              );
                            } catch (_) {
                              release();
                              rethrow;
                            } finally {
                              if (opening == null) release();
                              // For cover routes, TransitionRoute.completed owns release.
                            }
                          },
                          onLongPress: () => _showBook(shown[index]),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Future<void> _showBook(ShelfBook book) async {
    try {
      await HapticFeedback.mediumImpact();
    } on PlatformException {
      // A device without haptic support should still open the menu.
    }
    if (!mounted) return;
    final pinned =
        ref.read(shelfPinsProvider).asData?.value.containsKey(book.id) ?? false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(book.title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(
                  book.conflicted
                      ? '阅读进度存在冲突，请在设备同步页选择位置。'
                      : '上次位置：${book.metadata['chapterTitle'] == '' ? '尚无章节信息' : book.metadata['chapterTitle']} · ${_bookProgressLabel(book)}',
                ),
                const SizedBox(height: 8),
                const SizedBox(height: 20),
                if (!recentOnly && book.favorite)
                  TextButton.icon(
                    onPressed: () async {
                      try {
                        final library = await ref.read(
                          localLibraryProvider.future,
                        );
                        await library.setPinned(book.id, !pinned);
                        if (context.mounted) Navigator.pop(context);
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('置顶状态保存失败，请重试。')),
                          );
                        }
                      }
                    },
                    icon: Icon(
                      pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                    ),
                    label: Text(pinned ? '取消置顶' : '置顶'),
                  ),
                FilledButton.tonal(
                  onPressed: () async {
                    final repo = await ref.read(syncRepositoryProvider.future);
                    await repo.setFavorite(book, !book.favorite);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Text(book.favorite ? '取消收藏' : '加入收藏'),
                ),
                if (book.recent)
                  TextButton(
                    onPressed: () async {
                      final repo = await ref.read(
                        syncRepositoryProvider.future,
                      );
                      await repo.removeRecent(book);
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text('移出最近阅读'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.design,
    required this.onTap,
    required this.onLongPress,
    this.pinned = false,
  });
  final ShelfBook book;
  final int design;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool pinned;
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${book.title}，${book.favorite ? '已收藏' : '最近阅读'}',
      button: true,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                BookCover(
                  design: design,
                  title: book.title,
                  progress: book.conflicted
                      ? '进度待选择'
                      : _bookProgressLabel(book),
                ),
                if (pinned)
                  Positioned(
                    top: 5,
                    right: 5,
                    child: Semantics(
                      label: '已置顶',
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.push_pin_rounded,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              book.source.isEmpty ? '来源未提供' : book.source,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

String _bookProgressLabel(ShelfBook book) {
  final value = book.bookProgress;
  return value == null ? '待读取' : '${(value * 100).floor()}%';
}

/// Exposes a cropped capture from inside the render object, where its retained
/// layer is owned. No layout or paint changes compared with RepaintBoundary.
class _CoverBoundary extends SingleChildRenderObjectWidget {
  const _CoverBoundary({super.key, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _CoverRenderBoundary();
}

class _CoverRenderBoundary extends RenderRepaintBoundary {
  Future<ui.Image>? captureCover() {
    final painted = layer;
    if (!hasSize ||
        size.isEmpty ||
        painted is! OffsetLayer ||
        !painted.supportsRasterization()) {
      return null;
    }
    return painted.toImage(
      Rect.fromLTWH(0, 0, size.width, size.width / BookCover.aspectRatio),
      pixelRatio: 768 / size.width,
    );
  }
}
