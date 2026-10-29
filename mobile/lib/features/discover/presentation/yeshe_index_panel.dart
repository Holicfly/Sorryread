import 'package:flutter/material.dart';

import '../data/yeshe_index.dart';

class YesheIndexPanel extends StatelessWidget {
  const YesheIndexPanel({super.key, required this.controller});
  final YesheIndexController controller;
  void _help(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('建立本地书目后搜索'),
      content: const SingleChildScrollView(
        child: Text(
          '夜社没有可用的小说站内搜索。此功能只下载书名和链接，建立本机书目后按书名搜索，不下载封面或小说正文。\n\n目前约 2.5 万本、840 多页。使用最多 4 路并发下载，首次全量时间会根据实际速度估算；网络较慢或网站限流时耗时会增加。流量约 5～30 MB，数据库约 3～10 MB，实际进度、接收量和占用会显示在此页。\n\n下载会在后台继续，并通过系统通知显示进度；通知中可以暂停。中断或系统结束任务后，已保存的分页不会丢失，可回到这里继续。网站繁忙或限流时自动降速等待。建议连接 Wi-Fi 并保持电量充足。\n\n无需等全部完成，已缓存的书目就能搜索；尚未缓存的书暂时搜不到。新书不会自动出现在旧书目里，完成后可点“更新书目”重新扫描，原有本地书目仍可搜索。网址解析一直可用。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('yeshe-index-action'),
                  onPressed: controller.actionBusy || s.complete
                      ? null
                      : () => controller.action(),
                  icon: Icon(
                    s.running ? Icons.pause_rounded : Icons.download_rounded,
                  ),
                  label: Text(
                    s.running
                        ? '暂停缓存'
                        : s.complete
                        ? '书目已缓存'
                        : s.pages > 0
                        ? '继续缓存书目'
                        : '缓存全部书目',
                  ),
                ),
                IconButton(
                  key: const Key('yeshe-index-help'),
                  onPressed: () => _help(context),
                  tooltip: '缓存说明',
                  icon: const Icon(Icons.help_outline_rounded),
                ),
                if (s.complete)
                  TextButton(
                    onPressed: controller.actionBusy
                        ? null
                        : () => controller.action(refresh: true),
                    child: const Text('更新书目'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              s.complete
                  ? '本地书目已建立 · ${s.count} 本'
                  : '已缓存 ${s.count}${s.total > 0 ? '/${s.total}' : ''} 本 · ${s.pages} 页',
            ),
            if (s.running) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: s.progress),
              const SizedBox(height: 8),
              Text(s.remaining),
              if (s.speed != null) Text(s.speed!),
            ],
            if (s.count > 0)
              Text(
                '本地占用 ${(s.number('size') / 1048576).toStringAsFixed(1)} MB · 接收网页 ${(s.number('bytes') / 1048576).toStringAsFixed(1)} MB',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (!s.complete) const Text('可搜索已缓存部分，支持暂停与断点继续。'),
            if (s.error.isNotEmpty || controller.statusError != null)
              Text(
                controller.statusError ?? s.error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}
