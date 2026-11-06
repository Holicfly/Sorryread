import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design_system/components.dart';
import '../data/yeshe_index.dart';

class YesheIndexPanel extends StatefulWidget {
  const YesheIndexPanel({super.key, required this.controller});
  final YesheIndexController controller;

  @override
  State<YesheIndexPanel> createState() => _YesheIndexPanelState();
}

class _YesheIndexPanelState extends State<YesheIndexPanel> {
  final _helpPortal = OverlayPortalController();
  final _helpLink = LayerLink();
  final _helpRegion = Object();

  void _toggleHelp() => setState(_helpPortal.toggle);

  void _dismissHelp() {
    if (_helpPortal.isShowing) setState(_helpPortal.hide);
  }

  Widget _help(BuildContext context) {
    final theme = Theme.of(context);
    final width = math.min(300.0, MediaQuery.sizeOf(context).width - 44);
    return OverlayPortal(
      controller: _helpPortal,
      overlayChildBuilder: (_) => Align(
        alignment: Alignment.topRight,
        child: CompositedTransformFollower(
          link: _helpLink,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -6),
          showWhenUnlinked: false,
          child: TapRegion(
            groupId: _helpRegion,
            child: Material(
              key: const Key('yeshe-index-help-overlay'),
              elevation: 5,
              shadowColor: theme.colorScheme.shadow.withValues(alpha: .18),
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: width,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      '缓存后可搜索书目，缓存可暂停和继续。发现变化时，点击「等待更新」即可更新。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _helpLink,
        child: TapRegion(
          groupId: _helpRegion,
          onTapOutside: (_) => _dismissHelp(),
          child: Semantics(
            expanded: _helpPortal.isShowing,
            child: IconButton(
              key: const Key('yeshe-index-help'),
              onPressed: _toggleHelp,
              tooltip: _helpPortal.isShowing ? '收起缓存说明' : '缓存说明',
              icon: const Icon(Icons.help_outline_rounded, size: 20),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final status = controller.state;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final progress = status.progress;
    final error = controller.statusError ?? status.error;
    final label = switch (status) {
      _ when status.running && status.updating => '正在更新',
      _ when status.running => '暂停',
      _ when status.updateAvailable => '等待更新',
      _ when status.complete => '已缓存',
      _ when status.updating => '继续更新',
      _ when status.pages > 0 => '继续缓存',
      _ => '缓存',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Semantics(
                value: progress == null ? null : '${(progress * 100).round()}%',
                child: Material(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      if (status.running ||
                          (!status.complete && status.pages > 0))
                        Positioned.fill(
                          child: IgnorePointer(
                            child: _CacheWave(
                              progress: progress ?? 0,
                              running: status.running,
                            ),
                          ),
                        ),
                      InkWell(
                        key: const Key('yeshe-index-action'),
                        onTap:
                            controller.actionBusy ||
                                (status.complete && !status.updateAvailable)
                            ? null
                            : controller.action,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              if (status.running)
                                const FeatureIconBadge(Icons.pause_rounded)
                              else if (status.updateAvailable ||
                                  status.updating)
                                const FeatureIconBadge.asset(
                                  'assets/reader_icons/ys1_update.png',
                                )
                              else if (status.complete)
                                const FeatureIconBadge(Icons.check_rounded)
                              else
                                const FeatureIconBadge.asset(
                                  'assets/reader_icons/ys1_download.png',
                                ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  label,
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            _help(context),
          ],
        ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ),
      ],
    );
  }
}

class _CacheWave extends StatefulWidget {
  const _CacheWave({required this.progress, required this.running});
  final double progress;
  final bool running;

  @override
  State<_CacheWave> createState() => _CacheWaveState();
}

class _CacheWaveState extends State<_CacheWave>
    with SingleTickerProviderStateMixin {
  late final _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1450),
  );

  void _updateMotion() {
    if (widget.running && !MediaQuery.disableAnimationsOf(context)) {
      if (!_phase.isAnimating) _phase.repeat();
    } else if (_phase.isAnimating) {
      _phase.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(_CacheWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running) _updateMotion();
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: widget.progress),
      duration: widget.running && !reduceMotion
          ? const Duration(milliseconds: 380)
          : Duration.zero,
      curve: Curves.easeOut,
      builder: (context, progress, _) => CustomPaint(
        key: const Key('yeshe-cache-wave'),
        painter: _CacheWavePainter(
          progress,
          Theme.of(context).colorScheme.primary.withValues(alpha: .22),
          _phase,
          reduceMotion: reduceMotion,
        ),
      ),
    );
  }
}

class _CacheWavePainter extends CustomPainter {
  _CacheWavePainter(
    this.progress,
    this.color,
    this.phase, {
    required this.reduceMotion,
  }) : super(repaint: phase);

  final double progress;
  final Color color;
  final Animation<double> phase;
  final bool reduceMotion;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || size.isEmpty) return;
    final edge = size.width * progress;
    final amplitude = reduceMotion
        ? 0.0
        : math.min(4.0, math.min(edge, size.width - edge));
    final path = Path()..moveTo(0, 0);
    for (var i = 0; i <= 16; i++) {
      final fraction = i / 16;
      final wave = math.sin((fraction - phase.value) * math.pi * 2);
      path.lineTo(edge + amplitude * wave, size.height * fraction);
    }
    path
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CacheWavePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.reduceMotion != reduceMotion;
}
