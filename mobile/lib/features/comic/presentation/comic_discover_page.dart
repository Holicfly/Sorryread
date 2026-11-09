import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../design_system/components.dart';
import '../../discover/data/yeshe_index.dart';
import '../../discover/presentation/discover_search_field.dart';
import '../../discover/presentation/yeshe_index_panel.dart';
import '../../reader/data/reader_source.dart';
import '../../reader/presentation/reader_page.dart';
import '../data/yeshe_comic.dart';
import 'comic_cover.dart';

const _categories = {4: '全部', 19: '韩国', 20: '日本', 21: '3D'};

class ComicDiscoverPage extends ConsumerStatefulWidget {
  const ComicDiscoverPage({
    super.key,
    required this.heading,
    required this.tabs,
  });
  final Widget heading, tabs;

  @override
  ConsumerState<ComicDiscoverPage> createState() => _ComicDiscoverPageState();
}

class _ComicDiscoverPageState extends ConsumerState<ComicDiscoverPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _books = <ComicBook>[];
  final _seen = <String>{};
  late final YesheIndexController _index;
  int _category = 4, _page = 1, _offset = 0, _generation = 0, _revision = 0;
  String? _query, _error;
  bool _loading = false, _hasMore = true;

  @override
  void initState() {
    super.initState();
    _index = YesheIndexController(ref.read(comicIndexProvider))
      ..addListener(_indexChanged)
      ..initialize();
    _scroll.addListener(_loadNearEnd);
    unawaited(_load());
  }

  void _indexChanged() {
    final state = _index.state;
    if (!state.complete || state.number('updated') == _revision) return;
    _revision = state.number('updated');
    if (_query != null) _reset(_query, _category);
  }

  void _loadNearEnd() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 320 &&
        _error == null) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (_loading || !_hasMore) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final batch = await ref
          .read(comicCatalogProvider)
          .load(_category, query: _query, page: _page, offset: _offset);
      if (!mounted || generation != _generation) return;
      setState(() {
        _books.addAll(batch.books.where((book) => _seen.add(book.url)));
        _page++;
        _offset += batch.books.length;
        _hasMore = batch.hasMore;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadNearEnd();
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error is PlatformException
            ? error.message ?? '加载失败'
            : '漫画列表加载失败';
        _loading = false;
      });
    }
  }

  void _reset(String? query, int category) {
    setState(() {
      _generation++;
      _query = query;
      _category = category;
      _page = 1;
      _offset = 0;
      _books.clear();
      _seen.clear();
      _loading = false;
      _hasMore = true;
      _error = null;
    });
    unawaited(_load());
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _submit(String input) {
    final value = input.trim();
    if (value.isEmpty) {
      if (_query != null) _reset(null, _category);
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (!RegExp(
      r'^(https?://|yeshezy1\.com/)',
      caseSensitive: false,
    ).hasMatch(value)) {
      _reset(value, _category);
      return;
    }
    try {
      final link = parseComicLink(
        value.contains('://') ? value : 'https://$value',
      );
      if (link.chapter == null) {
        context.push('/comic', extra: link.detail);
      } else {
        context.push(
          '/reader',
          extra: ReaderOpenRequest(
            ComicBook('夜社漫画', link.detail).toShelfBook(),
            chapterUrl: link.chapter,
          ),
        );
      }
    } on ReaderFailure catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  void dispose() {
    _index.dispose();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PageWidth(
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.listInset,
            ),
            sliver: SliverList.list(
              children: [
                widget.heading,
                const SizedBox(height: 12),
                DiscoverSearchField(
                  controller: _input,
                  hint: '搜索本地漫画名或粘贴网址',
                  onSubmitted: _submit,
                  onCleared: () {
                    if (_query != null) _reset(null, _category);
                  },
                ),
                widget.tabs,
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 2, 0),
                  child: ListenableBuilder(
                    listenable: _index,
                    builder: (context, _) =>
                        YesheIndexPanel(controller: _index),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                  child: Row(
                    children: [
                      for (final entry in _categories.entries)
                        Expanded(
                          child: PageTextTab(
                            label: entry.value,
                            selected: _category == entry.key,
                            compact: true,
                            onTap: () {
                              if (_category != entry.key) {
                                _reset(_query, entry.key);
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.listInset + 10,
            ),
            sliver: SliverList.builder(
              itemCount: (_books.length + 2) ~/ 3,
              itemBuilder: (context, row) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var col = 0; col < 3; col++) ...[
                      if (col > 0) const SizedBox(width: 10),
                      Expanded(
                        child: row * 3 + col >= _books.length
                            ? const SizedBox.shrink()
                            : _tile(_books[row * 3 + col], theme),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                24 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Center(
                child: switch ((_loading, _error)) {
                  (true, _) => const CircularProgressIndicator(),
                  (_, final String message) => Column(
                    children: [
                      Text(message, textAlign: TextAlign.center),
                      TextButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                  _ when _books.isEmpty => ListenableBuilder(
                    listenable: _index,
                    builder: (_, _) => Text(
                      _query != null &&
                              _index.state.count == 0 &&
                              !_index.state.complete
                          ? '先缓存漫画目录，再按漫画名搜索'
                          : '没有找到相关漫画',
                    ),
                  ),
                  _ => const SizedBox.shrink(),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(ComicBook book, ThemeData theme) => Semantics(
    button: true,
    child: InkWell(
      key: ValueKey(book.url),
      borderRadius: BorderRadius.circular(10),
      onTap: () => context.push('/comic', extra: book.url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ComicCover(url: book.cover),
          const SizedBox(height: 6),
          Text(
            book.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}
