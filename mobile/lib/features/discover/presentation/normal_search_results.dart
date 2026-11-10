import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/discover_repository.dart';
import '../data/normal_search.dart';
import 'search_results_surface.dart';

class NormalSearchResults extends StatefulWidget {
  const NormalSearchResults({
    super.key,
    required this.source,
    required this.index,
    required this.scroll,
    required this.epoch,
    required this.opening,
    required this.onOpen,
    required this.onRetry,
  });
  final SourceSearchState source;
  final int index;
  final ScrollController scroll;
  final ValueListenable<int> epoch;
  final ValueListenable<bool> opening;
  final ValueChanged<DiscoverBook> onOpen;
  final VoidCallback onRetry;

  @override
  State<NormalSearchResults> createState() => _NormalSearchResultsState();
}

class _NormalSearchResultsState extends State<NormalSearchResults>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RepaintBoundary(
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.opening,
        child: ValueListenableBuilder<int>(
          valueListenable: widget.epoch,
          builder: (context, epoch, _) => ListenableBuilder(
            listenable: widget.source,
            builder: (context, _) {
              final source = widget.source;
              return CustomScrollView(
                controller: widget.scroll,
                key: PageStorageKey(
                  'normal-search-results-$epoch-${widget.index}',
                ),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.only(top: 2),
                    sliver: SliverList.separated(
                      itemCount: source.books.length,
                      separatorBuilder: (_, _) => const SearchResultDivider(),
                      itemBuilder: (context, index) => NormalSearchResultRow(
                        key: ValueKey(
                          '${source.books[index].sourceId}:${source.books[index].url}',
                        ),
                        book: source.books[index],
                        onTap: () => widget.onOpen(source.books[index]),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        16,
                        16,
                        24 + SearchResultsSurface.bottomInset(context),
                      ),
                      child: Center(
                        child: !source.started || source.loading
                            ? const CircularProgressIndicator()
                            : source.error != null
                            ? Column(
                                children: [
                                  Text(
                                    source.error!,
                                    textAlign: TextAlign.center,
                                  ),
                                  if (source.unavailableMessage == null &&
                                      (source.visited.isEmpty ||
                                          source.nextUrl != null))
                                    TextButton(
                                      onPressed: widget.onRetry,
                                      child: const Text('重试此书源'),
                                    ),
                                ],
                              )
                            : Text(
                                source.books.isEmpty
                                    ? '此书源没有找到相关小说'
                                    : source.nextUrl == null
                                    ? '此书源结果已全部展示'
                                    : '继续向下滚动加载',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        builder: (context, opening, child) =>
            IgnorePointer(ignoring: opening, child: child),
      ),
    );
  }
}

/// 52dp hit area plus the separate 8dp divider. Text can grow for accessibility.
class NormalSearchResultRow extends StatelessWidget {
  const NormalSearchResultRow({
    super.key,
    required this.book,
    required this.onTap,
  });
  final DiscoverBook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontSize: 16, height: 1.25),
                    ),
                    if (book.author.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(fontSize: 12, height: 1.25),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      ),
    ),
  );
}
