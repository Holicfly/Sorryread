import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../design_system/components.dart';
import '../application/sync_controller.dart';
import 'sync_page.dart';
import 'sync_wash.dart';

class SyncStatusEntry extends ConsumerWidget {
  const SyncStatusEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final result = ref.watch(syncControllerProvider);
    final state = result.asData?.value;
    final connected = state?.connected == true;
    final caption = result.hasError
        ? '加载失败'
        : state == null
        ? '加载中'
        : state.paused
        ? '连接已暂停'
        : state.busy
        ? '正在同步…'
        : state.peer?.name ?? '扫码连接';
    return Semantics(
      button: true,
      label: '与电脑同步，${connected ? '已连接，' : ''}$caption',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => context.go('/bookshelf/sync'),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      Icons.desktop_windows_outlined,
                      size: 23,
                      color: colors.onSurface,
                    ),
                    Positioned(
                      top: -1,
                      right: -2,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: connected ? colors.primary : colors.outline,
                          border: Border.all(
                            color: Theme.of(context).scaffoldBackgroundColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '与电脑同步',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.3,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.3,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SyncStatusCard extends ConsumerWidget {
  const SyncStatusCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final result = ref.watch(syncControllerProvider);
    final state = result.asData?.value;
    final connected = state?.connected == true && state?.paused != true;
    final label = result.hasError
        ? '设备信息暂时无法加载'
        : state == null
        ? '正在加载设备信息'
        : state.paused
        ? '连接已暂停'
        : state.busy
        ? '正在同步…'
        : connected
        ? '已连接 · ${state.peer!.name}'
        : state.peer != null
        ? '已配对 · 等待电脑在线'
        : '扫码连接电脑';
    return SyncWash(
      connected: connected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          onTap: () => context.go('/profile/sync'),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 58,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.devices_rounded,
                    color: colors.primary,
                    size: 29,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '与电脑同步',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: connected
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      if (state?.lastSuccess != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          '上次同步 · ${syncTime(state!.lastSuccess)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? colors.surface.withValues(alpha: .75)
                        : Colors.white.withValues(alpha: .9),
                    border: Border.all(
                      color: colors.primary.withValues(alpha: .06),
                    ),
                  ),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: colors.primary,
                    size: 24,
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
