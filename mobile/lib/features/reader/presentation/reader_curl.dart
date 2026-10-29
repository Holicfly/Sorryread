import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'reader_layout.dart';

/// Paint both text leaves and a curved, shaded paper fold. No chapter bitmap copies.
class PaperCurlPainter extends CustomPainter {
  PaperCurlPainter({
    required this.from,
    required this.to,
    required this.progress,
    required this.forward,
    required this.paper,
    this.insets = EdgeInsets.zero,
  });
  final ReaderLeaf from, to;
  final double progress;
  final bool forward;
  final Color paper;
  final EdgeInsets insets;
  @override
  void paint(Canvas canvas, Size size) {
    if (!forward) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    void leaf(ReaderLeaf value) {
      if (!forward) {
        canvas.save();
        canvas.translate(size.width, 0);
        canvas.scale(-1, 1);
      }
      canvas.save();
      canvas.translate(insets.left, insets.top);
      LeafPainter(value).paint(
        canvas,
        Size(size.width - insets.horizontal, size.height - insets.vertical),
      );
      canvas.restore();
      if (!forward) canvas.restore();
    }

    canvas.drawColor(paper, BlendMode.srcOver);
    leaf(to);
    final x = size.width * (1 - progress);
    final bend =
        math.sin(math.pi * progress) * math.min(76.0, size.width * .22);
    final edge = Path()
      ..moveTo(0, 0)
      ..lineTo(x, 0)
      ..cubicTo(
        x - bend * .45,
        size.height * .28,
        x - bend * .45,
        size.height * .72,
        x,
        size.height,
      )
      ..lineTo(0, size.height)
      ..close();
    canvas.save();
    canvas.clipPath(edge);
    canvas.drawColor(paper, BlendMode.srcOver);
    leaf(from);
    canvas.restore();
    if (bend > .1) {
      final fold = Path()
        ..moveTo(x, 0)
        ..cubicTo(
          x - bend * .45,
          size.height * .28,
          x - bend * .45,
          size.height * .72,
          x,
          size.height,
        )
        ..quadraticBezierTo(x + bend * 1.5, size.height * .5, x, 0)
        ..close();
      canvas.drawShadow(fold, Colors.black.withValues(alpha: .4), 7, false);
      canvas.save();
      canvas.clipPath(fold);
      canvas.drawColor(paper, BlendMode.srcOver);
      canvas.save();
      canvas.translate(2 * x, 0);
      canvas.scale(-1, 1);
      leaf(from);
      canvas.restore();
      canvas.drawPath(fold, Paint()..color = paper.withValues(alpha: .92));
      canvas.drawPath(
        fold,
        Paint()
          ..shader =
              LinearGradient(
                colors: [
                  Colors.black.withValues(alpha: .14),
                  Colors.white.withValues(alpha: .32),
                  Colors.black.withValues(alpha: .08),
                ],
              ).createShader(
                Rect.fromLTWH(x - bend * .4, 0, bend * 1.5, size.height),
              ),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(PaperCurlPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      from != oldDelegate.from ||
      to != oldDelegate.to ||
      insets != oldDelegate.insets ||
      forward != oldDelegate.forward ||
      paper != oldDelegate.paper;
}

class ScreenLeafPainter extends CustomPainter {
  ScreenLeafPainter(this.leaf, this.paper, this.insets);
  final ReaderLeaf leaf;
  final Color paper;
  final EdgeInsets insets;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);
    canvas.save();
    canvas.translate(insets.left, insets.top);
    LeafPainter(leaf).paint(
      canvas,
      Size(size.width - insets.horizontal, size.height - insets.vertical),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(ScreenLeafPainter old) =>
      leaf != old.leaf || paper != old.paper || insets != old.insets;
}
