import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dependencies.dart';
import '../../../design_system/components.dart';
import '../../reader/data/reader_repository.dart';
import '../../reader/presentation/reader_page.dart';
import '../data/discover_repository.dart';
import '../data/normal_search.dart';
import 'discover_page.dart';

class NormalSearchPage extends ConsumerStatefulWidget {
  const NormalSearchPage({super.key, required this.query});
  final String query;
  @override
  ConsumerState<NormalSearchPage> createState() => _NormalSearchPageState();
}

class _NormalSearchPageState extends ConsumerState<NormalSearchPage> {
  late final _input = TextEditingController(text: widget.query);
  final _scroll = ScrollController();
  final _offsets = <int, double>{};
  NormalSearchController? _search;
  String? _error;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_nearBottom);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final reader = await ref.read(readerRepositoryProvider.future);
      if (!mounted) return;
      final controller = NormalSearchController(reader)..addListener(_changed);
      if (controller.sources.isEmpty) {
        controller.dispose();
        setState(() => _error = '没有可用的普通书源。');
        return;
      }
      setState(() {
        _search = controller;
        _error = null;
      });
      unawaited(_remember(widget.query));
      unawaited(controller.start(widget.query));
    } catch (_) {
      if (mounted) setState(() => _error = '搜索服务加载失败，请重试。');
    }
  }

  Future<void> _remember(String value) async {
    try {
      final history = await ref.read(discoverHistoryProvider.future);
      await history.add(DiscoverMode.normal, value);
      if (mounted) {
        ref.invalidate(discoverHistoryEntriesProvider(DiscoverMode.normal));
      }
    } catch (_) {
      if (mounted) _notice('搜索记录保存失败。');
    }
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _nearBottom());
  }

  void _nearBottom() {
    final search = _search;
    if (!mounted || search == null || _opening || !_scroll.hasClients) return;
    final state = search.selected;
    if (state.started &&
        !state.loading &&
        state.error == null &&
        state.nextUrl != null &&
        _scroll.position.extentAfter < 240) {
      unawaited(search.loadMore());
    }
  }

  void _select(int index) {
    final search = _search!;
    if (search.selectedIndex == index) {
      search.selectSource(index);
      return;
    }
    if (_scroll.hasClients) _offsets[search.selectedIndex] = _scroll.offset;
    search.selectSource(index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients && search.selectedIndex == index) {
        _scroll.jumpTo(
          (_offsets[index] ?? 0).clamp(0, _scroll.position.maxScrollExtent),
        );
        _nearBottom();
      }
    });
  }

  void _submit(String value) {
    final query = value.trim();
    if (query.isEmpty || _search == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _offsets.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_remember(query));
    unawaited(_search!.start(query));
  }

  Future<void> _open(DiscoverBook book) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final sync = await ref.read(syncRepositoryProvider.future);
      final entry = book.toShelfBook();
      final favorite =
          (await sync.record(
            entry.id,
            'favorite',
          ))?.effective.payload['active'] ==
          true;
      if (!mounted) return;
      await context.push(
        '/reader',
        extra: ReaderOpenRequest(book.toShelfBook(favorite: favorite)),
      );
    } catch (_) {
      if (mounted) _notice('打开书籍失败，请重试。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _search?.removeListener(_changed);
    _search?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Retain the HTTP/cache owner for the lifetime of search and reader re-entry.
    ref.watch(readerRepositoryProvider);
    final search = _search;
    final state = search?.selected;
    final colors = Theme.of(context).colorScheme;
    return PageWidth(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 8, 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回发现',
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 21),
                ),
                Expanded(
                  child: DiscoverSearchField(
                    controller: _input,
                    hint: '搜索书名、作者或关键词',
                    onSubmitted: _submit,
                  ),
                ),
                TextButton(
                  onPressed: search == null ? null : () => _submit(_input.text),
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          if (search != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '已搜索 ${search.completed}/${search.sources.length} 个书源 · 已加载 ${search.totalResults} 条结果',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            SizedBox(
              height: 54,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                itemCount: search.sources.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, index) {
                  final source = search.sources[index];
                  final suffix = !source.started || source.loading
                      ? '…'
                      : source.error != null && source.books.isEmpty
                      ? '失败'
                      : '${source.books.length}';
                  return ChoiceChip(
                    key: ValueKey('normal-source-${source.source.id}'),
                    label: Text('${source.name} $suffix'),
                    selected: search.selectedIndex == index,
                    onSelected: (_) => _select(index),
                  );
                },
              ),
            ),
          ],
          if (_opening) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: search == null
                ? Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
                        : TextButton(
                            onPressed: _initialize,
                            child: Text(_error!),
                          ),
                  )
                : CustomScrollView(
                    controller: _scroll,
                    key: const PageStorageKey('normal-search-results'),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                        sliver: SliverList.builder(
                          itemCount: state!.books.length,
                          itemBuilder: (_, index) {
                            final book = state.books[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Material(
                                color: colors.surface,
                                borderRadius: BorderRadius.circular(18),
                                clipBehavior: Clip.antiAlias,
                                child: ListTile(
                                  key: ValueKey('${book.sourceId}:${book.url}'),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 12,
                                  ),
                                  title: Text(
                                    book.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  subtitle: book.author.isEmpty
                                      ? null
                                      : Text(book.author),
                                  trailing: const Icon(
                                    Icons.chevron_right_rounded,
                                    size: 21,
                                  ),
                                  onTap: _opening ? null : () => _open(book),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: !state.started || state.loading
                                ? const CircularProgressIndicator()
                                : state.error != null
                                ? Column(
                                    children: [
                                      Text(
                                        state.error!,
                                        textAlign: TextAlign.center,
                                      ),
                                      if (state.visited.isEmpty ||
                                          state.nextUrl != null)
                                        TextButton(
                                          onPressed: search.loadMore,
                                          child: const Text('重试此书源'),
                                        ),
                                    ],
                                  )
                                : Text(
                                    state.books.isEmpty
                                        ? '此书源没有找到相关小说'
                                        : state.nextUrl == null
                                        ? '此书源结果已全部展示'
                                        : '继续向下滚动加载',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
