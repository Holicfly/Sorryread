import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local_library.dart';
import '../../../data/reading_history.dart';
import '../../../design_system/components.dart';

class ReadingHistoryPage extends ConsumerStatefulWidget {
  const ReadingHistoryPage({super.key});

  @override
  ConsumerState<ReadingHistoryPage> createState() => _ReadingHistoryPageState();
}

class _ReadingHistoryPageState extends ConsumerState<ReadingHistoryPage> {
  final _dockKey = GlobalKey();
  double _dockHeight = 160;

  void _measureDock() {
    if (!mounted) return;
    final height = _dockKey.currentContext?.size?.height;
    if (height != null && (height - _dockHeight).abs() > .5) {
      setState(() => _dockHeight = height);
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = ref.watch(readingOverviewProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureDock());
    return Scaffold(
      appBar: AppBar(title: const Text('阅读记录')),
      body: SafeArea(
        top: false,
        bottom: false,
        child: PageWidth(
          child: Stack(
            children: [
              Positioned.fill(
                child: overview.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => Center(
                    child: TextButton(
                      onPressed: () => ref.invalidate(readingOverviewProvider),
                      child: const Text('记录加载失败，点击重试'),
                    ),
                  ),
                  data: (value) {
                    final items = <Widget>[];
                    String? day;
                    for (final entry in value.entries) {
                      if (entry.day != day) {
                        day = entry.day;
                        items.add(_DayMarker(day));
                      }
                      items.add(
                        _TimelineEntry(
                          entry,
                          key: ValueKey(
                            'history-${entry.day}-${entry.bookKey}',
                          ),
                        ),
                      );
                    }
                    return CustomScrollView(
                      key: const Key('reading-history-scroll'),
                      slivers: [
                        if (items.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                30,
                                24,
                                30,
                                _dockHeight + 24,
                              ),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '最近 30 天暂无阅读记录',
                                      textAlign: TextAlign.center,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      '翻开一本书，留下阅读的足迹。',
                                      textAlign: TextAlign.center,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        else ...[
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.listInset,
                              12,
                              AppSpacing.listInset,
                              0,
                            ),
                            sliver: SliverList.builder(
                              itemCount: items.length,
                              itemBuilder: (_, index) => items[index],
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: SizedBox(height: _dockHeight + 24),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: NotificationListener<SizeChangedLayoutNotification>(
                  onNotification: (_) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _measureDock(),
                    );
                    return false;
                  },
                  child: SizeChangedLayoutNotifier(
                    child: Padding(
                      key: _dockKey,
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.listInset,
                        8,
                        AppSpacing.listInset,
                        AppSpacing.dockBottom(context),
                      ),
                      child: _MonthDock(summary: overview.asData?.value.month),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayMarker extends StatelessWidget {
  const _DayMarker(this.day);
  final String day;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.parse(day), now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final label = date == today
        ? '今天'
        : date == yesterday
        ? '昨天'
        : '${date.year == now.year ? '' : '${date.year}年'}${date.month}月${date.day}日';
    return CustomPaint(
      painter: _TimelineLine(Theme.of(context).colorScheme.primary),
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: .65),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineEntry extends StatefulWidget {
  const _TimelineEntry(this.entry, {super.key});
  final ReadingDayEntry entry;

  @override
  State<_TimelineEntry> createState() => _TimelineEntryState();
}

class _TimelineEntryState extends State<_TimelineEntry> {
  bool _revealed = false;

  void _toggleTitle() => setState(() => _revealed = !_revealed);

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final theme = Theme.of(context);
    final progress = entry.position?.bookProgress;
    final chapter = entry.position?.chapterLabel ?? '';
    final time =
        '${entry.lastRead.hour.toString().padLeft(2, '0')}:${entry.lastRead.minute.toString().padLeft(2, '0')}';
    final colors = theme.colorScheme;
    final secondaryStyle = theme.textTheme.bodySmall;
    final displayTitle = entry.isSpecial && !_revealed ? '***' : entry.title;
    final titleText = Text(
      displayTitle,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    final title = entry.isSpecial
        ? Semantics(
            container: true,
            button: true,
            label: _revealed ? '隐藏书名' : '显示书名',
            value: displayTitle,
            onTap: _toggleTitle,
            child: ExcludeSemantics(
              child: GestureDetector(
                key: ValueKey('history-title-${entry.day}-${entry.bookKey}'),
                behavior: HitTestBehavior.opaque,
                onTap: _toggleTitle,
                child: titleText,
              ),
            ),
          )
        : titleText;
    final (asset, deviceLabel) = !entry.onDesktop
        ? ('phone', '手机阅读')
        : entry.onPhone
        ? ('both', '手机和电脑阅读')
        : ('desktop', '电脑阅读');
    final metadata = [
      if (entry.author.isNotEmpty) entry.author,
      if (chapter.isNotEmpty) chapter,
    ].join(' · ');
    final percent = progress == null ? null : '${(progress * 100).round()}%';

    return CustomPaint(
      painter: _TimelineLine(colors.primary),
      child: Padding(
        padding: const EdgeInsets.only(left: 26, bottom: 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: .45),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Semantics(
              container: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: title),
                      const SizedBox(width: 5),
                      Image.asset(
                        'assets/reading_devices/$asset.png',
                        key: const Key('reading-device-icon'),
                        width: 14,
                        height: 14,
                        color: colors.onSurface.withValues(alpha: .42),
                        semanticLabel: deviceLabel,
                      ),
                    ],
                  ),
                  if (metadata.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      metadata,
                      style: secondaryStyle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$time · 阅读 ${readingDuration(entry.milliseconds)}',
                          style: secondaryStyle,
                        ),
                      ),
                      if (progress != null) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 36,
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 3,
                            borderRadius: BorderRadius.circular(4),
                            backgroundColor: colors.primary.withValues(
                              alpha: .09,
                            ),
                            color: colors.primary.withValues(alpha: .55),
                            semanticsLabel: '整本阅读进度',
                            semanticsValue: percent,
                          ),
                        ),
                        const SizedBox(width: 5),
                        ExcludeSemantics(
                          child: Text(
                            percent!,
                            style: secondaryStyle?.copyWith(
                              color: colors.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineLine extends CustomPainter {
  const _TimelineLine(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawLine(
    const Offset(8, 0),
    Offset(8, size.height),
    Paint()
      ..color = color.withValues(alpha: .14)
      ..strokeWidth = 1,
  );

  @override
  bool shouldRepaint(_TimelineLine oldDelegate) => oldDelegate.color != color;
}

class _MonthDock extends StatelessWidget {
  const _MonthDock({required this.summary});
  final ReadingMonthSummary? summary;

  String _compactDuration(int milliseconds) {
    final minutes = milliseconds ~/ 60000;
    if (minutes < 60) return '$minutes分钟';
    final rest = minutes % 60;
    return rest == 0 ? '${minutes ~/ 60}小时' : '${minutes ~/ 60}时$rest分';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final month = summary?.month ?? DateTime.now();
    final metrics = [
      (
        icon: Icons.schedule_rounded,
        label: '阅读时长',
        value: summary == null ? '—' : _compactDuration(summary!.milliseconds),
      ),
      (
        icon: Icons.menu_book_outlined,
        label: '已读章节',
        value: summary == null ? '—' : '${summary!.chapters} 章',
      ),
      (
        icon: Icons.calendar_today_outlined,
        label: '连续阅读',
        value: summary == null ? '—' : '${summary!.streak} 天',
      ),
    ];
    return IgnorePointer(
      child: DecoratedBox(
        key: const Key('reading-month-dock'),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surface.withValues(alpha: .97),
              Color.alphaBlend(
                theme.colorScheme.primary.withValues(alpha: .06),
                theme.colorScheme.surface,
              ).withValues(alpha: .97),
            ],
          ),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: .10),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .06),
              blurRadius: 24,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  constraints.maxWidth < 310 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '本月阅读小结',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontSize: stacked ? 14 : 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        stacked
                            ? '${month.month}月'
                            : '${month.year}年${month.month}月',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (stacked)
                    for (var index = 0; index < metrics.length; index++) ...[
                      if (index > 0) const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            flex: 2,
                            child: Text(
                              metrics[index].label,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 3,
                            child: Text(
                              metrics[index].value,
                              textAlign: TextAlign.right,
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                    ]
                  else
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (
                            var index = 0;
                            index < metrics.length;
                            index++
                          ) ...[
                            if (index > 0)
                              VerticalDivider(
                                width: 18,
                                thickness: 1,
                                color: theme.colorScheme.primary.withValues(
                                  alpha: .12,
                                ),
                              ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        metrics[index].icon,
                                        size: 17,
                                        color: theme.colorScheme.primary
                                            .withValues(alpha: .8),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          metrics[index].value,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontSize: 15,
                                                height: 1.3,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 7),
                                  Text(
                                    metrics[index].label,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
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
