import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'reader_asset_icon.dart';

String readerBatteryIcon(int? level, bool charging) {
  if (charging) return 'battery_charging';
  if (level == null || level <= 20) return 'battery_low';
  if (level <= 50) return 'battery_medium';
  if (level < 95) return 'battery_high';
  return 'battery_full';
}

TextStyle readerStatusTextStyle(TextStyle base, Color ink) => base.copyWith(
  fontSize: 11,
  height: 1.2,
  color: ink.withValues(alpha: .65),
  fontFeatures: const [FontFeature.tabularFigures()],
);

String readerClockLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// Frozen footer data recorded with each paper face at the start of a turn.
class ReaderPageFooter {
  const ReaderPageFooter({
    required this.bounds,
    required this.time,
    required this.chapterTitle,
    required this.level,
    required this.style,
    required this.scaler,
    required this.direction,
    this.locale,
    this.batteryImage,
  });

  final Rect bounds;
  final DateTime time;
  final String chapterTitle;
  final int? level;
  final TextStyle style;
  final TextScaler scaler;
  final TextDirection direction;
  final Locale? locale;
  final ui.Image? batteryImage;

  ReaderPageFooter withChapterTitle(String title) => ReaderPageFooter(
    bounds: bounds,
    time: time,
    chapterTitle: title,
    level: level,
    style: style,
    scaler: scaler,
    direction: direction,
    locale: locale,
    batteryImage: batteryImage,
  );

  void paint(Canvas canvas) {
    if (bounds.width <= 20 || bounds.height <= 0) return;
    TextPainter label(String text, {double maxWidth = double.infinity}) =>
        TextPainter(
          text: TextSpan(text: text, style: style),
          textScaler: scaler,
          textDirection: direction,
          locale: locale,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: maxWidth);
    final side = bounds.width * .23;
    final clock = label(readerClockLabel(time));
    final chapter = label(
      chapterTitle,
      maxWidth: math.max(0, bounds.width - side * 2 - 20),
    );
    final battery = label(level == null ? '—' : '$level%');
    final total = side * 2 + 20 + chapter.width;
    final left = bounds.center.dx - total / 2;

    void fittedText(TextPainter text, Rect box) {
      final scale = math.min(
        1.0,
        math.min(
          box.width / math.max(.001, text.width),
          box.height / math.max(.001, text.height),
        ),
      );
      canvas.save();
      canvas.translate(
        box.center.dx - text.width * scale / 2,
        box.center.dy - text.height * scale / 2,
      );
      canvas.scale(scale);
      text.paint(canvas, Offset.zero);
      canvas.restore();
    }

    fittedText(clock, Rect.fromLTWH(left, bounds.top, side, bounds.height));
    chapter.paint(
      canvas,
      Offset(left + side + 10, bounds.center.dy - chapter.height / 2),
    );
    final batteryBox = Rect.fromLTWH(
      left + side + 20 + chapter.width,
      bounds.top,
      side,
      bounds.height,
    );
    final batteryWidth = 21 + battery.width;
    final batteryHeight = math.max(9.0, battery.height);
    final scale = math.min(
      1.0,
      math.min(
        batteryBox.width / batteryWidth,
        batteryBox.height / batteryHeight,
      ),
    );
    canvas.save();
    canvas.translate(
      batteryBox.center.dx - batteryWidth * scale / 2,
      batteryBox.center.dy - batteryHeight * scale / 2,
    );
    canvas.scale(scale);
    final icon = Rect.fromLTWH(0, (batteryHeight - 9) / 2, 18, 9);
    final image = batteryImage;
    final ink = style.color ?? Colors.grey;
    if (image != null) {
      canvas.drawImageRect(
        image,
        const Rect.fromLTRB(2, 10, 46, 38),
        icon,
        Paint()..colorFilter = ColorFilter.mode(ink, BlendMode.srcIn),
      );
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(icon.deflate(.5), const Radius.circular(1)),
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      canvas.drawRect(
        Rect.fromLTWH(2, icon.top + 2, 12 * (level ?? 0) / 100, 5),
        Paint()..color = ink,
      );
    }
    battery.paint(canvas, Offset(21, (batteryHeight - battery.height) / 2));
    canvas.restore();
    clock.dispose();
    chapter.dispose();
    battery.dispose();
  }
}

class ReaderStatusBar extends StatelessWidget {
  static double heightFor(TextScaler scaler) =>
      (scaler.scale(11) * 1.2).clamp(16.0, double.infinity);
  const ReaderStatusBar({
    super.key,
    required this.level,
    required this.charging,
    required this.time,
    required this.chapterTitle,
    required this.ink,
  });
  final int? level;
  final bool charging;
  final DateTime time;
  final String chapterTitle;
  final Color ink;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: DefaultTextStyle(
      style: readerStatusTextStyle(Theme.of(context).textTheme.bodySmall!, ink),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Row(
            key: const Key('reader-status-bar'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: constraints.maxWidth * .23,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    readerClockLabel(time),
                    key: const Key('reader-clock-status'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  chapterTitle,
                  key: const Key('reader-chapter-status'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: constraints.maxWidth * .23,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    key: const Key('reader-battery-status'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ReaderAssetIcon(
                        readerBatteryIcon(level, charging),
                        color: ink.withValues(alpha: .65),
                        size: 18,
                        height: 9,
                      ),
                      const SizedBox(width: 3),
                      Text(level == null ? '—' : '$level%'),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
