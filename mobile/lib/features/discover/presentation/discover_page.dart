import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dependencies.dart';
import '../../../design_system/components.dart';
import '../../reader/data/reader_source.dart';
import '../../reader/presentation/reader_page.dart';
import '../../local_books/local_book_parser.dart';
import '../../sync/application/sync_controller.dart';
import '../data/discover_repository.dart';
import '../data/yeshe_index.dart';
import 'yeshe_index_panel.dart';
import 'search_results_surface.dart';

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
  bool _yeshe = false;
  bool _importing = false;

  DiscoverMode get mode => _special ? DiscoverMode.mh : DiscoverMode.normal;

  void _tapHeading() {
    final now = _clock.elapsedMilliseconds;
    _taps = _lastTap >= 0 && now - _lastTap <= 800 ? _taps + 1 : 1;
    _lastTap = now;
    if (_taps != 5) return;
    setState(() {
      _taps = 0;
      _special = !_special;
      _yeshe = false;
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

  Widget _heading() => PageHeader(
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: GestureDetector(
              key: const Key('discover-heading'),
              behavior: HitTestBehavior.opaque,
              onTap: _tapHeading,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: PageHeader.textPadding,
                ),
                child: Text('发现', style: PageHeader.titleStyle(context)),
              ),
            ),
          ),
        ),
        Tooltip(
          message: '导入图书',
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextButton.icon(
              key: const Key('discover-import-books'),
              onPressed: _importing ? null : _importBooks,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                minimumSize: const Size(48, 44),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: Image.asset(
                'assets/reader_icons/import_book.png',
                width: 21,
                height: 21,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              label: Text(_importing ? '导入中' : '导入图书'),
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _importBooks() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _importing = true);
    try {
      final choices =
          await bookPicker.invokeListMethod<dynamic>('choose') ?? [];
      if (choices.isEmpty || !mounted) return;
      final store = (await ref.read(syncRepositoryProvider.future))
          .importedBooks;
      if (store == null || !mounted) return;
      final peer = await ref.read(peerStorageProvider).read();
      final failures = <String>[];
      var success = 0;
      for (final value in choices) {
        final item = Map<String, dynamic>.from(value as Map);
        final name = item['name'] as String;
        final path = item['path'] as String?;
        if (path == null) {
          failures.add('$name · ${item['error']}');
          continue;
        }
        final file = File(path);
        try {
          await store.importFile(file, name, server: peer?.serverId);
          success++;
        } catch (error) {
          final reason = error is FormatException ? error.message : '无法读取该文件';
          failures.add('$name · $reason');
        } finally {
          if (await file.exists()) await file.delete();
        }
      }
      if (mounted) {
        _notice(
          context,
          failures.isEmpty
              ? '已处理 $success 本图书，可在书架查看'
              : '成功 $success 本，失败 ${failures.length} 本。 ${failures.first}',
        );
      }
    } catch (_) {
      if (mounted) _notice(context, '图书导入失败，请重试');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _selectSpecialTab(bool yeshe) {
    if (_yeshe == yeshe) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _yeshe = yeshe);
  }

  Widget _tabs() => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
    child: Row(
      children: [
        PageTextTab(
          label: '18c',
          selected: !_yeshe,
          onTap: () => _selectSpecialTab(false),
        ),
        const SizedBox(width: 20),
        PageTextTab(
          label: 'YS1',
          selected: _yeshe,
          onTap: () => _selectSpecialTab(true),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_yeshe) {
      return DiscoverResultsPage.yesheTab(heading: _heading(), tabs: _tabs());
    }
    return PageWidth(
      child: CustomScrollView(
        key: const PageStorageKey('discover-scroll'),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.listInset,
              0,
              AppSpacing.listInset,
              24 + MediaQuery.paddingOf(context).bottom,
            ),
            sliver: SliverList.list(
              children: [
                _heading(),
                const SizedBox(height: 12),
                DiscoverSearchField(
                  controller: _input,
                  hint: '搜索书名、作者或关键词',
                  onSubmitted: _search,
                ),
                if (_special) _tabs() else const SizedBox(height: 20),
                DiscoverHistorySection(
                  key: ValueKey(mode),
                  mode: mode,
                  onSelected: _search,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DiscoverSearchField extends StatelessWidget {
  const DiscoverSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSubmitted,
    this.enabled = true,
    this.onCleared,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSubmitted;
  final bool enabled;
  final VoidCallback? onCleared;

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
          onPressed: () {
            controller.clear();
            onCleared?.call();
          },
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

class DiscoverHistorySection extends ConsumerStatefulWidget {
  const DiscoverHistorySection({
    super.key,
    required this.mode,
    required this.onSelected,
  });
  final DiscoverMode mode;
  final ValueChanged<String> onSelected;

  @override
  ConsumerState<DiscoverHistorySection> createState() =>
      _DiscoverHistorySectionState();
}

class _DiscoverHistorySectionState
    extends ConsumerState<DiscoverHistorySection> {
  bool _editing = false;
  bool _saving = false;

  Future<void> _delete([String? value]) async {
    if (_saving) return;
    final mode = widget.mode;
    final providers = ProviderScope.containerOf(context, listen: false);
    setState(() => _saving = true);
    try {
      final history = await ref.read(discoverHistoryProvider.future);
      if (value == null) {
        await history.clear(mode);
      } else {
        await history.remove(mode, value);
      }
      providers.invalidate(discoverHistoryEntriesProvider(mode));
    } catch (_) {
      if (mounted) _notice(context, '搜索记录保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = discoverHistoryEntriesProvider(widget.mode);
    final history = ref.watch(entries);
    final values = history.value ?? const <String>[];
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final actionStyle = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: const Size(0, 44),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('搜索记录', style: theme.textTheme.titleMedium)),
            if (_editing) ...[
              TextButton(
                style: actionStyle,
                onPressed: _saving || values.isEmpty ? null : () => _delete(),
                child: const Text('全部删除'),
              ),
              Text('｜', style: theme.textTheme.bodySmall),
              TextButton(
                style: actionStyle,
                onPressed: _saving
                    ? null
                    : () => setState(() => _editing = false),
                child: const Text('完成'),
              ),
            ] else
              IconButton(
                tooltip: '管理搜索记录',
                onPressed: values.isEmpty
                    ? null
                    : () => setState(() => _editing = true),
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
              ),
          ],
        ),
        if (history.hasError)
          TextButton(
            onPressed: () => ref.invalidate(entries),
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
                onPressed: _editing ? null : () => widget.onSelected(value),
                onDeleted: _editing ? () => _delete(value) : null,
                deleteButtonTooltipMessage: '删除这条记录',
                side: BorderSide.none,
                backgroundColor: colors.primary.withValues(alpha: .06),
                shape: const StadiumBorder(),
              ),
          ],
        ),
      ],
    );
  }
}

class DiscoverResultsPage extends ConsumerStatefulWidget {
  const DiscoverResultsPage({super.key, required this.mode, this.query = ''})
    : tabHeader = null;
  const DiscoverResultsPage.yesheTab({
    super.key,
    required Widget heading,
    required Widget tabs,
  }) : mode = DiscoverMode.yeshe,
       query = '',
       tabHeader = (heading: heading, tabs: tabs);

  final DiscoverMode mode;
  final String query;
  final ({Widget heading, Widget tabs})? tabHeader;
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

  void _clearYesheSearch() {
    if (_index?.query == null) return;
    _index!.browse();
    if (_scroll.hasClients) _scroll.jumpTo(0);
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

  Widget? _resultStatus(DiscoverResults? results, bool local) {
    if (local) {
      final index = _index!;
      if (index.loading) return const CircularProgressIndicator();
      if (index.error != null) {
        return TextButton(
          onPressed: () => index.search(index.query!),
          child: Text(index.error!),
        );
      }
      return index.books.isEmpty
          ? Text(index.state.count == 0 ? '请先缓存书目，再搜索书名' : '已缓存书目中没有找到相关小说')
          : null;
    }
    if (_initialError != null) {
      return TextButton(onPressed: _initialize, child: Text(_initialError!));
    }
    if (results == null || results.loading) {
      return const CircularProgressIndicator();
    }
    if (results.error != null) {
      return Column(
        children: [
          Text(results.error!, textAlign: TextAlign.center),
          if (results.nextUrl != null)
            TextButton(onPressed: results.loadMore, child: const Text('重试')),
        ],
      );
    }
    if (results.books.isEmpty) return const Text('没有找到相关小说');
    if (night) return null;
    return Text(
      results.nextUrl == null ? '已展示全部结果' : '继续向下滚动加载',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final local = _index?.query != null;
    final shown = local ? _index!.books : (results?.books ?? <DiscoverBook>[]);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final header = widget.tabHeader;
    final status = _resultStatus(results, local);
    final search = DiscoverSearchField(
      controller: _input,
      hint: night ? '搜索本地书名或粘贴网址' : '搜索书名、作者或关键词',
      onSubmitted: _submit,
      onCleared: night ? _clearYesheSearch : null,
      enabled: !_opening,
    );
    final slivers = <Widget>[
      if (night && _index != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: YesheIndexPanel(controller: _index!),
          ),
        ),
      if (!night)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '全部',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  results?.total == null
                      ? '已加载 ${results?.books.length ?? 0} 本'
                      : '共找到 ${results!.total} 本 · 已加载 ${results.books.length} 本',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      SliverList.separated(
        separatorBuilder: (_, _) => const SearchResultDivider(),
        itemCount: shown.length,
        itemBuilder: (context, index) {
          final book = shown[index];
          return ListTile(
            key: ValueKey(book.url),
            contentPadding: EdgeInsets.symmetric(
              horizontal: 18,
              vertical: night ? 2 : 10,
            ),
            title: Text(book.title, style: theme.textTheme.titleMedium),
            trailing: const Icon(Icons.chevron_right_rounded, size: 21),
            onTap: _opening ? null : () => _open(book),
          );
        },
      ),
      if (status != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: status),
          ),
        ),
    ];

    if (header != null) {
      return PageWidth(
        child: CustomScrollView(
          key: const PageStorageKey('yeshe-tab-scroll'),
          controller: _scroll,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.listInset,
              ),
              sliver: SliverList.list(
                children: [
                  header.heading,
                  const SizedBox(height: 12),
                  search,
                  header.tabs,
                  if (_opening) const LinearProgressIndicator(minHeight: 2),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.listInset,
              ),
              sliver: DecoratedSliver(
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(AppSpacing.radius),
                ),
                sliver: SliverMainAxisGroup(slivers: slivers),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 24 + MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      );
    }
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
                Expanded(child: search),
                TextButton(
                  onPressed: _opening ? null : _submit,
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          if (_opening) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: SearchResultsSurface(
              child: CustomScrollView(
                key: const PageStorageKey('discover-results-scroll'),
                controller: _scroll,
                slivers: [
                  ...slivers,
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 24 + SearchResultsSurface.bottomInset(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
