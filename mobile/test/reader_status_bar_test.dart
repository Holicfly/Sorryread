import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/reader/data/reader_platform.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_asset_icon.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_status_bar.dart';

void main() {
  test('battery artwork follows charge state and level boundaries', () {
    expect(readerBatteryIcon(100, true), 'battery_charging');
    expect(readerBatteryIcon(20, false), 'battery_low');
    expect(readerBatteryIcon(21, false), 'battery_medium');
    expect(readerBatteryIcon(50, false), 'battery_medium');
    expect(readerBatteryIcon(51, false), 'battery_high');
    expect(readerBatteryIcon(94, false), 'battery_high');
    expect(readerBatteryIcon(95, false), 'battery_full');
  });
  for (final width in [272.0, 342.0, 760.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('status stays symmetric at $width with text scale $scale', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: width,
                    child: ReaderStatusBar(
                      level: 100,
                      charging: true,
                      time: DateTime(2026, 10, 26, 16, 32),
                      chapterTitle: '第108章 ${'很长的章节名称' * 8}',
                      ink: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final bar = tester.getRect(find.byKey(const Key('reader-status-bar')));
        final chapter = tester.getRect(
          find.byKey(const Key('reader-chapter-status')),
        );
        final battery = tester.getRect(
          find.byKey(const Key('reader-battery-status')),
        );
        final clock = tester.getRect(
          find.byKey(const Key('reader-clock-status')),
        );
        final icon = tester.getRect(find.byType(ReaderAssetIcon));
        final level = tester.getRect(find.text('100%'));
        expect(icon.width / icon.height, closeTo(2, .01));
        expect(icon.height, lessThanOrEqualTo(level.height));
        expect(icon.center.dy, closeTo(level.center.dy, .01));
        expect(chapter.center.dx, closeTo(bar.center.dx, .01));
        expect(battery.left, closeTo(bar.left, .01));
        expect(clock.right, closeTo(bar.right, .01));
        expect(battery.right, lessThan(chapter.left));
        expect(clock.left, greaterThan(chapter.right));
        expect(find.text('16:32'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('all supplied reader artwork loads and inherits palette ink', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              for (final name in [
                'catalog',
                'night',
                'day',
                'settings',
                'battery_low',
                'battery_medium',
                'battery_high',
                'battery_full',
                'battery_charging',
              ])
                ReaderAssetIcon(name, color: Colors.white),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final image in tester.widgetList<Image>(find.byType(Image))) {
      expect(image.color, Colors.white);
    }
    expect(find.byType(Image), findsNWidgets(9));
    expect(tester.takeException(), isNull);
  });
  testWidgets('native bridge exposes charging status with legacy fallback', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      ReaderPlatform.channel,
      (call) async =>
          call.method == 'batteryStatus' ? {'level': 82, 'charging': true} : 82,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(ReaderPlatform.channel, null),
    );
    var status = await ReaderPlatform().batteryStatus();
    expect(status.level, 82);
    expect(status.charging, isTrue);
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
      if (call.method == 'batteryStatus') throw MissingPluginException();
      return 73;
    });
    status = await ReaderPlatform().batteryStatus();
    expect(status.level, 73);
    expect(status.charging, isFalse);
  });
}
