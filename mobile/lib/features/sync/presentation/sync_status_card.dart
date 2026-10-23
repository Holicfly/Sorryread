import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../design_system/components.dart';
import '../application/sync_controller.dart';
import 'sync_page.dart';

class SyncStatusCard extends ConsumerWidget {
  const SyncStatusCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final result = ref.watch(syncControllerProvider);
    final state = result.asData?.value;
    final connected = state?.connected == true;
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
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(AppSpacing.radius),
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
              Icon(
                Icons.chevron_right_rounded,
                color: colors.onSurfaceVariant,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
