import 'package:flutter/material.dart';

/// Muted two-hue wash anchored to the top of a page, fading into the
/// scaffold background.
///
/// Two stacked gradients, no saveLayer:
///   1. a horizontal hue shift at a low, constant alpha;
///   2. a vertical ramp back to the page background.
///
/// The result is the "top tint" native readers use: strongest at the very
/// top, gone by ~220 dp, slightly warmer on one side than the other.
enum TopWashTone {
  /// 书架：雾蓝 → 暖砂
  shelf(Color(0xFF9FBCDA), Color(0xFFE5C9A0)),

  /// 发现：淡紫 → 鼠尾草
  discover(Color(0xFFB5A7D4), Color(0xFFA9CCB8)),

  /// 我的：杏色 → 雾蓝
  profile(Color(0xFFE8C0A6), Color(0xFFACC4DF)),

  /// 本地存储：青瓷绿 → 淡麦色
  storage(Color(0xFF80BDB5), Color(0xFFE1D3A0));

  const TopWashTone(this.left, this.right);
  final Color left;
  final Color right;
}

class TopWash extends StatelessWidget {
  const TopWash({super.key, required this.tone, this.height = 220});

  final TopWashTone tone;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = theme.scaffoldBackgroundColor;
    final dark = theme.brightness == Brightness.dark;
    final tint = dark ? .20 : .26;

    return IgnorePointer(
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      tone.left.withValues(alpha: tint),
                      tone.right.withValues(alpha: tint),
                    ],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      background.withValues(alpha: 0),
                      background.withValues(alpha: .65),
                      background,
                    ],
                    stops: const [0, .52, 1],
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

/// Full-page [Stack] that keeps [TopWash] fixed behind a scrolling page.
class TopWashPage extends StatelessWidget {
  const TopWashPage({
    super.key,
    required this.tone,
    required this.child,
    this.height = 280,
  });

  final TopWashTone tone;
  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: TopWash(tone: tone, height: height),
      ),
      Positioned.fill(child: child),
    ],
  );
}
