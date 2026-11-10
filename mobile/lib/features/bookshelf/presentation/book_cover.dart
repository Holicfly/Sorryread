import 'dart:math';
import 'dart:io';

import 'package:flutter/material.dart';

/// Keep assignments during rebuilds and spread matching covers across the grid.
class BookCoverAssignments {
  BookCoverAssignments({Random? random}) : _random = random ?? Random();
  final Random _random;
  final _assigned = <String, int>{};

  List<int> forBooks(List<String> ids, {int columns = 3}) {
    final result = <int>[];
    for (var i = 0; i < ids.length; i++) {
      final column = i % columns;
      final excluded = <int>{
        if (i > 0) result[i - 1],
        if (i > 1) result[i - 2],
        if (i >= columns) result[i - columns],
        if (i >= columns && column > 0) result[i - columns - 1],
        if (i >= columns && column < columns - 1) result[i - columns + 1],
      };
      var choice = _assigned[ids[i]];
      if (choice == null || excluded.contains(choice)) {
        final options = [
          for (var n = 0; n < BookCover.designCount; n++)
            if (!excluded.contains(n)) n,
        ];
        choice = options[_random.nextInt(options.length)];
        _assigned[ids[i]] = choice;
      }
      result.add(choice);
    }
    return result;
  }
}

class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.design,
    required this.title,
    required this.progress,
    this.decodeWidthOverride,
    this.localCover,
  });
  final int design;
  final String title, progress;
  final int? decodeWidthOverride;
  final File? localCover;
  static const aspectRatio = 858 / 1341;
  static int get designCount => _inks.length;
  static String artworkAsset(int design) =>
      'assets/covers/cover_${design + 1}.png';
  static int decodeWidthFor(double width, double pixelRatio) =>
      (width * 1024 / 858 * pixelRatio).ceil().clamp(1, 1024);

  static const _moonlightInk = Color(0xFFFFF2D8);
  static const _inks = [
    Color(0xFF534735),
    Color(0xFF51465D),
    Color(0xFF354D3D),
    Color(0xFF36515B),
    Color(0xFF304D65),
    Color(0xFF58492F),
    Color(0xFF513B49),
    Color(0xFF3B2445),
    Color(0xFF28445B),
    _moonlightInk,
    Color(0xFF442D1D),
    Color(0xFF263F32),
  ];

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: aspectRatio,
    child: LayoutBuilder(
      builder: (context, box) {
        final ink = _inks[design];
        final moonlight = ink == _moonlightInk;
        final decodeWidth = decodeWidthFor(
          box.maxWidth,
          MediaQuery.devicePixelRatioOf(context),
        );
        Widget layer(String asset) => Positioned(
          left: -box.maxWidth * 83 / 858,
          top: -box.maxHeight * 97 / 1341,
          width: box.maxWidth * 1024 / 858,
          height: box.maxHeight * 1536 / 1341,
          child: Image.asset(
            asset,
            fit: BoxFit.fill,
            cacheWidth: decodeWidthOverride ?? decodeWidth,
            excludeFromSemantics: true,
          ),
        );
        final artwork = ClipRRect(
          borderRadius: BorderRadius.circular(box.maxWidth * 38 / 858),
          child: Stack(
            fit: StackFit.expand,
            children: [
              layer(artworkAsset(design)),
              layer('assets/covers/spine.png'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
                child: DefaultTextStyle(
                  style: TextStyle(
                    color: ink,
                    shadows: moonlight
                        ? const [
                            Shadow(color: Color(0xB21B3542), blurRadius: 3),
                          ]
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '素若 · 阅读',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 9),
                      ),
                      Expanded(
                        child: Align(
                          alignment: const Alignment(0, -.2),
                          child: Text(
                            title,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              height: 1.45,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          progress,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: moonlight ? const Color(0xFF254352) : null,
                            shadows: moonlight ? const [] : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
        final cover = localCover;
        if (cover == null) return artwork;
        return ClipRRect(
          borderRadius: BorderRadius.circular(box.maxWidth * 38 / 858),
          child: Image.file(
            cover,
            fit: BoxFit.cover,
            width: box.maxWidth,
            height: box.maxHeight,
            cacheWidth: decodeWidth,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => artwork,
          ),
        );
      },
    ),
  );
}
