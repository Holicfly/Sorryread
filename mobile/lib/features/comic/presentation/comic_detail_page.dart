import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dependencies.dart';
import '../../../data/sync_repository.dart';
import '../../../design_system/components.dart';
import '../../reader/presentation/reader_page.dart';
import '../data/yeshe_comic.dart';
import 'comic_cover.dart';

final _comicDetail = FutureProvider.autoDispose.family<ComicDetail, String>(
  (ref, url) async =>
      (await ref.watch(comicRepositoryProvider.future)).detail(url),
);

class ComicDetailPage extends ConsumerWidget {
  const ComicDetailPage({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(_comicDetail(url));
    return Scaffold(
      appBar: AppBar(title: const Text('夜社漫画')),
      body: PageWidth(
        child: info.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('漫画详情加载失败'),
                TextButton(
                  onPressed: () => ref.invalidate(_comicDetail(url)),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
          data: (detail) => _DetailContent(detail: detail),
        ),
      ),
    );
  }
}

class _DetailContent extends ConsumerStatefulWidget {
  const _DetailContent({required this.detail});
  final ComicDetail detail;

  @override
  ConsumerState<_DetailContent> createState() => _DetailContentState();
}

class _DetailContentState extends ConsumerState<_DetailContent> {
  bool _saving = false;

  Future<void> _favorite(ShelfBook book, bool active) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final repository = await ref.read(syncRepositoryProvider.future);
      await repository.setFavorite(book, active);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('收藏状态保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final book = detail.book.toShelfBook();
    final current = ref
        .watch(shelfBooksProvider)
        .value
        ?.where((item) => item.id == book.id)
        .firstOrNull;
    final favorite = current?.favorite == true;
    final text = Theme.of(context).textTheme;
    void open([String? chapter]) {
      context.push(
        '/reader',
        extra: ReaderOpenRequest(current ?? book, chapterUrl: chapter),
      );
    }

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 100,
                      child: ComicCover(url: detail.book.cover),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(book.title, style: text.titleLarge),
                          const SizedBox(height: 8),
                          for (final label in detail.labels)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(label, style: text.bodySmall),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: open,
                      icon: const Icon(Icons.auto_stories_outlined),
                      label: Text(current?.position != null ? '继续阅读' : '开始阅读'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _saving
                          ? null
                          : () => _favorite(book, !favorite),
                      icon: Icon(
                        favorite ? Icons.favorite : Icons.favorite_border,
                      ),
                      label: Text(favorite ? '已收藏' : '收藏'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  '章节 · ${detail.chapters.length} 话',
                  style: text.titleMedium,
                ),
              ],
            ),
          ),
        ),
        SliverList.separated(
          itemCount: detail.chapters.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, indent: 20, endIndent: 20),
          itemBuilder: (context, index) {
            final chapter = detail.chapters[index];
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(chapter.title),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => open(chapter.url),
            );
          },
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 12),
        ),
      ],
    );
  }
}
