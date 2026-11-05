import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design_system/components.dart';

/// A slow moving pigment wash. The foreground is never rebuilt by animation.
class SyncWash extends StatefulWidget {
  const SyncWash({super.key, required this.connected, required this.child});
  final bool connected;
  final Widget child;

  @override
  State<SyncWash> createState() => _SyncWashState();
}

class _SyncWashState extends State<SyncWash>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _clock = AnimationController.unbounded(vsync: this);
  bool _foreground = true, _visible = true, _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _updatePlayback();
  }

  @override
  void didUpdateWidget(SyncWash oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updatePlayback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updatePlayback();
  }

  void _updatePlayback() {
    if (widget.connected && _foreground && _visible && !_reduceMotion) {
      if (!_clock.isAnimating) _clock.animateWith(_WashClock(_clock.value));
    } else {
      _clock.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.radius),
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: widget.connected && !dark
                  ? Colors.white
                  : theme.colorScheme.surface,
            ),
          ),
          if (widget.connected)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      key: const Key('connected-sync-wash'),
                      painter: SyncWashPainter(clock: _clock, dark: dark),
                    ),
                  ),
                ),
              ),
            ),
          widget.child,
        ],
      ),
    );
  }
}

class _WashClock extends Simulation {
  _WashClock(this.start);
  final double start;
  @override
  double x(double time) => start + time;
  @override
  double dx(double time) => 1;
  @override
  bool isDone(double time) => false;
}

/// Overlapping soft ellipses drift and deform at different continuous rates.
/// Radial shaders provide soft edges without offscreen blur layers.
class SyncWashPainter extends CustomPainter {
  SyncWashPainter({required this.clock, required this.dark})
    : super(repaint: clock);
  final Animation<double> clock;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.value;
    final pigment = dark ? const Color(0xFF7EB28C) : const Color(0xFFA3C8A8);
    final opacity = dark ? .14 : .36;
    for (var i = 0; i < 3; i++) {
      final seed = i * 2.13;
      final x =
          size.width *
          (.52 +
              .30 * math.sin(t * .19 + seed) +
              .07 * math.sin(t * .071 + seed));
      final y = size.height * (.5 + .40 * math.sin(t * .137 + seed * .8));
      final width = size.width * (.48 + .10 * math.sin(t * .113 + seed));
      final height = size.height * (.95 + .25 * math.sin(t * .163 + seed));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(.18 * math.sin(t * .083 + seed));
      canvas.scale(width, height);
      canvas.drawCircle(
        Offset.zero,
        1,
        Paint()
          ..shader = RadialGradient(
            colors: [
              pigment.withValues(alpha: opacity),
              pigment.withValues(alpha: opacity * .55),
              pigment.withValues(alpha: 0),
            ],
            stops: const [0, .45, 1],
          ).createShader(const Rect.fromLTWH(-1, -1, 2, 2)),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(SyncWashPainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.clock != clock;
}
