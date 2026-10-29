import 'package:flutter/material.dart';

import '../../bookshelf/presentation/book_opening.dart';

/// This loading state is painted inside the fixed paper plane. A narrow rail
/// reaches its right edge, so even the first exposed strip signals loading.
class ReaderLoadingPaper extends StatelessWidget {
  const ReaderLoadingPaper({
    super.key,
    required this.ink,
    required this.accent,
  });
  final Color ink, accent;
  @override
  Widget build(BuildContext context) {
    final animation = BookPaperScope.maybeOf(context)?.animation;
    Widget content(bool opening) => Stack(
      key: const Key('reader-loading-paper'),
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('正在加载章节', style: TextStyle(color: ink)),
            ],
          ),
        ),
        if (opening)
          Positioned(
            key: const Key('reader-opening-loading'),
            right: 0,
            top: 0,
            bottom: 0,
            width: 42,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .08),
                border: Border(right: BorderSide(color: accent, width: 2)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < 3; i++)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: accent,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('加载中', style: TextStyle(fontSize: 11, color: ink)),
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
    return RepaintBoundary(
      child: animation == null
          ? content(false)
          : AnimatedBuilder(
              animation: animation,
              builder: (_, _) => content(
                !animation.isCompleted &&
                    animation.status != AnimationStatus.reverse,
              ),
            ),
    );
  }
}
