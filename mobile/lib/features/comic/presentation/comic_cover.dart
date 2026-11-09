import 'package:flutter/material.dart';

import '../data/yeshe_comic.dart';

class ComicCover extends StatelessWidget {
  const ComicCover({super.key, required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    final source = comicImageUrl(Uri.parse('https://yeshezy1.com/'), url);
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = bounds.maxWidth;
        final placeholder = AspectRatio(
          aspectRatio: .7,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: const Icon(Icons.image_outlined, size: 24),
          ),
        );
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: source == null
              ? placeholder
              : Image.network(
                  source,
                  width: width,
                  fit: BoxFit.contain,
                  alignment: Alignment.topCenter,
                  cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                      .ceil()
                      .clamp(1, 800),
                  frameBuilder: (context, child, frame, synchronous) =>
                      synchronous || frame != null ? child : placeholder,
                  errorBuilder: (_, _, _) => placeholder,
                  excludeFromSemantics: true,
                ),
        );
      },
    );
  }
}
