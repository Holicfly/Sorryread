import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../data/sync_repository.dart';
import '../../../design_system/components.dart';
import '../../sync/presentation/sync_status_card.dart';

class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});
  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  bool recentOnly = false;
  @override
  Widget build(BuildContext context) {
    final data = ref.watch(shelfBooksProvider);
    final books = data.asData?.value ?? <ShelfBook>[];
    final recent = books.where((b) => b.recent).take(10).toList();
    final shown = recentOnly ? recent : books;
    return PageWidth(
      child: CustomScrollView(
        key: const PageStorageKey('bookshelf-scroll'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            sliver: SliverList.list(
              children: [
                const PageHeading('我的书架'),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ChoiceChip(
                      label: Text('全部  ${books.length}'),
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
                  recentOnly ? '最近阅读' : '书架一览',
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
                        recentOnly ? '暂无最近阅读' : '书架暂无书籍',
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
                        width / .7 +
                        scaler.scale(15) * 1.5 +
                        scaler.scale(12) * 1.5 +
                        16,
                  ),
                  itemBuilder: (context, index) => _BookCard(
                    book: shown[index],
                    onTap: () => _showBook(shown[index]),
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
                      : '上次位置：${book.metadata['chapterTitle'] == '' ? '尚无章节信息' : book.metadata['chapterTitle']} · ${(book.progress * 100).round()}%',
                ),
                const SizedBox(height: 8),
                const Text('阅读功能暂未开放。'),
                const SizedBox(height: 20),
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
  const _BookCard({required this.book, required this.onTap});
  final ShelfBook book;
  final VoidCallback onTap;
  static const colors = [
    Color(0xFFDCE3CE),
    Color(0xFFD5E4E8),
    Color(0xFFEAC5A1),
    Color(0xFFE3D9C3),
    Color(0xFFBCD0C7),
    Color(0xFFD9D2E2),
  ];
  @override
  Widget build(BuildContext context) {
    final hash = book.id.codeUnits.fold<int>(
      0,
      (a, b) => (a * 31 + b) & 0x7fffffff,
    );
    const ink = Color(0xFF34473B);
    return Semantics(
      label: '${book.title}，${book.favorite ? '已收藏' : '最近阅读'}',
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: .7,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors[hash % colors.length],
                  borderRadius: BorderRadius.circular(12),
                  border: Border(
                    left: BorderSide(
                      color: ink.withValues(alpha: .14),
                      width: 5,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '素若 · 阅读',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 9, color: ink),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          book.title,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 20,
                            height: 1.45,
                            color: ink,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      book.conflicted
                          ? '进度待选择'
                          : '${(book.progress * 100).round()}%',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: ink),
                    ),
                  ],
                ),
              ),
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
