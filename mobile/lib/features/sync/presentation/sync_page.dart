import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    '在线书自动同步收藏、最近阅读和阅读进度。本地图书与支持该功能的电脑自动同步原文件、目录、收藏和续读位置。\n\n在同一局域网或热点下连接，打开应用后自动重连。移出本地图书时，可以选择当前设备或双端。双端移除在对端连接后执行。';

class SyncPage extends ConsumerWidget {
  const SyncPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncControllerProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('与电脑同步'),
        backgroundColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              Theme.of(context).brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: Theme.of(context).brightness,
        ),
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded),
          tooltip: '返回',
          onPressed: () => context.pop(),
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
      padding: EdgeInsets.fromLTRB(
        AppSpacing.listInset,
        12,
        AppSpacing.listInset,
        28 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.devices_rounded,
                      size: 34,
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
                        Text('书架、阅读进度与本地图书', style: theme.textTheme.bodySmall),
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
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final buttons = <Widget>[
                    FilledButton.icon(
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
                      icon: const Icon(Icons.sync_rounded, size: 17),
                      label: const Text('立即同步', textAlign: TextAlign.center),
                    ),
                    OutlinedButton.icon(
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
                      icon: Icon(
                        value.paused
                            ? Icons.link_rounded
                            : Icons.link_off_rounded,
                        size: 17,
                      ),
                      label: Text(
                        value.paused ? '重新连接' : '断开连接',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ];
                  if (constraints.maxWidth < 270 ||
                      MediaQuery.textScalerOf(context).scale(14) > 21) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        buttons.first,
                        const SizedBox(height: 8),
                        buttons.last,
                      ],
                    );
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
              const SizedBox(height: 13),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 6,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 17,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '上次同步 · ${syncTime(value.lastSuccess)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
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
        const Divider(height: 38, indent: 8, endIndent: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: _RecentSyncRecords(),
        ),
        const Divider(height: 38, indent: 8, endIndent: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            value.peer == null ? '连接设备' : '已连接设备',
            style: theme.textTheme.titleMedium,
          ),
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                const FeatureIconBadge(
                  Icons.desktop_windows_outlined,
                  size: 38,
                ),
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
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.link_off_rounded, size: 17),
              label: const Text('删除当前连接设备'),
              style: TextButton.styleFrom(foregroundColor: colors.error),
              onPressed: value.busy
                  ? null
                  : () async {
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
        const Divider(height: 34, indent: 8, endIndent: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('近期同步', style: theme.textTheme.titleMedium)),
            TextButton(
              onPressed: () =>
                  context.push('${GoRouterState.of(context).uri.path}/records'),
              child: const Text('更多记录'),
            ),
          ],
        ),
        Text('仅保留最近 24 小时', style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        ref
            .watch(syncLogsProvider)
            .when(
              loading: () => const Text('正在加载记录…'),
              error: (_, _) => const Text('记录暂时无法加载'),
              data: (entries) => entries.isEmpty
                  ? const Text('暂无同步记录')
                  : Column(
                      children: [
                        for (final (index, item) in entries.take(count).indexed)
                          _SyncTimelineRow(
                            item: item,
                            first: index == 0,
                            last:
                                index + 1 == count ||
                                index + 1 == entries.length,
                          ),
                      ],
                    ),
            ),
      ],
    );
  }
}

class _SyncTimelineRow extends StatelessWidget {
  const _SyncTimelineRow({
    required this.item,
    required this.first,
    required this.last,
  });

  final Json item;
  final bool first, last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final success = item['success'] == 1;
    final lineColor = theme.colorScheme.outlineVariant;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                Container(width: 1, height: 5, color: first ? null : lineColor),
                Icon(
                  success ? Icons.check_circle_outline : Icons.error_outline,
                  size: 18,
                  color: success
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                if (!last)
                  Expanded(child: Container(width: 1, color: lineColor)),
              ],
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 3, bottom: last ? 2 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['message'] as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _logTime(item['time_utc'] as String),
                    style: theme.textTheme.bodySmall,
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
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.listInset,
                      20,
                      AppSpacing.listInset,
                      20 + MediaQuery.paddingOf(context).bottom,
                    ),
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
