import 'package:flutter/material.dart';

import '../../../design_system/components.dart';
import '../../sync/presentation/sync_status_card.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) => PageWidth(
    child: ListView(
      key: const PageStorageKey('profile-scroll'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        28,
      ),
      children: const [
        PageHeading('我的'),
        _ReaderProfileBlock(),
        SizedBox(height: AppSpacing.gap),
        SyncStatusCard(),
        _SectionHeading('常用功能'),
        _SettingsGroup(
          items: [
            _PlaceholderItem(Icons.history_rounded, '阅读记录', '阅读时长与历史'),
            _PlaceholderItem(Icons.bookmark_border_rounded, '书签与笔记', '管理书签与笔记'),
            _PlaceholderItem(Icons.file_download_outlined, '下载与导入', '导入本地书籍'),
            _PlaceholderItem(Icons.storage_rounded, '本地存储', '空间使用情况'),
            _PlaceholderItem(Icons.cloud_upload_outlined, '备份与恢复', '备份数据到本地'),
          ],
        ),
        _SectionHeading('偏好与其他'),
        _SettingsGroup(
          items: [
            _PlaceholderItem(Icons.tune_rounded, '阅读设置', '字体、排版、翻页'),
            _PlaceholderItem(Icons.palette_outlined, '主题外观', '跟随系统'),
            _PlaceholderItem(Icons.shield_outlined, '隐私设置', '数据与权限'),
            _PlaceholderItem(Icons.info_outline_rounded, '关于应用', '素若阅读'),
          ],
        ),
        SizedBox(height: 18),
        Text(
          '阅读设置等功能尚未开放。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, height: 1.5),
        ),
      ],
    ),
  );
}

class _ReaderProfileBlock extends StatelessWidget {
  const _ReaderProfileBlock();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SurfaceBlock(
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.person_outline_rounded,
                  color: theme.colorScheme.primary,
                  size: 34,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('本地读者', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text('专注阅读与同步', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    const PlaceholderBadge(label: '资料占位'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final label in ['阅读时长', '已读书籍', '笔记', '连续阅读'])
                Expanded(
                  child: Column(
                    children: [
                      Text('—', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 5),
                      Text(
                        label,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 22, 0, 10),
    child: Semantics(
      header: true,
      child: Text(
        title,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

class _PlaceholderItem {
  const _PlaceholderItem(this.icon, this.title, this.description);
  final IconData icon;
  final String title;
  final String description;
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.items});
  final List<_PlaceholderItem> items;

  @override
  Widget build(BuildContext context) => SurfaceBlock(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    child: Column(
      children: [
        for (var index = 0; index < items.length; index++) ...[
          if (index > 0)
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Divider(
                height: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          _SettingsRow(item: items[index]),
        ],
      ],
    ),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.item});
  final _PlaceholderItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '${item.title}，${item.description}，功能占位，暂不可用',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  constraints.maxWidth < 340 ||
                  MediaQuery.textScalerOf(context).scale(14) > 18;
              final description = Text(
                item.description,
                style: theme.textTheme.bodySmall,
              );
              return Row(
                children: [
                  Icon(item.icon, size: 24, color: theme.colorScheme.onSurface),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.title, style: theme.textTheme.titleMedium),
                        if (stacked) ...[
                          const SizedBox(height: 4),
                          description,
                        ],
                      ],
                    ),
                  ),
                  if (!stacked) ...[
                    const SizedBox(width: 8),
                    Flexible(flex: 4, child: description),
                  ],
                  const SizedBox(width: 10),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
