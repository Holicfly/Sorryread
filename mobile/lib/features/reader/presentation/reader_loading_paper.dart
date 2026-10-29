import 'package:flutter/material.dart';

/// A single centered loading state inside the fixed paper plane.
class ReaderLoadingPaper extends StatelessWidget {
  const ReaderLoadingPaper({
    super.key,
    required this.ink,
    required this.accent,
  });
  final Color ink, accent;
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: Center(
      key: const Key('reader-loading-paper'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: accent),
          const SizedBox(height: 16),
          Text('正在加载章节', style: TextStyle(color: ink)),
        ],
      ),
    ),
  );
}
