import 'package:flutter/material.dart';

/// A background-colored overlay, leaving the status row fully opaque and crisp.
/// Unlike a full-screen ShaderMask, this does not allocate a page-sized layer.
class ReaderBottomFade extends StatelessWidget {
  const ReaderBottomFade({
    super.key,
    required this.background,
    required this.footerHeight,
  });
  static const extent = 28.0;
  final Color background;
  final double footerHeight;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: SizedBox(
        height: footerHeight + extent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [background.withValues(alpha: 0), background, background],
              stops: [0, extent / (extent + footerHeight), 1],
            ),
          ),
        ),
      ),
    ),
  );
}
