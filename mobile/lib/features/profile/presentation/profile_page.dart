import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../design_system/components.dart';
import '../../../data/local_library.dart';
import '../../../data/reading_history.dart';
import '../data/daily_saying.dart';
import '../data/reader_profile.dart';
import '../../sync/presentation/sync_status_card.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) => PageWidth(
    child: ListView(
      key: const PageStorageKey('profile-scroll'),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.listInset,
        0,
        AppSpacing.listInset,
        28 + MediaQuery.paddingOf(context).bottom,
      ),
      children: const [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: PageHeading('我的'),
        ),
        _ReaderInformation(),
        _ReadingStatistics(),
        SizedBox(height: 20),
        SyncStatusCard(),
        SizedBox(height: 20),
        _SettingsGroup(
          items: [
            _ProfileItem(
              Icons.history_rounded,
              '阅读记录',
              '最近 30 天',
              path: '/profile/history',
            ),
            _ProfileItem(
              Icons.storage_rounded,
              '本地存储',
              '空间使用情况',
              path: '/profile/storage',
            ),
            _ProfileItem(
              Icons.info_outline_rounded,
              '关于应用',
              '素若阅读',
              path: '/profile/about',
            ),
          ],
        ),
      ],
    ),
  );
}

class _ReaderInformation extends ConsumerWidget {
  const _ReaderInformation();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final saying = ref.watch(dailySayingProvider);
    final profile =
        ref.watch(readerProfileProvider).value ?? const ReaderProfile();
    final avatarId = profile.avatarId;
    return Padding(
      key: const Key('reader-information'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      child: Row(
        children: [
          Semantics(
            container: true,
            label: '编辑昵称和头像',
            button: true,
            child: GestureDetector(
              key: const Key('profile-avatar'),
              onTap: () => context.push('/profile/edit'),
              child: CircleAvatar(
                radius: 32,
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundImage: avatarId == null
                    ? null
                    : AssetImage(presetAvatarAsset(avatarId)),
                child: avatarId == null
                    ? Icon(
                        Icons.person_outline_rounded,
                        color: theme.colorScheme.primary,
                        size: 34,
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(profile.nickname, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('每日一句', style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                saying.when(
                  data: (value) =>
                      Text(value.text, style: theme.textTheme.bodyMedium),
                  loading: () =>
                      Text('正在获取…', style: theme.textTheme.bodySmall),
                  error: (_, _) => TextButton(
                    onPressed: () => ref.invalidate(dailySayingProvider),
                    child: const Text('每日一句暂不可用，点击重试。'),
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

class _ReadingStatistics extends ConsumerWidget {
  const _ReadingStatistics();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final statistics = ref.watch(readingStatsProvider);
    ref.watch(localDayProvider);
    final stats = statistics.asData?.value, now = DateTime.now();
    final items = [
      (
        icon: Icons.menu_book_outlined,
        label: '今日阅读',
        value: stats?.durationLabelFor(now) ?? '—',
      ),
      (
        icon: Icons.hourglass_empty_rounded,
        label: '阅读时长',
        value: stats?.durationLabel ?? '—',
      ),
      (
        icon: Icons.storage_rounded,
        label: '已读书籍',
        value: stats == null ? '—' : '${stats.bookCount} 本',
      ),
      (
        icon: Icons.event_available_outlined,
        label: '连续阅读',
        value: stats == null ? '—' : '${stats.streak(now)} 天',
      ),
    ];
    final valueStyle = theme.textTheme.titleMedium!.copyWith(height: 1.35);
    final labelStyle = theme.textTheme.bodySmall!;
    return SurfaceBlock(
      key: const Key('reading-statistics-card'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 18),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final columns =
                  constraints.maxWidth < 350 &&
                      MediaQuery.textScalerOf(context).scale(14) > 20
                  ? 2
                  : 4;
              final width = constraints.maxWidth / columns - 8;
              double height(String text, TextStyle style) {
                final painter = TextPainter(
                  text: TextSpan(text: text, style: style),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout(maxWidth: width);
                final height = painter.height;
                painter.dispose();
                return height;
              }

              final valueHeight = items
                  .map((item) => height(item.value, valueStyle))
                  .reduce((a, b) => a > b ? a : b);
              final labelHeight = items
                  .map((item) => height(item.label, labelStyle))
                  .reduce((a, b) => a > b ? a : b);
              Widget cell(int index) {
                final item = items[index];
                final summary = Column(
                  children: [
                    FeatureIconBadge(
                      item.icon,
                      key: ValueKey('stat-icon-${item.label}'),
                      size: 34,
                      iconSize: 21,
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: valueHeight,
                      child: Center(
                        child: Text(
                          item.value,
                          textAlign: TextAlign.center,
                          style: valueStyle,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: labelHeight,
                      child: Text(
                        item.label,
                        textAlign: TextAlign.center,
                        style: labelStyle,
                      ),
                    ),
                  ],
                );
                if (index > 1) return summary;
                return _ReadingTimeCell(
                  key: ValueKey('reading-time-${item.label}'),
                  label: item.label,
                  height: 34 + 12 + valueHeight + 6 + labelHeight,
                  durations: stats?.durationByDevice(
                    day: index == 0 ? now : null,
                  ),
                  summary: summary,
                );
              }

              return Wrap(
                runSpacing: 18,
                children: [
                  for (var index = 0; index < items.length; index++)
                    SizedBox(
                      width: constraints.maxWidth / columns,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: index % columns == 0
                              ? null
                              : Border(
                                  left: BorderSide(
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: .65),
                                  ),
                                ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: cell(index),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (statistics.hasError)
            TextButton(
              onPressed: () => ref.invalidate(readingStatsProvider),
              child: const Text('统计加载失败，点击重试'),
            ),
        ],
      ),
    );
  }
}

class _ReadingTimeCell extends StatefulWidget {
  const _ReadingTimeCell({
    super.key,
    required this.label,
    required this.height,
    required this.durations,
    required this.summary,
  });

  final String label;
  final double height;
  final ({int phone, int desktop})? durations;
  final Widget summary;

  @override
  State<_ReadingTimeCell> createState() => _ReadingTimeCellState();
}

class _ReadingTimeCellState extends State<_ReadingTimeCell> {
  Timer? _restoreTimer;

  void _toggleDetails() {
    setState(() {
      if (_restoreTimer != null) {
        _restoreTimer!.cancel();
        _restoreTimer = null;
      } else {
        _restoreTimer = Timer(const Duration(seconds: 5), () {
          setState(() => _restoreTimer = null);
        });
      }
    });
  }

  @override
  void dispose() {
    _restoreTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final durations = widget.durations;
    final showDetails = _restoreTimer != null && durations != null;
    final theme = Theme.of(context);

    Widget device(IconData icon, String label, int duration) => Expanded(
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 13, color: theme.colorScheme.primary),
                  const SizedBox(width: 3),
                  Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ],
              ),
              Text(
                readingDuration(duration),
                style: theme.textTheme.titleMedium?.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );

    return SizedBox(
      height: widget.height,
      child: Semantics(
        button: durations != null,
        label: showDetails ? widget.label : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          onTap: durations == null ? null : _toggleDetails,
          child: showDetails
              ? Column(
                  children: [
                    device(Icons.smartphone_rounded, '手机', durations.phone),
                    const Divider(height: 1, indent: 6, endIndent: 6),
                    device(
                      Icons.desktop_windows_outlined,
                      '电脑',
                      durations.desktop,
                    ),
                  ],
                )
              : widget.summary,
        ),
      ),
    );
  }
}

class _ProfileItem {
  const _ProfileItem(this.icon, this.title, this.description, {this.path});
  final IconData icon;
  final String title;
  final String description;
  final String? path;
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.items});
  final List<_ProfileItem> items;

  @override
  Widget build(BuildContext context) => SurfaceBlock(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Column(
      children: [
        for (var index = 0; index < items.length; index++) ...[
          if (index > 0)
            Padding(
              padding: const EdgeInsets.only(left: 68, right: 16),
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
  final _ProfileItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: item.path == null ? null : () => context.push(item.path!),
      child: Semantics(
        label: item.path == null
            ? '${item.title}，${item.description}，功能占位，暂不可用'
            : '${item.title}，${item.description}',
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final description = Text(
                  item.description,
                  key: ValueKey('profile-description-${item.title}'),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall,
                );
                return Row(
                  children: [
                    FeatureIconBadge(item.icon),
                    const SizedBox(width: 14),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final title = Text(
                            item.title,
                            style: theme.textTheme.titleMedium,
                          );
                          double width(String value, TextStyle? style) {
                            final painter = TextPainter(
                              text: TextSpan(text: value, style: style),
                              textDirection: Directionality.of(context),
                              textScaler: MediaQuery.textScalerOf(context),
                            )..layout();
                            final width = painter.width;
                            painter.dispose();
                            return width;
                          }

                          if (width(item.title, theme.textTheme.titleMedium) +
                                  width(
                                    item.description,
                                    theme.textTheme.bodySmall,
                                  ) +
                                  12 >
                              constraints.maxWidth) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                title,
                                const SizedBox(height: 4),
                                description,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: title),
                              const SizedBox(width: 12),
                              description,
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(
                      Icons.chevron_right_rounded,
                      key: ValueKey('profile-arrow-${item.title}'),
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
