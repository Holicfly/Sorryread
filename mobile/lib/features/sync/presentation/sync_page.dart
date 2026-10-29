import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dependencies.dart';
import '../../../design_system/components.dart';
import '../../../sync_engine/sync_model.dart';
import '../../../sync_engine/sync_transport.dart';
import '../application/sync_controller.dart';

String syncTime(DateTime? value) {
  if (value == null) return '尚未同步';
  final time = value.toLocal();
  final now = DateTime.now();
  final day =
      time.year == now.year && time.month == now.month && time.day == now.day
      ? '今天'
      : '${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  return '$day ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

const syncExplanation =
    '默认双向同步书库收藏、最近阅读和全部阅读进度，无需选择。取消收藏、移出最近阅读也会同步；删除连接设备不会清除已有阅读数据。\n\n仅在同一局域网或互连热点时连接。打开应用和阅读时自动同步，后台按系统允许的条件补齐，重新打开后自动重连。正文、目录文件、封面、设置及书签笔记不在本次同步范围内。';

class SyncPage extends ConsumerWidget {
  const SyncPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('与电脑同步'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded),
          tooltip: '返回',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/profile'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline_rounded),
            tooltip: '同步说明',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('同步说明'),
                content: const SingleChildScrollView(
                  child: Text(syncExplanation),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('知道了'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: PageWidth(
        child: status.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('设备信息暂时无法加载'),
                TextButton(
                  onPressed: () => ref.invalidate(syncControllerProvider),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
          data: (value) => _SyncContent(value: value),
        ),
      ),
    );
  }
}

class _SyncContent extends ConsumerWidget {
  const _SyncContent({required this.value});
  final SyncViewState value;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final controller = ref.read(syncControllerProvider.notifier);
    final title = value.peer == null
        ? '尚未连接电脑'
        : value.connected
        ? '已连接桌面端'
        : '已配对，等待连接';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        SurfaceBlock(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 66,
                    height: 70,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      Icons.devices_rounded,
                      size: 38,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 7),
                        Text('收藏、最近阅读与阅读进度', style: theme.textTheme.bodySmall),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.circle,
                              size: 9,
                              color: value.connected
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                value.paused
                                    ? '已暂停连接'
                                    : value.busy
                                    ? '正在连接与同步…'
                                    : value.connected
                                    ? '连接正常'
                                    : '等待局域网连接',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Divider(height: 1, color: colors.outlineVariant),
              const SizedBox(height: 14),
              Wrap(
                spacing: 14,
                runSpacing: 8,
                children: [
                  Text(
                    '上次同步 · ${syncTime(value.lastSuccess)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    value.paused
                        ? '本次运行已暂停'
                        : value.peer == null
                        ? '配对后自动同步'
                        : '自动同步已开启',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) {
                  final buttons = <Widget>[
                    FilledButton(
                      onPressed:
                          value.peer == null || value.busy || value.paused
                          ? null
                          : () => controller.synchronize(manual: true),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                      ),
                      child: const Text(
                        '立即同步',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: value.peer == null
                          ? null
                          : value.paused
                          ? value.busy
                                ? null
                                : controller.reconnect
                          : controller.disconnect,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                      ),
                      child: Text(
                        value.paused ? '重新连接' : '断开连接',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ];
                  if (MediaQuery.textScalerOf(context).scale(12) > 17) {
                    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
                  }
                  return Row(
                    children: [
                      for (var i = 0; i < buttons.length; i++) ...[
                        if (i != 0) const SizedBox(width: 8),
                        Expanded(child: buttons[i]),
                      ],
                    ],
                  );
                },
              ),
              if (value.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  value.error!,
                  style: TextStyle(color: colors.error, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),
        const _RecentSyncRecords(),
        const SizedBox(height: 22),
        Text(
          value.peer == null ? '连接设备' : '已连接设备',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 10),
        if (value.peer == null)
          SurfaceBlock(
            padding: EdgeInsets.zero,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 10,
              ),
              leading: Icon(
                Icons.add_circle_outline_rounded,
                color: colors.primary,
              ),
              title: const Text('连接新设备'),
              subtitle: const Text('扫描电脑上的配对二维码'),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: !value.busy,
              onTap: () async {
                final ticket = await context.push<PairTicket>('/scan');
                if (ticket != null && context.mounted) {
                  await controller.pair(ticket);
                }
              },
            ),
          )
        else ...[
          SurfaceBlock(
            child: Row(
              children: [
                const Icon(Icons.desktop_windows_outlined, size: 30),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value.peer!.name,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 5),
                      Text('Windows · 本地网络', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  value.connected ? '● 在线' : '● 离线',
                  style: TextStyle(
                    fontSize: 12,
                    color: value.connected
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SurfaceBlock(
            padding: EdgeInsets.zero,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 5,
              ),
              leading: Icon(Icons.link_off_rounded, color: colors.error),
              title: const Text('删除当前连接设备'),
              enabled: !value.busy,
              onTap: () async {
                final remove = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('删除当前连接设备？'),
                    content: const Text(
                      '解除配对后可连接新设备，已有阅读数据将保留。电脑离线时，也可在电脑端解除旧配对。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (remove == true) await controller.forgetPeer();
              },
            ),
          ),
        ],
        if (value.conflicts.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text('待处理的阅读进度', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          for (final record in value.conflicts)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SurfaceBlock(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.effective.payload['title'] as String,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text('两端保留了不同位置，请选择后继续同步。'),
                    for (final choice in record.positions)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton(
                          onPressed: value.busy
                              ? null
                              : () async {
                                  try {
                                    await controller.resolve(record, choice);
                                  } catch (_) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            const SnackBar(
                                              content: Text('保存选择失败，请重试'),
                                            ),
                                          );
                                    }
                                  }
                                },
                          child: Text(
                            _choiceLabel(choice, ref),
                            textAlign: TextAlign.start,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
        const SizedBox(height: 22),
        SurfaceBlock(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('同步说明', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              Text(syncExplanation, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }

  String _choiceLabel(SyncChange choice, WidgetRef ref) {
    final self = ref.read(syncRepositoryProvider).asData?.value.deviceId;
    final device = choice.origin == self ? '此手机' : '其他设备';
    final payload = choice.payload;
    if (payload['active'] == false) return '$device · 移除此阅读记录';
    return '$device · ${payload['chapterTitle'] == '' ? '阅读位置' : payload['chapterTitle']} · ${((payload['progress'] as num) * 100).round()}%';
  }
}

final syncLogsProvider = StreamProvider.autoDispose<List<Json>>((ref) async* {
  final repo = await ref.watch(syncRepositoryProvider.future);
  yield* repo.watchLogs();
});

class _RecentSyncRecords extends ConsumerWidget {
  const _RecentSyncRecords();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    final rowHeight = 76.0 * scale.clamp(1.0, 3.0);
    final count = (MediaQuery.sizeOf(context).height * .32 / rowHeight)
        .floor()
        .clamp(1, 4);
    return SurfaceBlock(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('近期同步', style: theme.textTheme.titleMedium)),
              TextButton(
                onPressed: () => context.push('/profile/sync/records'),
                child: const Text('更多记录'),
              ),
            ],
          ),
          Text('仅保留最近 24 小时', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          ref
              .watch(syncLogsProvider)
              .when(
                loading: () => const Text('正在加载记录…'),
                error: (_, _) => const Text('记录暂时无法加载'),
                data: (entries) => entries.isEmpty
                    ? const Text('暂无同步记录')
                    : Column(
                        children: [
                          for (final item in entries.take(count))
                            SizedBox(
                              height: rowHeight,
                              child: Row(
                                children: [
                                  Icon(
                                    item['success'] == 1
                                        ? Icons.check_circle_outline
                                        : Icons.error_outline,
                                    size: 18,
                                    color: item['success'] == 1
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.error,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item['message'] as String,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            height: 1.35,
                                          ),
                                        ),
                                        Text(
                                          _logTime(item['time_utc'] as String),
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
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

String _logTime(String value) {
  final date = DateTime.tryParse(value);
  return date == null
      ? value
      : '${syncTime(date)}:${date.toLocal().second.toString().padLeft(2, '0')}';
}

class SyncRecordsPage extends ConsumerWidget {
  const SyncRecordsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      title: const Text('最近 24 小时同步记录'),
      actions: [
        IconButton(
          tooltip: '刷新',
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(syncLogsProvider),
        ),
      ],
    ),
    body: PageWidth(
      child: ref
          .watch(syncLogsProvider)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) => const Center(child: Text('记录暂时无法加载，请重试')),
            data: (entries) => entries.isEmpty
                ? const Center(child: Text('暂无同步记录'))
                : ListView.separated(
                    padding: const EdgeInsets.all(20),
                    itemCount: entries.length,
                    separatorBuilder: (_, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = entries[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 6),
                        leading: Icon(
                          item['success'] == 1
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          color: item['success'] == 1
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.error,
                        ),
                        title: Text(item['message'] as String),
                        subtitle: Text(_logTime(item['time_utc'] as String)),
                      );
                    },
                  ),
          ),
    ),
  );
}
