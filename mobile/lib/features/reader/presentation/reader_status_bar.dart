import 'package:flutter/material.dart';

import 'reader_asset_icon.dart';

String readerBatteryIcon(int? level, bool charging) {
  if (charging) return 'battery_charging';
  if (level == null || level <= 20) return 'battery_low';
  if (level <= 50) return 'battery_medium';
  if (level < 95) return 'battery_high';
  return 'battery_full';
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
      style: Theme.of(context).textTheme.bodySmall!.copyWith(
        fontSize: 11,
        height: 1.2,
        color: ink.withValues(alpha: .65),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sideWidth = (constraints.maxWidth * .24).clamp(60.0, 86.0);
          return Row(
            key: const Key('reader-status-bar'),
            children: [
              SizedBox(
                width: sideWidth,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      key: const Key('reader-battery-status'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ReaderAssetIcon(
                          readerBatteryIcon(level, charging),
                          color: ink.withValues(alpha: .65),
                          size: 20,
                          height: 10,
                        ),
                        const SizedBox(width: 4),
                        Text(level == null ? '—' : '$level%'),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    chapterTitle,
                    key: const Key('reader-chapter-status'),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              SizedBox(
                width: sideWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                      key: const Key('reader-clock-status'),
                    ),
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
