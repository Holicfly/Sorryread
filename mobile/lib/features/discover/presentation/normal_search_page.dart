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
import 'search_results_surface.dart';
import 'normal_source_tabs.dart';
import 'normal_search_results.dart';

class NormalSearchPage extends ConsumerStatefulWidget {
  const NormalSearchPage({super.key, required this.query});
  final String query;
  @override
  ConsumerState<NormalSearchPage> createState() => _NormalSearchPageState();
}

class _NormalSearchPageState extends ConsumerState<NormalSearchPage>
    with SingleTickerProviderStateMixin {
  late final _input = TextEditingController(text: widget.query);
  final _scrolls = <ScrollController>[];
  TabController? _tabs;
  final _epoch = ValueNotifier<int>(0);
  final _summary = ValueNotifier<(int, int)>((0, 0));
  final _opening = ValueNotifier<bool>(false);
  List<Widget> _pages = const [];
  NormalSearchController? _search;
  String? _error;
  bool _paging = false;

  @override
  void initState() {
    super.initState();
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
      _tabs = TabController(length: controller.sources.length, vsync: this)
        ..addListener(_tabChanged);
      for (var index = 0; index < controller.sources.length; index++) {
        _scrolls.add(
          ScrollController(
            onAttach: (_) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _nearBottom(index);
              });
            },
          )..addListener(() => _nearBottom(index)),
        );
      }
      _pages = [
        for (var index = 0; index < controller.sources.length; index++)
          NormalSearchResults(
            source: controller.sources[index],
            index: index,
            scroll: _scrolls[index],
            epoch: _epoch,
            opening: _opening,
            onOpen: _open,
            onRetry: () => unawaited(controller.loadMore()),
          ),
      ];
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
    final search = _search;
    if (search == null) return;
    _summary.value = (search.completed, search.totalResults);
    if (_tabs!.index != search.selectedIndex) {
      _tabs!.animateTo(search.selectedIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nearBottom(search.selectedIndex);
    });
  }

  void _nearBottom(int index) {
    final search = _search;
    final scroll = _scrolls[index];
    if (!mounted ||
        search == null ||
        _opening.value ||
        _paging ||
        !scroll.hasClients ||
        search.selectedIndex != index) {
      return;
    }
    final state = search.selected;
    if (state.started &&
        !state.loading &&
        state.error == null &&
        state.nextUrl != null &&
        scroll.position.extentAfter < 240) {
      unawaited(search.loadMore());
    }
  }

  void _tabChanged() {
    if (!_tabs!.indexIsChanging) {
      if (_tabs!.index != _search!.selectedIndex) {
        _search!.selectSource(_tabs!.index);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nearBottom(_search!.selectedIndex);
      });
    }
  }

  void _submit(String value) {
    final query = value.trim();
    if (query.isEmpty || _search == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _epoch.value++;
    for (final scroll in _scrolls) {
      if (scroll.hasClients) scroll.jumpTo(0);
    }
    unawaited(_remember(query));
    unawaited(_search!.start(query));
  }

  Future<void> _open(DiscoverBook book) async {
    if (_opening.value) return;
    _opening.value = true;
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
      if (mounted) _opening.value = false;
    }
  }

  @override
  void dispose() {
    _search?.removeListener(_changed);
    _search?.dispose();
    _input.dispose();
    _tabs?.dispose();
    _epoch.dispose();
    _summary.dispose();
    _opening.dispose();
    for (final scroll in _scrolls) {
      scroll.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Retain the HTTP/cache owner for the lifetime of search and reader re-entry.
    ref.watch(readerRepositoryProvider);
    final search = _search;
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
                child: ValueListenableBuilder<(int, int)>(
                  valueListenable: _summary,
                  builder: (context, summary, _) => Text(
                    '已搜索 ${summary.$1}/${search.sources.length} 个书源 · 已加载 ${summary.$2} 条结果',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
            NormalSourceTabs(
              key: const Key('normal-source-tabs'),
              controller: _tabs!,
              sources: search.sources,
              onSelected: (index) {
                search.selectSource(index);
                if (_tabs!.index != index) _tabs!.animateTo(index);
              },
            ),
          ],
          ValueListenableBuilder<bool>(
            valueListenable: _opening,
            builder: (context, opening, _) => opening
                ? const LinearProgressIndicator(minHeight: 2)
                : const SizedBox.shrink(),
          ),
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
                : SearchResultsSurface(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification.metrics.axis != Axis.horizontal) {
                          return false;
                        }
                        if (notification is ScrollStartNotification) {
                          _paging = true;
                          if (notification.dragDetails != null) {
                            // Claim a manual choice without notifying/rebuilding the page.
                            search.selectSource(_tabs!.index);
                          }
                        } else if (notification is ScrollEndNotification) {
                          _paging = false;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _nearBottom(search.selectedIndex);
                          });
                        }
                        return false;
                      },
                      child: TabBarView(
                        key: const Key('normal-results-pager'),
                        controller: _tabs,
                        children: _pages,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
