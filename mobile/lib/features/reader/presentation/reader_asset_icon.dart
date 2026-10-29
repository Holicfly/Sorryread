import 'package:flutter/material.dart';

/// Keep the supplied PNGs intact; frame their visible artwork consistently.
class ReaderAssetIcon extends StatelessWidget {
  const ReaderAssetIcon(
    this.name, {
    super.key,
    required this.color,
    this.size = 28,
    this.height,
  });
  final String name;
  final Color color;
  final double size;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final bounds = switch (name) {
      'catalog' => const Rect.fromLTRB(334, 466, 938, 882),
      'night' => const Rect.fromLTRB(341, 342, 934, 953),
      'day' => const Rect.fromLTRB(277, 310, 977, 991),
      'settings' => const Rect.fromLTRB(310, 319, 944, 1000),
      _ => const Rect.fromLTRB(2, 10, 46, 38),
    };
    final canvas = name.startsWith('battery_') ? 48.0 : 1254.0;
    return SizedBox(
      width: size,
      height: height ?? size,
      child: FittedBox(
        fit: name.startsWith('battery_') ? BoxFit.fill : BoxFit.contain,
        child: SizedBox(
          width: bounds.width,
          height: bounds.height,
          child: ClipRect(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: -bounds.left,
                  top: -bounds.top,
                  width: canvas,
                  height: canvas,
                  child: Image.asset(
                    'assets/reader_icons/$name.png',
                    fit: BoxFit.fill,
                    color: color,
                    colorBlendMode: BlendMode.srcIn,
                    cacheWidth: canvas == 48 ? 48 : 256,
                    excludeFromSemantics: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
