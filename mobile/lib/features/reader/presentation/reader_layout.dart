import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/reader_source.dart';

/// Internal offsets use UTF-16 for TextPainter; persisted offsets use Unicode scalars.
class TextAnchor {
  const TextAnchor(this.paragraph, this.offset);
  final int paragraph, offset;
}

class ReaderBlock {
  ReaderBlock(
    this.paragraph,
    this.painter,
    this.lines,
    this.spacing, {
    this.startOffset = 0,
    this.endOffset = 0,
    this.indent = 0,
  }) {
    // Resolve glyph positions once, while preparing this block, never on drag.
    _lineOffsets = [
      for (final line in lines)
        startOffset +
            math.max(
              0,
              painter
                      .getLineBoundary(
                        painter.getPositionForOffset(
                          Offset(0, line.baseline - line.ascent / 2),
                        ),
                      )
                      .start -
                  indent,
            ),
    ];
  }
  final int paragraph;
  final int startOffset, endOffset, indent;
  final TextPainter painter;
  final List<LineMetrics> lines;
  final double spacing;
  late final List<int> _lineOffsets;
  double get height => painter.height + spacing;
  double lineTop(int i) => i == 0 ? 0 : lines[i].baseline - lines[i].ascent;
  double lineBottom(int i) =>
      i + 1 == lines.length ? painter.height : lineTop(i + 1);
  int lineOffset(int i) => _lineOffsets[i];
}

class PageSlice {
  const PageSlice(this.block, this.top, this.bottom, this.y);
  final ReaderBlock block;
  final double top, bottom, y;
}

class ReaderLeaf {
  ReaderLeaf(this.anchor);
  final TextAnchor anchor;
  final List<PageSlice> slices = [];
}

class ReaderLayout {
  ReaderLayout(
    this.chapter,
    this.width,
    this.height,
    TextStyle style,
    TextScaler scaler,
  ) {
    for (final block in _shape(chapter, width, style, scaler)) {
      _append(block);
    }
  }

  ReaderLayout._(this.chapter, this.width, this.height);

  /// TextPainter belongs to the UI isolate. Shape bounded chunks between frames
  /// instead of putting an entire preloaded chapter into a widget build.
  static Future<ReaderLayout?> prepare(
    ReaderChapter chapter,
    double width,
    double height,
    TextStyle style,
    TextScaler scaler, {
    required bool Function() cancelled,
    required Future<void> Function() yieldWork,
  }) async {
    final result = ReaderLayout._(chapter, width, height);
    final watch = Stopwatch()..start();
    try {
      for (final block in _shape(chapter, width, style, scaler)) {
        result._append(block);
        if (cancelled()) {
          result.dispose();
          return null;
        }
        if (watch.elapsedMicroseconds >= 1000) {
          await yieldWork();
          if (cancelled()) {
            result.dispose();
            return null;
          }
          watch.reset();
        }
      }
      return result;
    } catch (_) {
      result.dispose();
      rethrow;
    }
  }

  static Iterable<ReaderBlock> _shape(
    ReaderChapter chapter,
    double width,
    TextStyle style,
    TextScaler scaler,
  ) sync* {
    for (var i = -1; i < chapter.paragraphs.length; i++) {
      final title = i == -1;
      final text = title ? chapter.title : chapter.paragraphs[i];
      final partStyle = title
          ? style.copyWith(
              fontSize: style.fontSize! * 1.12,
              fontWeight: FontWeight.w600,
            )
          : style;
      TextPainter shape(String text) => TextPainter(
        text: TextSpan(text: text, style: partStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        strutStyle: StrutStyle(
          fontFamily: style.fontFamily,
          fontSize: title ? style.fontSize! * 1.12 : style.fontSize,
          height: 1.8,
          forceStrutHeight: true,
        ),
      )..layout(maxWidth: width);
      var start = 0;
      final chunkSize = (width / scaler.scale(style.fontSize!) * 8)
          .round()
          .clamp(128, 512);
      while (start < text.length) {
        final indent = !title && start == 0 ? 2 : 0;
        var end = math.min(text.length, start + chunkSize);
        if (end < text.length &&
            text.codeUnitAt(end - 1) >= 0xD800 &&
            text.codeUnitAt(end - 1) <= 0xDBFF) {
          end--;
        }
        final prefix = indent == 0 ? '' : '\u3000\u3000';
        var painter = shape('$prefix${text.substring(start, end)}');
        var lines = painter.computeLineMetrics();
        if (end < text.length && lines.length > 1) {
          // End the chunk at a real line break. The next chunk continues the
          // same paragraph, without a second indent or paragraph spacing.
          final last = lines.last;
          final offset =
              painter
                  .getLineBoundary(
                    painter.getPositionForOffset(
                      Offset(0, last.baseline - last.ascent / 2),
                    ),
                  )
                  .start -
              indent;
          if (offset > 0) {
            end = start + offset;
            painter.dispose();
            painter = shape('$prefix${text.substring(start, end)}');
            lines = painter.computeLineMetrics();
          }
        }
        yield ReaderBlock(
          i,
          painter,
          lines,
          end == text.length ? style.fontSize! * (title ? 1.05 : .8) : 0,
          startOffset: start,
          endOffset: end,
          indent: indent,
        );
        start = end;
      }
    }
  }

  final ReaderChapter chapter;
  final double width, height;
  final blocks = <ReaderBlock>[];
  final _blockTops = <double>[0];
  final _pageAnchors = <TextAnchor>[const TextAnchor(0, 0)];
  List<ReaderLeaf>? _pages;
  double _pageY = 0;
  bool _pageHasContent = false;

  void _append(ReaderBlock block) {
    blocks.add(block);
    _blockTops.add(_blockTops.last + block.height);
    // Keep the small page index for the footer, without allocating page slices
    // or calling glyph hit testing while scrolling.
    for (var line = 0; line < block.lines.length; line++) {
      final lineHeight = block.lineBottom(line) - block.lineTop(line);
      if (_pageY + lineHeight > height + .01 && _pageHasContent) {
        _pageAnchors.add(
          TextAnchor(math.max(0, block.paragraph), block.lineOffset(line)),
        );
        _pageY = 0;
      }
      _pageY += lineHeight;
      _pageHasContent = true;
    }
    _pageY += block.spacing;
  }

  double get scrollHeight => _blockTops.last;
  int get pageCount => _pageAnchors.length;
  TextAnchor anchorForPage(int index) => _pageAnchors[index];
  List<ReaderLeaf> get pages => _pages ??= _paginate();
  List<ReaderLeaf> _paginate() {
    final result = <ReaderLeaf>[];
    var page = ReaderLeaf(const TextAnchor(0, 0));
    var y = 0.0;
    for (final block in blocks) {
      var start = 0;
      for (var line = 0; line < block.lines.length; line++) {
        final lineHeight = block.lineBottom(line) - block.lineTop(line);
        if (y + lineHeight > height + .01 &&
            (y > 0 || page.slices.isNotEmpty)) {
          if (line > start) {
            page.slices.add(
              PageSlice(
                block,
                block.lineTop(start),
                block.lineTop(line),
                y - (block.lineTop(line) - block.lineTop(start)),
              ),
            );
          }
          result.add(page);
          page = ReaderLeaf(
            TextAnchor(math.max(0, block.paragraph), block.lineOffset(line)),
          );
          y = 0;
          start = line;
        }
        y += lineHeight;
      }
      page.slices.add(
        PageSlice(
          block,
          block.lineTop(start),
          block.painter.height,
          y - (block.painter.height - block.lineTop(start)),
        ),
      );
      y += block.spacing;
    }
    if (page.slices.isNotEmpty) result.add(page);
    return result;
  }

  static int _compare(TextAnchor a, TextAnchor b) => a.paragraph != b.paragraph
      ? a.paragraph.compareTo(b.paragraph)
      : a.offset.compareTo(b.offset);

  int pageFor(TextAnchor anchor) {
    var lo = 0, hi = _pageAnchors.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_compare(_pageAnchors[mid], anchor) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return math.max(0, lo - 1);
  }

  double scrollFor(TextAnchor anchor) {
    if (anchor.paragraph == 0 && anchor.offset == 0) return 0;
    var lo = 0, hi = blocks.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1, b = blocks[mid];
      if (b.paragraph < anchor.paragraph ||
          (b.paragraph == anchor.paragraph && b.startOffset <= anchor.offset)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final index = lo - 1;
    if (index < 0 || blocks[index].paragraph != anchor.paragraph) return 0;
    final block = blocks[index];
    lo = 0;
    hi = block.lines.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (block.lineOffset(mid) <= anchor.offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return _blockTops[index] + block.lineTop(math.max(0, lo - 1));
  }

  TextAnchor anchorForScroll(double pixels) {
    if (pixels >= scrollHeight) {
      final p = chapter.paragraphs.length - 1;
      return TextAnchor(p, chapter.paragraphs[p].length);
    }
    var lo = 0, hi = blocks.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_blockTops[mid + 1] <= pixels) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final index = lo.clamp(0, blocks.length - 1), block = blocks[index];
    if (block.paragraph < 0) return const TextAnchor(0, 0);
    final local = pixels - _blockTops[index];
    lo = 0;
    hi = block.lines.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (block.lineTop(mid) <= local) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return TextAnchor(block.paragraph, block.lineOffset(math.max(0, lo - 1)));
  }

  void dispose() {
    for (final block in blocks) {
      block.painter.dispose();
    }
  }
}

class LeafPainter extends CustomPainter {
  LeafPainter(this.leaf);
  final ReaderLeaf leaf;
  @override
  void paint(Canvas canvas, Size size) {
    for (final slice in leaf.slices) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(0, slice.y, size.width, slice.bottom - slice.top),
      );
      slice.block.painter.paint(canvas, Offset(0, slice.y - slice.top));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(LeafPainter oldDelegate) => oldDelegate.leaf != leaf;
}

class BlockPainter extends CustomPainter {
  BlockPainter(this.block);
  final ReaderBlock block;
  @override
  void paint(Canvas canvas, Size size) =>
      block.painter.paint(canvas, Offset.zero);
  @override
  bool shouldRepaint(BlockPainter oldDelegate) => oldDelegate.block != block;
}
