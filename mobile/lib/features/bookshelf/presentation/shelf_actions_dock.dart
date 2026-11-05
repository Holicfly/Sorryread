import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../data/local_library.dart';
import '../../../data/sync_repository.dart';

final shelfSelectionProvider = NotifierProvider<ShelfSelection, Set<String>>(
  ShelfSelection.new,
);

class ShelfSelection extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String id) {
    final next = Set<String>.of(state);
    if (!next.remove(id)) next.add(id);
    state = Set.unmodifiable(next);
  }

  void clear() => state = const {};
}

String shelfBookProgressLabel(ShelfBook book) {
  final value = book.bookProgress;
  return value == null ? '待读取' : '${(value * 100).floor()}%';
}

class ShelfActionsDock extends ConsumerStatefulWidget {
  const ShelfActionsDock({super.key, required this.selected});
  final Set<String> selected;

  @override
  ConsumerState<ShelfActionsDock> createState() => _ShelfActionsDockState();
}

class _ShelfActionsDockState extends ConsumerState<ShelfActionsDock> {
  bool _saving = false;

  Future<void> _apply(Future<void> Function() operation) async {
    if (_saving) return;
    final selection = widget.selected;
    setState(() => _saving = true);
    try {
      await operation();
      if (mounted && identical(ref.read(shelfSelectionProvider), selection)) {
        ref.read(shelfSelectionProvider.notifier).clear();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('操作未保存，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(shelfBooksProvider).asData?.value ?? [];
    final pins = ref.watch(shelfPinsProvider).asData?.value;
    final selected = books
        .where((book) => widget.selected.contains(book.id))
        .toList();
    final allPinned =
        pins != null && selected.every((book) => pins.containsKey(book.id));
    final allFavorite =
        selected.isNotEmpty && selected.every((book) => book.favorite);
    final enabled = !_saving && selected.length == widget.selected.length;
    final single = widget.selected.length == 1 ? selected.firstOrNull : null;
    final theme = Theme.of(context);

    return Column(
      key: const Key('shelf-actions-dock'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (single != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 17, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  single.title,
                  key: const Key('shelf-selection-title'),
                  style: theme.textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${(single.metadata['chapterTitle'] as String?)?.isNotEmpty == true ? single.metadata['chapterTitle'] : '尚无章节信息'} · ${shelfBookProgressLabel(single)}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 24, endIndent: 24),
        ],
        SizedBox(
          height: 64,
          child: Material(
            type: MaterialType.transparency,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _action(
                  icon: allPinned
                      ? Icons.push_pin_rounded
                      : Icons.push_pin_outlined,
                  label: allPinned ? '取消置顶' : '置顶',
                  onTap: enabled && pins != null
                      ? () => _apply(() async {
                          final library = await ref.read(
                            localLibraryProvider.future,
                          );
                          await library.setBooksPinned(
                            selected.map((book) => book.id),
                            !allPinned,
                          );
                        })
                      : null,
                ),
                _action(
                  icon: allFavorite
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  label: allFavorite ? '取消收藏' : '加入收藏',
                  onTap: enabled
                      ? () => _apply(() async {
                          final repo = await ref.read(
                            syncRepositoryProvider.future,
                          );
                          await repo.setFavorites(selected, !allFavorite);
                        })
                      : null,
                ),
                _action(
                  icon: Icons.history_rounded,
                  label: '移出最近阅读',
                  onTap: enabled && selected.any((book) => book.recent)
                      ? () => _apply(() async {
                          final repo = await ref.read(
                            syncRepositoryProvider.future,
                          );
                          await repo.removeRecentBooks(selected);
                        })
                      : null,
                ),
                _action(icon: Icons.drive_file_move_outline, label: '移动至分组'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final color = onTap == null
        ? theme.colorScheme.onSurface.withValues(alpha: .38)
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        button: true,
        enabled: onTap != null,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(height: 3),
                Flexible(
                  child: Center(
                    heightFactor: 1,
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: color,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
