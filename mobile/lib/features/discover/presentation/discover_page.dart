import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dependencies.dart';
import '../../../design_system/components.dart';
import '../../reader/data/reader_source.dart';
import '../../reader/presentation/reader_page.dart';
import '../data/discover_repository.dart';
import '../data/yeshe_index.dart';
import 'yeshe_index_panel.dart';

void _notice(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<void> _remember(WidgetRef ref, DiscoverMode mode, String value) async {
  final history = await ref.read(discoverHistoryProvider.future);
  await history.add(mode, value);
  ref.invalidate(discoverHistoryEntriesProvider(mode));
}

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});
  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  final _input = TextEditingController();
  final _clock = Stopwatch()..start();
  int _taps = 0, _lastTap = -1;
  bool _special = false;

  DiscoverMode get mode => _special ? DiscoverMode.mh : DiscoverMode.normal;

  void _tapHeading() {
    final now = _clock.elapsedMilliseconds;
    _taps = _lastTap >= 0 && now - _lastTap <= 800 ? _taps + 1 : 1;
    _lastTap = now;
    if (_taps != 5) return;
    setState(() {
      _taps = 0;
      _special = !_special;
      _input.clear();
    });
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _search([String? value]) {
    final query = (value ?? _input.text).trim();
    if (query.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    context.push(
      Uri(
        path: '/discover/results',
        queryParameters: {'mode': mode.id, 'q': query},
      ).toString(),
    );
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageWidth(
    child: CustomScrollView(
      key: const PageStorageKey('discover-scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          sliver: SliverList.list(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Semantics(
                  header: true,
                  child: GestureDetector(
                    key: const Key('discover-heading'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _tapHeading,
                    child: const PageHeading('发现'),
                  ),
                ),
              ),
              Text(
                _special ? '快捷进入你常用的分类' : '搜索你想看的小说',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              DiscoverSearchField(
                controller: _input,
                hint: '搜索书名、作者或关键词',
                onSubmitted: _search,
              ),
              const SizedBox(height: 28),
              if (_special) ...[const _YesheCard(), const SizedBox(height: 28)],
              DiscoverHistorySection(
                mode: mode,
                chips: _special,
                onSelected: _search,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class DiscoverSearchField extends StatelessWidget {
  const DiscoverSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSubmitted,
    this.enabled = true,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSubmitted;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextField(
      key: const Key('discover-search-input'),
      controller: controller,
      enabled: enabled,
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: colors.onSurfaceVariant, fontSize: 14),
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: IconButton(
          tooltip: '清空输入',
          onPressed: controller.clear,
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
        filled: true,
        fillColor: colors.onSurface.withValues(alpha: .045),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(32),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 15,
        ),
      ),
    );
  }
}

class DiscoverHistorySection extends ConsumerWidget {
  const DiscoverHistorySection({
    super.key,
    required this.mode,
    required this.onSelected,
    this.chips = false,
  });
  final DiscoverMode mode;
  final ValueChanged<String> onSelected;
  final bool chips;

  Future<void> _edit(BuildContext context, WidgetRef ref, String? value) async {
    try {
      final history = await ref.read(discoverHistoryProvider.future);
      if (value == null) {
        await history.clear(mode);
      } else {
        await history.remove(mode, value);
      }
      ref.invalidate(discoverHistoryEntriesProvider(mode));
    } catch (_) {
      if (context.mounted) _notice(context, '搜索记录保存失败，请重试。');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(discoverHistoryEntriesProvider(mode));
    final values = history.asData?.value ?? <String>[];
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                chips ? '最近搜索' : '搜索记录',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: values.isEmpty
                  ? null
                  : () => _edit(context, ref, null),
              icon: const Icon(Icons.delete_outline_rounded, size: 17),
              label: const Text('清空'),
            ),
          ],
        ),
        if (history.hasError)
          TextButton(
            onPressed: () =>
                ref.invalidate(discoverHistoryEntriesProvider(mode)),
            child: const Text('记录加载失败，点击重试'),
          )
        else if (values.isEmpty && !history.isLoading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '暂无搜索记录',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
        if (chips)
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: [
              for (final value in values)
                InputChip(
                  avatar: const Icon(Icons.history_rounded, size: 18),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onPressed: () => onSelected(value),
                  onDeleted: () => _edit(context, ref, value),
                  deleteButtonTooltipMessage: '删除这条记录',
                  side: BorderSide.none,
                  backgroundColor: colors.primary.withValues(alpha: .06),
                  shape: const StadiumBorder(),
                ),
            ],
          )
        else
          for (final value in values)
            Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history_rounded, size: 21),
                  title: Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: '删除这条记录',
                    icon: const Icon(Icons.close_rounded, size: 17),
                    onPressed: () => _edit(context, ref, value),
                  ),
                  onTap: () => onSelected(value),
                ),
                Divider(height: 1, color: colors.outlineVariant),
              ],
            ),
      ],
    );
  }
}

class _YesheCard extends StatelessWidget {
  const _YesheCard();
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.primaryContainer,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('yeshe-entry'),
        onTap: () => context.push('/discover/results?mode=yeshe'),
        child: CustomPaint(
          painter: _Landscape(colors.primary),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 32),
            child: Row(
              children: [
                Icon(
                  Icons.nights_stay_outlined,
                  color: colors.primary,
                  size: 46,
                ),
                const SizedBox(width: 22),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '夜社',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text('点击直接查看结果'),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: colors.primary,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Landscape extends CustomPainter {
  const _Landscape(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < 3; i++) {
      final y = size.height * (.65 + i * .1);
      final path = Path()..moveTo(0, y);
      path.quadraticBezierTo(size.width * .25, y - 40, size.width * .5, y + 8);
      path.quadraticBezierTo(size.width * .8, y - 55, size.width, y - 14);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = color.withValues(alpha: .035 + i * .025),
      );
    }
  }

  @override
  bool shouldRepaint(_Landscape oldDelegate) => color != oldDelegate.color;
}

class DiscoverResultsPage extends ConsumerStatefulWidget {
  const DiscoverResultsPage({super.key, required this.mode, this.query = ''});
  final DiscoverMode mode;
  final String query;
  @override
  ConsumerState<DiscoverResultsPage> createState() =>
      _DiscoverResultsPageState();
}

class _DiscoverResultsPageState extends ConsumerState<DiscoverResultsPage> {
  late final _input = TextEditingController(text: widget.query);
  final _scroll = ScrollController();
  DiscoverResults? _results;
  YesheIndexController? _index;
  String? _initialError;
  bool _opening = false;
  bool get night => widget.mode == DiscoverMode.yeshe;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_nearBottom);
    if (night) {
      _index = YesheIndexController(ref.read(yesheIndexRepositoryProvider))
        ..addListener(_changed)
        ..initialize();
    }
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final repository = await ref.read(discoverRepositoryProvider.future);
      if (!mounted) return;
      final results = DiscoverResults(repository)..addListener(_changed);
      setState(() {
        _results = results;
        _initialError = null;
      });
      if (!night) unawaited(_saveHistory(widget.query));
      await results.start(widget.mode, widget.query);
    } catch (_) {
      if (mounted) setState(() => _initialError = '搜索服务初始化失败，请重试。');
    }
  }

  Future<void> _saveHistory(String value) async {
    try {
      await _remember(ref, widget.mode, value);
    } catch (_) {
      if (mounted) _notice(context, '本次搜索记录未能保存。');
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _nearBottom());
  }

  void _nearBottom() {
    if (_index?.query != null) {
      if (mounted &&
          !_opening &&
          _scroll.hasClients &&
          _scroll.position.extentAfter < 240 &&
          _index!.error == null) {
        unawaited(_index!.loadMore());
      }
      return;
    }
    final results = _results;
    if (!mounted ||
        results == null ||
        results.error != null ||
        _opening ||
        !_scroll.hasClients) {
      return;
    }
    if (_scroll.position.extentAfter < 240) unawaited(results.loadMore());
  }

  Future<void> _open(DiscoverBook book, {String? chapterUrl}) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final sync = await ref.read(syncRepositoryProvider.future);
      final shelf = book.toShelfBook();
      final favorite =
          (await sync.record(
            shelf.id,
            'favorite',
          ))?.effective.payload['active'] ==
          true;
      if (!mounted) return;
      await context.push(
        '/reader',
        extra: ReaderOpenRequest(
          book.toShelfBook(favorite: favorite),
          chapterUrl: chapterUrl,
        ),
      );
    } catch (_) {
      if (mounted) _notice(context, '打开书籍失败，请重试。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _submit([String? value]) async {
    if (_opening) return;
    final query = (value ?? _input.text).trim();
    FocusManager.instance.primaryFocus?.unfocus();
    if (!night) {
      if (query.isEmpty) return;
      _input.text = query;
      unawaited(_saveHistory(query));
      if (_scroll.hasClients) _scroll.jumpTo(0);
      await _results?.start(widget.mode, query);
      return;
    }
    if (query.isEmpty) {
      _index?.browse();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      await _results?.start(widget.mode, '');
      return;
    }
    if (!query.contains('://') && !query.startsWith('http')) {
      _input.text = query;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      await _index?.search(query);
      return;
    }
    setState(() => _opening = true);
    try {
      parseYesheInput(query);
      final repository = await ref.read(discoverRepositoryProvider.future);
      final (book, chapter) = await repository.resolveYeshe(query);
      if (!mounted) return;
      await _saveHistory(query);
      if (!mounted) return;
      _input.text = query;
      setState(() => _opening = false);
      await _open(book, chapterUrl: chapter);
    } catch (e) {
      if (mounted) {
        _notice(context, e is ReaderFailure ? e.message : '网址解析失败，请检查网络后重试。');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _index?.removeListener(_changed);
    _index?.dispose();
    _results?.removeListener(_changed);
    _results?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final local = _index?.query != null;
    final shown = local ? _index!.books : (results?.books ?? <DiscoverBook>[]);
    final colors = Theme.of(context).colorScheme;
    final nightHistory = night
        ? ref.watch(discoverHistoryEntriesProvider(widget.mode))
        : null;
    return PageWidth(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 8, 12),
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
                    hint: night ? '搜索本地书名或粘贴网址' : '搜索书名、作者或关键词',
                    onSubmitted: _submit,
                    enabled: !_opening,
                  ),
                ),
                TextButton(
                  onPressed: _opening ? null : _submit,
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          if (_opening) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: CustomScrollView(
              key: const PageStorageKey('discover-results-scroll'),
              controller: _scroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  sliver: SliverList.list(
                    children: [
                      if (night) ...[
                        Text(
                          '夜社结果',
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '浏览小说、搜索本地书目，或粘贴网址阅读',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        if (_index != null)
                          YesheIndexPanel(controller: _index!),
                        if (local) ...[
                          Text(
                            _index!.state.complete
                                ? '本地书名搜索 · 找到 ${_index!.total} 本'
                                : '本地书名搜索 · 找到 ${_index!.total} 本（仅已缓存部分）',
                          ),
                          Wrap(
                            children: [
                              TextButton(
                                onPressed: () => _index!.search(_index!.query!),
                                child: const Text('刷新搜索结果'),
                              ),
                              TextButton(
                                onPressed: () {
                                  _input.clear();
                                  _index!.browse();
                                  if (_scroll.hasClients) _scroll.jumpTo(0);
                                },
                                child: const Text('返回在线浏览'),
                              ),
                            ],
                          ),
                          if (_index!.state.count == 0)
                            const Text('请先缓存书目。缓存开始后即可搜索已下载的书名。'),
                        ],
                        if (nightHistory?.hasError == true ||
                            (nightHistory?.asData?.value.isNotEmpty ?? false))
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('最近解析'),
                            children: [
                              DiscoverHistorySection(
                                mode: widget.mode,
                                chips: true,
                                onSelected: _submit,
                              ),
                            ],
                          ),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Chip(
                          label: const Text('全部'),
                          side: BorderSide.none,
                          backgroundColor: colors.primaryContainer,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        local
                            ? '已显示 ${shown.length}/${_index!.total} 本'
                            : results?.total == null
                            ? '已加载 ${results?.books.length ?? 0} 本'
                            : '共找到 ${results!.total} 本 · 已加载 ${results.books.length} 本',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (results != null || local)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverList.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, index) {
                        final book = shown[index];
                        return Column(
                          children: [
                            ListTile(
                              key: ValueKey(book.url),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 10,
                              ),
                              title: Text(
                                book.title,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              trailing: const Icon(
                                Icons.chevron_right_rounded,
                                size: 21,
                              ),
                              onTap: _opening ? null : () => _open(book),
                            ),
                            Divider(height: 1, color: colors.outlineVariant),
                          ],
                        );
                      },
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: local
                          ? (_index!.loading
                                ? const CircularProgressIndicator()
                                : _index!.error != null
                                ? TextButton(
                                    onPressed: () =>
                                        _index!.search(_index!.query!),
                                    child: Text(_index!.error!),
                                  )
                                : Text(
                                    _index!.books.isEmpty
                                        ? '已缓存书目中没有找到相关小说'
                                        : !_index!.hasMore
                                        ? '本地结果已全部展示'
                                        : '继续向下滚动加载',
                                  ))
                          : _initialError != null
                          ? TextButton(
                              onPressed: _initialize,
                              child: Text(_initialError!),
                            )
                          : results == null || results.loading
                          ? const CircularProgressIndicator()
                          : results.error != null
                          ? Column(
                              children: [
                                Text(
                                  results.error!,
                                  textAlign: TextAlign.center,
                                ),
                                if (results.nextUrl != null)
                                  TextButton(
                                    onPressed: results.loadMore,
                                    child: const Text('重试'),
                                  ),
                              ],
                            )
                          : Text(
                              results.books.isEmpty
                                  ? '没有找到相关小说'
                                  : results.nextUrl == null
                                  ? '已展示全部结果'
                                  : '继续向下滚动加载',
                              style: Theme.of(context).textTheme.bodySmall,
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
