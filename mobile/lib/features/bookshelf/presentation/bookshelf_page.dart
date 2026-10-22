import 'package:flutter/material.dart';

import '../../../design_system/components.dart';
import '../../sync/presentation/sync_placeholder_card.dart';
import 'demo_books.dart';

class BookshelfPage extends StatelessWidget {
  const BookshelfPage({super.key});

  @override
  Widget build(BuildContext context) => PageWidth(
    child: CustomScrollView(
      key: const PageStorageKey('bookshelf-scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          sliver: SliverList.list(
            children: [
              const PageHeading('我的书架'),
              const Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _FilterPlaceholder(label: '全部', detail: '9', selected: true),
                  _FilterPlaceholder(label: '最近阅读', detail: '—'),
                ],
              ),
              const SizedBox(height: 20),
              const SyncPlaceholderCard(),
              const SizedBox(height: 22),
              Row(
                children: [
                  Text('书架一览', style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  const PlaceholderBadge(label: '示例书籍'),
                ],
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.crossAxisExtent - 28) / 3;
              final scaler = MediaQuery.textScalerOf(context);
              final textHeight =
                  scaler.scale(15) * 1.5 + scaler.scale(12) * 1.5;
              return SliverGrid.builder(
                itemCount: demoBooks.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 20,
                  mainAxisExtent: width / 0.7 + textHeight + 16,
                ),
                itemBuilder: (context, index) =>
                    _BookPlaceholder(book: demoBooks[index]),
              );
            },
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          sliver: SliverToBoxAdapter(
            child: Text(
              '封面与书名仅用于布局展示，阅读数据尚未接入。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    ),
  );
}

class _FilterPlaceholder extends StatelessWidget {
  const _FilterPlaceholder({
    required this.label,
    required this.detail,
    this.selected = false,
  });
  final String label;
  final String detail;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '$label，筛选占位，暂不可用',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? colors.primaryContainer : colors.surface,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Text(
            '$label  $detail',
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _BookPlaceholder extends StatelessWidget {
  const _BookPlaceholder({required this.book});
  final DemoBook book;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${book.title}，${book.author}，示例书籍，暂不可阅读',
    child: ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 0.7,
            child: Container(
              decoration: BoxDecoration(
                color: book.cover,
                borderRadius: BorderRadius.circular(12),
                border: Border(
                  left: BorderSide(
                    color: book.ink.withValues(alpha: 0.14),
                    width: 5,
                  ),
                ),
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '素若 · 阅读',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: book.ink.withValues(alpha: 0.65),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        book.title,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 20,
                          height: 1.45,
                          fontWeight: FontWeight.w500,
                          color: book.ink,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    '封面占位',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: book.ink.withValues(alpha: 0.6),
                    ),
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
            book.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
