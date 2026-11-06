import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> compareFooterPixels(
  List<int> idle,
  List<int> snapshot,
  Size size,
  Rect bounds,
  double ratio,
) {
  Rect inkBounds(List<int> bytes, Rect area) {
    var left = double.infinity,
        top = double.infinity,
        right = 0.0,
        bottom = 0.0;
    final width = (size.width * ratio).round();
    for (
      var y = (area.top * ratio).ceil();
      y < (area.bottom * ratio).floor();
      y++
    ) {
      for (
        var x = (area.left * ratio).ceil();
        x < (area.right * ratio).floor();
        x++
      ) {
        final i = (y * width + x) * 4;
        if (bytes[i] < 210 && bytes[i + 1] < 210) {
          left = left < x ? left : x.toDouble();
          right = right > x ? right : x.toDouble();
          top = top < y ? top : y.toDouble();
          bottom = bottom > y ? bottom : y.toDouble();
        }
      }
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  final side = bounds.width * .23;
  final areas = {
    'clock': Rect.fromLTWH(bounds.left, bounds.top, side, bounds.height),
    'chapter': Rect.fromLTRB(
      bounds.left + side + 10,
      bounds.top,
      bounds.right - side - 10,
      bounds.bottom,
    ),
    'battery': Rect.fromLTWH(
      bounds.right - side,
      bounds.top,
      side,
      bounds.height,
    ),
  };
  return [
    for (final entry in areas.entries)
      (() {
        final before = inkBounds(idle, entry.value);
        final during = inkBounds(snapshot, entry.value);
        expect(before.isFinite && during.isFinite, isTrue, reason: entry.key);
        return <String, dynamic>{
          'name': entry.key,
          'idleWidth': before.width,
          'idleHeight': before.height,
          'snapshotWidth': during.width,
          'snapshotHeight': during.height,
        };
      })(),
  ];
}

void expectFooterSizes(List<Map<String, dynamic>> metrics) {
  for (final item in metrics) {
    expect(
      item['snapshotWidth'],
      closeTo(item['idleWidth'] as num, 2),
      reason: '$item',
    );
    expect(
      item['snapshotHeight'],
      closeTo(item['idleHeight'] as num, 2),
      reason: '$item',
    );
  }
}

Future<(List<int>, ui.Image)> footerPicturePixels(
  ui.Picture picture,
  Size size,
  double ratio,
) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..scale(ratio)
    ..drawPicture(picture);
  final scaled = recorder.endRecording();
  final image = await scaled.toImage(
    (size.width * ratio).round(),
    (size.height * ratio).round(),
  );
  scaled.dispose();
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List()
      .toList();
  return (bytes, image);
}
