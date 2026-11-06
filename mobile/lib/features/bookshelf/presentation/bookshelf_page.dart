import 'dart:async';
import 'dart:io';
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
import 'shelf_actions_dock.dart';
import '../../reader/presentation/reader_page.dart';
import '../../reader/data/reader_font_warmup.dart';

class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});
  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  bool _show18mh = false;
  int _page = 0;
  bool get recentOnly => _page == 1;
  int _titleTaps = 0, _lastTitleTap = -1;
  final _tapClock = Stopwatch()..start();
  final _pages = PageController();
  final _shelfScrolls = List.generate(3, (_) => ScrollController());
  final _covers = List.generate(3, (_) => BookCoverAssignments());
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
    _pages.dispose();
    for (final scroll in _shelfScrolls) {
      scroll.dispose();
    }
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

  void _tapTab(int page) {
    // Keep the existing five-tap source-group entry on the selected tab.
    if (page == _page && page < 2) {
      _tapHeading();
    } else {
      _titleTaps = 0;
    }
    _selectPage(page);
  }

  Widget _shelfTabs(
    int favorites,
    int recent,
    int local, {
    required bool compact,
  }) => Row(
    key: const Key('bookshelf-tabs'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Flexible(
        child: PageTextTab(
          key: const Key('shelf-tab-favorites'),
          label: '收藏',
          count: compact ? null : favorites,
          singleLine: true,
          selected: _page == 0,
          onTap: () => _tapTab(0),
        ),
      ),
      const SizedBox(width: 10),
      Flexible(
        flex: 2,
        child: PageTextTab(
          key: const Key('shelf-tab-recent'),
          label: '最近阅读',
          count: compact ? null : recent,
          singleLine: true,
          selected: recentOnly,
          onTap: () => _tapTab(1),
        ),
      ),
      if (local > 0) ...[
        const SizedBox(width: 10),
        Flexible(
          flex: 2,
          child: PageTextTab(
            key: const Key('shelf-tab-imported'),
            label: '本地图书',
            count: compact ? null : local,
            singleLine: true,
            selected: _page == 2,
            onTap: () => _tapTab(2),
          ),
        ),
      ],
    ],
  );

  void _selectPage(int page) {
    if (_openShelf != null || !_pages.hasClients) return;
    _pages.jumpToPage(page);
    // The jump can report metrics from before the imported page was laid out.
    _setPage(page);
  }

  void _setPage(int page) {
    if (_page == page) return;
    ref.read(shelfSelectionProvider.notifier).clear();
    setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(shelfBooksProvider);
    final selected = ref.watch(shelfSelectionProvider);
    final selection = ref.read(shelfSelectionProvider.notifier);
    final books = data.asData?.value ?? <ShelfBook>[];
    final pins = ref.watch(shelfPinsProvider).asData?.value ?? <String, int>{};
    final local = books.where((book) => book.imported != null).toList();
    local.sort((a, b) => (pins[b.id] ?? 0).compareTo(pins[a.id] ?? 0));
    if (local.isEmpty && _page == 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _page == 2 && _pages.hasClients) _selectPage(0);
      });
    }
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
    final recent = grouped.where((b) => b.recent).toList();
    final recentOrder = {
      for (var i = 0; i < recent.length; i++) recent[i].id: i,
    };
    recent.sort((a, b) {
      final byPin = (pins[b.id] ?? 0).compareTo(pins[a.id] ?? 0);
      return byPin == 0
          ? recentOrder[a.id]!.compareTo(recentOrder[b.id]!)
          : byPin;
    });
    final visibleRecent = recent.take(10).toList();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: selected.isEmpty ? null : selection.clear,
      child: PageWidth(
        // Header is a sibling of the pager, not part of its pages: horizontal
        // swipes must move only the book area (same structure as Fanqie's
        // ViewPager + tab strip).
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IgnorePointer(
              ignoring: selected.isNotEmpty,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.page,
                ),
                child: PageHeader(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact =
                          constraints.maxWidth <
                              (local.isNotEmpty ? 342 : 270) ||
                          MediaQuery.textScalerOf(context).scale(21) > 25;
                      final tabs = _shelfTabs(
                        favorites.length,
                        visibleRecent.length,
                        local.length,
                        compact: compact,
                      );
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(child: tabs),
                          const SizedBox(width: 8),
                          SyncStatusEntry(showCaption: !compact),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                key: const Key('bookshelf-pager'),
                controller: _pages,
                // ViewPager-compatible snapping: a short but fast flick switches
                // one page even when the finger travelled well under 50%.
                physics: _openShelf == null && selected.isEmpty
                    ? const PageScrollPhysics(parent: ClampingScrollPhysics())
                    : const NeverScrollableScrollPhysics(),
                onPageChanged: _setPage,
                itemCount: local.isEmpty && _page != 2 ? 2 : 3,
                itemBuilder: (context, page) => _shelfPage(
                  page: page,
                  data: data,
                  favorites: favorites,
                  recent: visibleRecent,
                  local: local,
                  pins: pins,
                  selected: selected,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shelfPage({
    required int page,
    required AsyncValue<List<ShelfBook>> data,
    required List<ShelfBook> favorites,
    required List<ShelfBook> recent,
    required List<ShelfBook> local,
    required Map<String, int> pins,
    required Set<String> selected,
  }) {
    final recentOnly = page == 1;
    final shown = _openShelf != null && page == _page
        ? _openShelf!
        : (page == 2
              ? local
              : recentOnly
              ? recent
              : favorites);
    final designs = _covers[page].forBooks(shown.map((b) => b.id).toList());
    _warmCovers(designs);
    return CustomScrollView(
      key: PageStorageKey(
        page == 2
            ? 'bookshelf-imported-scroll'
            : recentOnly
            ? 'bookshelf-recent-scroll'
            : 'bookshelf-scroll',
      ),
      controller: _shelfScrolls[page],
      slivers: [
        if (_show18mh && page != 2)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                0,
                AppSpacing.page,
                12,
              ),
              child: Text(
                '18mh / 夜社',
                style: Theme.of(context).textTheme.bodySmall,
              ),
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
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.listInset,
                30,
                AppSpacing.listInset,
                40,
              ),
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
                      page == 2
                          ? '暂无本地图书'
                          : recentOnly
                          ? '暂无最近阅读'
                          : '暂无收藏书籍',
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
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            6,
            AppSpacing.page,
            0,
          ),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.crossAxisExtent - 40) / 3;
              final scaler = MediaQuery.textScalerOf(context);
              // Text layout rounds a line's height up to a logical pixel.
              // Use the same rounding so fractional font scales still fit.
              final titleHeight = (scaler.scale(14) * 1.5).ceilToDouble();
              final sourceHeight = (scaler.scale(12) * 1.4).ceilToDouble();
              return SliverGrid.builder(
                itemCount: shown.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 20,
                  mainAxisSpacing: 24,
                  mainAxisExtent:
                      width / BookCover.aspectRatio +
                      (titleHeight > 28 ? titleHeight : 28) +
                      sourceHeight +
                      11,
                ),
                itemBuilder: (context, index) => Builder(
                  builder: (cardContext) {
                    final id = shown[index].id;
                    final imported = shown[index].imported;
                    final design = imported == null
                        ? designs[index]
                        : int.parse(imported.hash.substring(0, 8), radix: 16) %
                              6;
                    final coverPath = imported?.coverPath;
                    // The same book can be mounted in both moving pages.
                    // Give each cover its own render key and raster cache.
                    final coverId = '$page:$id';
                    final signature =
                        '$id:${shown[index].title}:${shelfBookProgressLabel(shown[index])}:$design:$width:$coverPath';
                    final coverKey = _coverKeys.putIfAbsent(
                      coverId,
                      () => GlobalKey(),
                    );
                    _queueCoverRaster(coverId, signature, coverKey);
                    return _CoverBoundary(
                      key: coverKey,
                      child: _BookCard(
                        book: shown[index],
                        design: design,
                        pinned: pins.containsKey(id),
                        selected: selected.isEmpty
                            ? null
                            : selected.contains(id),
                        onTap: () async {
                          if (ref.read(shelfSelectionProvider).isNotEmpty) {
                            ref
                                .read(shelfSelectionProvider.notifier)
                                .toggle(id, tab: ShelfTab.values[page]);
                            return;
                          }
                          if (imported?.ready == false) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('等待同步原文件，也可以从发现页导入同一文件。'),
                              ),
                            );
                            return;
                          }
                          if (_openShelf != null ||
                              _pages.position.isScrollingNotifier.value) {
                            return;
                          }
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
                                        box.size.width / BookCover.aspectRatio,
                                      ),
                                  design,
                                  shown[index].title,
                                  shelfBookProgressLabel(shown[index]),
                                  decodeWidth: _warmReady.contains(design)
                                      ? 1024
                                      : null,
                                  onClosed: release,
                                  localCover: coverPath == null
                                      ? null
                                      : File(coverPath),
                                  coverImage:
                                      _coverRasters[coverId]?.$1 == signature
                                      ? _coverRasters[coverId]!.$2
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
                        onLongPress: () =>
                            _selectBook(id, ShelfTab.values[page]),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: 28 + MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );
  }

  Future<void> _selectBook(String id, ShelfTab tab) async {
    if (_openShelf != null) return;
    ref.read(shelfSelectionProvider.notifier).toggle(id, tab: tab);
    try {
      await HapticFeedback.mediumImpact();
    } on PlatformException {
      // Haptics are optional.
    }
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.design,
    required this.onTap,
    required this.onLongPress,
    this.pinned = false,
    this.selected,
  });
  final ShelfBook book;
  final int design;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool pinned;
  final bool? selected;
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          '${book.title}，${book.favorite
              ? '已收藏'
              : book.imported != null
              ? '本地图书'
              : '最近阅读'}',
      button: true,
      selected: selected,
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
                      : shelfBookProgressLabel(book),
                  localCover: book.imported?.coverPath == null
                      ? null
                      : File(book.imported!.coverPath!),
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
                if (selected != null)
                  Positioned(
                    right: 5,
                    bottom: 5,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected!
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.surface
                                  .withValues(alpha: .9),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      child: SizedBox.square(
                        dimension: 21,
                        child: selected!
                            ? Icon(
                                Icons.check_rounded,
                                size: 15,
                                color: Theme.of(context).colorScheme.onPrimary,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '管理《${book.title}》',
                  onPressed: onLongPress,
                  icon: const Icon(Icons.more_vert_rounded),
                  iconSize: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 22,
                    height: 28,
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(22, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
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
