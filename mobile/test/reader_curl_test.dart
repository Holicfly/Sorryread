import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_curl.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const size = Size(400, 870);

  test('fold bisects the corner and touch and reflection swaps them', () {
    for (final corner in [const Offset(400, 0), const Offset(400, 870)]) {
      final touch = Offset(170, corner.dy == 0 ? 145 : 725);
      final geometry = CurlGeometry(size, corner, touch);
      for (final fold in [geometry.horizontalFold, geometry.verticalFold]) {
        expect(
          (fold - corner).distance,
          closeTo((fold - touch).distance, .00001),
        );
      }
      final reflection = geometry.reflection;
      final reflected = Offset(
        reflection[0] * corner.dx + reflection[4] * corner.dy + reflection[12],
        reflection[1] * corner.dx + reflection[5] * corner.dy + reflection[13],
      );
      expect((reflected - touch).distance, lessThan(.00001));
    }
  });

  test('horizontal pulls retain finite curved folds at both page edges', () {
    for (final y in [0.0, 870.0]) {
      final geometry = CurlGeometry(size, Offset(400, y), Offset(180, y));
      expect(geometry.lifted.computeMetrics().single.length.isFinite, isTrue);
      expect(geometry.verticalFold.dy.isFinite, isTrue);
      expect(geometry.horizontalFold.dx, closeTo(290, .001));
      expect(geometry.verticalFold.dy, lessThan(-10000));
      expect(geometry.reflection.every((number) => number.isFinite), isTrue);
    }
  });

  test('dragging far across the page corrects an out-of-bounds edge', () {
    final geometry = CurlGeometry(
      size,
      const Offset(400, 870),
      const Offset(390, 100),
    );
    expect(geometry.finger, isNot(const Offset(390, 100)));
    expect(
      geometry.horizontalEdge.dx,
      inInclusiveRange(-.001, size.width + .001),
    );
    expect(geometry.lifted.computeMetrics().single.length.isFinite, isTrue);
  });

  test(
    'page corners and off-page touches never produce non-finite geometry',
    () {
      for (final point in [
        const Offset(400, 870),
        const Offset(400, 400),
        const Offset(399.9999, 870),
        const Offset(400, 869.9999),
        const Offset(-400, 870),
        const Offset(800, 870),
        const Offset(150, -100),
        const Offset(10, 950),
      ]) {
        final geometry = CurlGeometry(size, const Offset(400, 870), point);
        for (final offset in [
          geometry.finger,
          geometry.horizontalFold,
          geometry.verticalFold,
          geometry.horizontalEdge,
          geometry.verticalEdge,
          geometry.horizontalJoin,
          geometry.verticalJoin,
        ]) {
          expect(
            offset.dx.isFinite && offset.dy.isFinite,
            isTrue,
            reason: '$point => $offset',
          );
        }
        expect(geometry.reflection.every((number) => number.isFinite), isTrue);
      }
    },
  );
  test('paper back is mirrored only inside its own curved polygon', () async {
    const pageSize = Size(200, 300);
    const corner = Offset(200, 300);
    const finger = Offset(70, 210);
    ui.Picture solid(Color color) {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(color, BlendMode.src);
      return recorder.endRecording();
    }

    final front = solid(const Color(0xffe6140a));
    final under = solid(const Color(0xff0f28e6));
    final recorder = ui.PictureRecorder();
    PaperCurlPainter(
      front: front,
      under: under,
      corner: corner,
      finger: finger,
      paper: Colors.white,
    ).paint(Canvas(recorder), pageSize);
    final picture = recorder.endRecording();
    final image = await picture.toImage(200, 300);
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final geometry = CurlGeometry(pageSize, corner, finger);
    final lifted = geometry.lifted;
    final back = geometry.back;
    final counts = [0, 0, 0];
    for (var y = 5; y < 295; y += 7) {
      for (var x = 5; x < 195; x += 7) {
        final point = Offset(x.toDouble(), y.toDouble());
        final inLift = lifted.contains(point);
        final inBack = back.contains(point);
        final neighbors = [
          point + const Offset(2, 0),
          point - const Offset(2, 0),
          point + const Offset(0, 2),
          point - const Offset(0, 2),
        ];
        if (neighbors.any(
          (p) => lifted.contains(p) != inLift || back.contains(p) != inBack,
        )) {
          continue;
        }
        final index = (y * 200 + x) * 4;
        final r = pixels.getUint8(index), b = pixels.getUint8(index + 2);
        if (!inLift) {
          counts[0]++;
          expect(r, greaterThan(b));
        } else if (!inBack) {
          counts[1]++;
          expect(b, greaterThan(r));
        } else {
          counts[2]++;
          expect(
            r,
            greaterThan(b),
            reason: 'The back must contain the mirrored front at $point',
          );
        }
      }
    }
    expect(counts.every((count) => count > 10), isTrue, reason: '$counts');
    image.dispose();
    picture.dispose();
    front.dispose();
    under.dispose();
  });
  test('curved paper faces tile the lifted region without next-page slivers', () async {
    const pageSize = Size(200, 300);
    ui.Picture solid(Color color) {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(color, BlendMode.src);
      return recorder.endRecording();
    }

    final front = solid(Colors.white);
    final under = solid(Colors.blue);
    for (final top in [false, true]) {
      for (final x in [50.0, 110.0, 170.0]) {
        final corner = Offset(200, top ? 0 : 300);
        final finger = Offset(x, top ? 75 : 225);
        final geometry = CurlGeometry(pageSize, corner, finger);
        final lifted = geometry.lifted;
        final back = geometry.back;
        final exposed = geometry.exposed;
        final recorder = ui.PictureRecorder();
        PaperCurlPainter(
          front: front,
          under: under,
          corner: corner,
          finger: finger,
          paper: Colors.white,
        ).paint(Canvas(recorder), pageSize);
        final picture = recorder.endRecording();
        final image = await picture.toImage(200, 300);
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        for (var y = .5; y < 300; y++) {
          for (var px = .5; px < 200; px++) {
            final point = Offset(px, y);
            if (!lifted.contains(point)) continue;
            expect(
              back.contains(point) || exposed.contains(point),
              isTrue,
              reason: 'Uncovered curved paper at $point, top=$top, x=$x',
            );
            if (!back.contains(point) ||
                [
                  const Offset(1, 0),
                  const Offset(-1, 0),
                  const Offset(0, 1),
                  const Offset(0, -1),
                ].any((d) => !back.contains(point + d))) {
              continue;
            }
            final i = (y.floor() * 200 + px.floor()) * 4;
            expect(
              (pixels.getUint8(i) - pixels.getUint8(i + 2)).abs(),
              lessThanOrEqualTo(2),
              reason:
                  'Blue next page leaked through the paper at $point, top=$top',
            );
          }
        }
        image.dispose();
        picture.dispose();
      }
    }
    front.dispose();
    under.dispose();
  });
  test('top and bottom corner shadows are vertical mirrors', () async {
    const pageSize = Size(200, 300);
    final white = ui.PictureRecorder();
    Canvas(white).drawColor(Colors.white, BlendMode.src);
    final page = white.endRecording();
    final samples = <List<int>>[];
    for (final top in [false, true]) {
      final recorder = ui.PictureRecorder();
      PaperCurlPainter(
        front: page,
        under: page,
        corner: Offset(200, top ? 0 : 300),
        finger: Offset(90, top ? 90 : 210),
        paper: Colors.white,
        pixelRatio: 3,
      ).paint(Canvas(recorder), pageSize);
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 300);
      samples.add(
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
            .asUint8List()
            .toList(),
      );
      image.dispose();
      picture.dispose();
    }
    var difference = 0;
    for (var y = 0; y < 300; y++) {
      for (var x = 0; x < 200; x++) {
        difference +=
            (samples[0][(y * 200 + x) * 4] -
                    samples[1][((299 - y) * 200 + x) * 4])
                .abs();
      }
    }
    expect(difference / (200 * 300), lessThan(.2));
    page.dispose();
  });
  test('edge shadows darken the flat page and folded back at either horizontal edge', () async {
    const pageSize = Size(200, 300);
    final white = ui.PictureRecorder();
    Canvas(white).drawColor(Colors.white, BlendMode.src);
    final page = white.endRecording();
    for (final top in [false, true]) {
      final corner = Offset(200, top ? 0 : 300);
      final finger = Offset(90, top ? 90 : 210);
      final geometry = CurlGeometry(pageSize, corner, finger);
      final lifted = geometry.lifted;
      final back = geometry.back;
      final recorder = ui.PictureRecorder();
      PaperCurlPainter(
        front: page,
        under: page,
        corner: corner,
        finger: finger,
        paper: Colors.white,
      ).paint(Canvas(recorder), pageSize);
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 300);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var flat = 0, folded = 0, exposed = 0;
      for (var y = 1; y < 299; y++) {
        for (var x = 1; x < 199; x++) {
          final color = bytes.getUint8((y * 200 + x) * 4);
          if (color >= 250) {
            continue;
          }
          final point = Offset(x.toDouble(), y.toDouble());
          if (!lifted.contains(point)) {
            flat++;
          } else if (back.contains(point)) {
            folded++;
          } else {
            exposed++;
          }
        }
      }
      expect(
        flat,
        greaterThan(10),
        reason: 'Missing flat edge shadow, top=$top',
      );
      expect(
        folded,
        greaterThan(10),
        reason: 'Missing folded edge shadow, top=$top',
      );
      if (!top) {
        expect(
          exposed,
          greaterThan(10),
          reason: 'Missing underlying edge shadow',
        );
      }
      final oppositeY = top ? 298 : 1;
      for (var x = 1; x < 199; x++) {
        expect(bytes.getUint8((oppositeY * 200 + x) * 4), 255);
      }
      image.dispose();
      picture.dispose();
    }
    page.dispose();
  });
}
