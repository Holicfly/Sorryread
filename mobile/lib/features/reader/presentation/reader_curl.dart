import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'reader_layout.dart';
import 'reader_status_bar.dart';

/// The corner and touch point are reflections across the fold.
class CurlGeometry {
  factory CurlGeometry(Size size, Offset corner, Offset finger) {
    var touch = finger;
    final edge = corner + (_horizontalFold(corner, touch) - corner) * 1.5;
    if (touch.dx > 0 &&
        touch.dx < size.width &&
        (edge.dx < 0 || edge.dx > size.width)) {
      final edgeX = edge.dx < 0 ? size.width - edge.dx : edge.dx;
      final dx = (corner.dx - touch.dx).abs();
      final x = (corner.dx - size.width * dx / edgeX).abs();
      final y =
          (corner.dy -
                  (corner.dx - x).abs() * (corner.dy - touch.dy).abs() / dx)
              .abs();
      touch = Offset(x, y);
    }
    return CurlGeometry._(corner, touch);
  }

  CurlGeometry._(this.corner, this.finger)
    : normal = (corner - finger).distance < .000001
          ? const Offset(1, 0)
          : (corner - finger) / (corner - finger).distance,
      midpoint = (corner + finger) / 2;

  final Offset corner, finger, normal, midpoint;

  static Offset _horizontalFold(Offset corner, Offset finger) {
    final middle = (corner + finger) / 2;
    final dx = corner.dx - middle.dx;
    final divisor = dx.abs() < .1 ? (dx < 0 ? -.1 : .1) : dx;
    final dy = corner.dy - middle.dy;
    return Offset(middle.dx - dy * dy / divisor, corner.dy);
  }

  late final Offset horizontalFold = _horizontalFold(corner, finger);
  late final Offset verticalFold = _verticalFold();

  Offset _verticalFold() {
    final dx = corner.dx - midpoint.dx;
    final dy = corner.dy - midpoint.dy;
    // Keep the curved fold for a horizontal pull. The remote intercept is
    // clipped to the page by the painter, just as in FramePager.
    final divisor = dy.abs() < .1 ? (dy < 0 ? -.1 : .1) : dy;
    return Offset(corner.dx, midpoint.dy - dx * dx / divisor);
  }

  late final Offset horizontalEdge = corner + (horizontalFold - corner) * 1.5;
  late final Offset verticalEdge = corner + (verticalFold - corner) * 1.5;
  late final Offset horizontalJoin = _intersect(
    finger,
    horizontalFold,
    horizontalEdge,
    verticalEdge,
  );
  late final Offset verticalJoin = _intersect(
    finger,
    verticalFold,
    horizontalEdge,
    verticalEdge,
  );

  static Offset _intersect(Offset a, Offset b, Offset c, Offset d) {
    final first = b - a;
    final second = d - c;
    final denominator = first.dx * second.dy - first.dy * second.dx;
    if (denominator.abs() < .00000001) return (a + b) / 2;
    final delta = c - a;
    final along = (delta.dx * second.dy - delta.dy * second.dx) / denominator;
    return a + first * along;
  }

  late final Offset horizontalCurve =
      (horizontalEdge + horizontalFold * 2 + horizontalJoin) / 4;
  late final Offset verticalCurve =
      (verticalEdge + verticalFold * 2 + verticalJoin) / 4;

  Path get lifted => Path()
    ..moveTo(horizontalEdge.dx, horizontalEdge.dy)
    ..quadraticBezierTo(
      horizontalFold.dx,
      horizontalFold.dy,
      horizontalJoin.dx,
      horizontalJoin.dy,
    )
    ..lineTo(finger.dx, finger.dy)
    ..lineTo(verticalJoin.dx, verticalJoin.dy)
    ..quadraticBezierTo(
      verticalFold.dx,
      verticalFold.dy,
      verticalEdge.dx,
      verticalEdge.dy,
    )
    ..lineTo(corner.dx, corner.dy)
    ..close();

  Path get exposed => Path()
    ..moveTo(horizontalEdge.dx, horizontalEdge.dy)
    ..quadraticBezierTo(
      (horizontalEdge.dx + horizontalFold.dx) / 2,
      (horizontalEdge.dy + horizontalFold.dy) / 2,
      horizontalCurve.dx,
      horizontalCurve.dy,
    )
    ..lineTo(verticalCurve.dx, verticalCurve.dy)
    ..quadraticBezierTo(
      (verticalFold.dx + verticalEdge.dx) / 2,
      (verticalFold.dy + verticalEdge.dy) / 2,
      verticalEdge.dx,
      verticalEdge.dy,
    )
    ..lineTo(corner.dx, corner.dy)
    ..close();

  // Split both Beziers at t=.5 so the back and exposed page share the full
  // curved outline. Straight chords here leave thin strips of the next page.
  Path get back => Path()
    ..moveTo(verticalCurve.dx, verticalCurve.dy)
    ..lineTo(horizontalCurve.dx, horizontalCurve.dy)
    ..quadraticBezierTo(
      (horizontalFold.dx + horizontalJoin.dx) / 2,
      (horizontalFold.dy + horizontalJoin.dy) / 2,
      horizontalJoin.dx,
      horizontalJoin.dy,
    )
    ..lineTo(finger.dx, finger.dy)
    ..lineTo(verticalJoin.dx, verticalJoin.dy)
    ..quadraticBezierTo(
      (verticalJoin.dx + verticalFold.dx) / 2,
      (verticalJoin.dy + verticalFold.dy) / 2,
      verticalCurve.dx,
      verticalCurve.dy,
    )
    ..close();

  Float64List get reflection {
    final xx = 1 - 2 * normal.dx * normal.dx;
    final yy = 1 - 2 * normal.dy * normal.dy;
    final xy = -2 * normal.dx * normal.dy;
    return Float64List.fromList([
      xx,
      xy,
      0,
      0,
      xy,
      yy,
      0,
      0,
      0,
      0,
      1,
      0,
      midpoint.dx - xx * midpoint.dx - xy * midpoint.dy,
      midpoint.dy - xy * midpoint.dx - yy * midpoint.dy,
      0,
      1,
    ]);
  }
}

/// The text is recorded once per turn, then replayed on the flat and folded faces.
class PaperCurlPainter extends CustomPainter {
  PaperCurlPainter({
    required this.front,
    required this.under,
    required this.corner,
    required this.finger,
    required this.paper,
    this.pixelRatio = 1,
  });

  final ui.Picture front;
  final ui.Picture? under;
  final Offset corner, finger;
  final Color paper;
  final double pixelRatio;

  static ui.Picture record(
    ReaderLeaf leaf,
    Color paper,
    EdgeInsets insets,
    Size size, {
    ReaderPageFooter? footer,
  }) {
    final recorder = ui.PictureRecorder();
    ScreenLeafPainter(
      leaf,
      paper,
      insets,
      footer: footer,
    ).paint(Canvas(recorder), size);
    return recorder.endRecording();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawColor(paper, BlendMode.src);
    if (finger.dx <= -size.width) {
      if (under != null) canvas.drawPicture(under!);
      canvas.restore();
      return;
    }
    if ((corner - finger).distance < .5 || finger.dx >= size.width * 2) {
      canvas.drawPicture(front);
      canvas.restore();
      return;
    }

    final geometry = CurlGeometry(size, corner, finger);
    final lifted = geometry.lifted;
    final back = geometry.back;
    final sheet = Path()..addRect(rect);
    final width = math.min((geometry.finger - corner).distance, size.width) / 3;

    canvas.save();
    canvas.clipPath(Path.combine(PathOperation.difference, sheet, lifted));
    canvas.drawPicture(front);
    canvas.restore();

    canvas.save();
    canvas.clipPath(lifted);
    canvas.clipPath(geometry.exposed);
    if (under != null) canvas.drawPicture(under!);
    canvas.restore();

    final dark = paper.computeLuminance() < .15;
    final shade = Color.lerp(
      paper,
      Colors.black,
      dark ? .9 : .38,
    )!.withValues(alpha: dark ? .4 : .31);
    final diagonal = math.sqrt(
      size.width * size.width + size.height * size.height,
    );
    // Paint all shadows in bottom-corner coordinates. Mirroring this frame
    // gives the top corner the same widths, directions and gradient coverage.
    final top = corner.dy == 0;
    final shadowGeometry = top
        ? CurlGeometry(
            size,
            Offset(corner.dx, size.height),
            Offset(geometry.finger.dx, size.height - geometry.finger.dy),
          )
        : geometry;
    void shadowFrame() {
      if (top) {
        canvas.translate(0, size.height);
        canvas.scale(1, -1);
      }
    }

    final angle = math.atan2(
      shadowGeometry.horizontalFold.dx - shadowGeometry.corner.dx,
      shadowGeometry.verticalFold.dy - shadowGeometry.corner.dy,
    );

    canvas.save();
    shadowFrame();
    canvas.clipPath(shadowGeometry.lifted);
    canvas.clipPath(shadowGeometry.exposed);
    _paperEdgeShadow(
      canvas,
      shadowGeometry.horizontalEdge,
      angle,
      width,
      diagonal,
      shade,
      reverse: false,
    );
    canvas.restore();

    canvas.save();
    shadowFrame();
    _frontEdgeShadows(
      canvas,
      shadowGeometry,
      shadowGeometry.lifted,
      diagonal,
      shade,
    );
    canvas.restore();

    canvas.save();
    canvas.clipPath(lifted);
    canvas.clipPath(back);
    // Reflection can move parts of the source picture outside its bounds.
    // The paper stays opaque even where the reflected picture has no pixels.
    canvas.drawRect(rect, Paint()..color = paper);
    canvas.save();
    canvas.transform(geometry.reflection);
    canvas.drawPicture(front);
    canvas.restore();
    canvas.drawRect(rect, Paint()..color = paper.withAlpha(200));
    canvas.restore();
    final backWidth = math.min(
      width,
      math.min(
        (geometry.horizontalEdge.dx - geometry.horizontalFold.dx).abs() / 2,
        (geometry.verticalEdge.dy - geometry.verticalFold.dy).abs() / 2,
      ),
    );
    canvas.save();
    shadowFrame();
    canvas.clipPath(shadowGeometry.lifted);
    canvas.clipPath(shadowGeometry.back);
    _paperEdgeShadow(
      canvas,
      shadowGeometry.horizontalEdge,
      angle,
      backWidth,
      diagonal,
      shade,
      reverse: true,
    );
    canvas.restore();
    canvas.restore();
  }

  void _paperEdgeShadow(
    Canvas canvas,
    Offset origin,
    double angle,
    double width,
    double length,
    Color shade, {
    required bool reverse,
  }) {
    if (width <= .0001) return;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.rotate(angle);
    canvas.drawRect(
      Rect.fromLTRB(-width, 0, 0, length),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(-width, 0),
          Offset.zero,
          reverse
              ? [shade, shade.withValues(alpha: 0)]
              : [shade.withValues(alpha: 0), shade],
        ),
    );
    canvas.restore();
  }

  void _frontEdgeShadows(
    Canvas canvas,
    CurlGeometry geometry,
    Path lifted,
    double length,
    Color shade,
  ) {
    final finger = geometry.finger;
    final width = math.min(
      16 / pixelRatio,
      math.min(
        (finger - geometry.horizontalJoin).distance,
        (finger - geometry.verticalJoin).distance,
      ),
    );
    if (width <= .0001) return;
    final e = geometry.horizontalFold;
    final i = geometry.verticalFold;
    final farAngle =
        math.pi / 4 - math.atan2(finger.dy - e.dy, finger.dx - e.dx);
    final far =
        finger +
        Offset(
          math.cos(farAngle) * width * math.sqrt2,
          -math.sin(farAngle) * width * math.sqrt2,
        );
    final horizontal = Path()
      ..moveTo(far.dx, far.dy)
      ..lineTo(finger.dx, finger.dy)
      ..lineTo(e.dx, e.dy)
      ..lineTo(geometry.horizontalEdge.dx, geometry.horizontalEdge.dy)
      ..close();
    canvas.save();
    canvas.clipPath(Path.combine(PathOperation.difference, horizontal, lifted));
    canvas.translate(e.dx, e.dy);
    canvas.rotate(math.atan2(finger.dx - e.dx, e.dy - finger.dy));
    canvas.drawRect(
      Rect.fromLTRB(-width, -length, 1 / pixelRatio, 0),
      Paint()
        ..shader = ui.Gradient.linear(Offset(-width, 0), Offset.zero, [
          shade.withValues(alpha: 0),
          shade,
        ]),
    );
    canvas.restore();

    final vertical = Path()
      ..moveTo(far.dx, far.dy)
      ..lineTo(finger.dx, finger.dy)
      ..lineTo(i.dx, i.dy)
      ..lineTo(geometry.verticalEdge.dx, geometry.verticalEdge.dy)
      ..close();
    final remoteY = i.dy < 0 ? i.dy - geometry.corner.dy : i.dy;
    final remoteDistance = math.sqrt(i.dx * i.dx + remoteY * remoteY);
    final left = remoteDistance > length ? -width - remoteDistance : -length;
    final right = remoteDistance > length ? length - remoteDistance : 0.0;
    canvas.save();
    canvas.clipPath(Path.combine(PathOperation.difference, vertical, lifted));
    canvas.translate(i.dx, i.dy);
    canvas.rotate(math.atan2(i.dy - finger.dy, i.dx - finger.dx));
    canvas.drawRect(
      Rect.fromLTRB(left, -width, right, 0),
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, -width), Offset.zero, [
          shade.withValues(alpha: 0),
          shade,
        ]),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(PaperCurlPainter old) =>
      front != old.front ||
      under != old.under ||
      corner != old.corner ||
      finger != old.finger ||
      paper != old.paper ||
      pixelRatio != old.pixelRatio;
}

class ScreenLeafPainter extends CustomPainter {
  ScreenLeafPainter(this.leaf, this.paper, this.insets, {this.footer});
  final ReaderLeaf leaf;
  final Color paper;
  final EdgeInsets insets;
  final ReaderPageFooter? footer;
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
    footer?.paint(canvas);
  }

  @override
  bool shouldRepaint(ScreenLeafPainter old) =>
      leaf != old.leaf ||
      paper != old.paper ||
      insets != old.insets ||
      footer != old.footer;
}
