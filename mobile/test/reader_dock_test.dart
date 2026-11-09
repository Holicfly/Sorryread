import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_dock.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_preferences.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_settings_sheet.dart';

import 'reader_page_test.dart' show mountReader;
import 'reader_fullscreen_test.dart' show capture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/sourceHan.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'dock grows upward with no modal barrier and leaves central footer visible',
    (tester) async {
      await mountReader(
        tester,
        size: const Size(400, 869),
        safePadding: const FakeViewPadding(bottom: 24),
      );
      final content = find.byKey(const Key('reader-content'));
      await tester.tapAt(tester.getCenter(content));
      await tester.pumpAndSettle();
      final dock = find.byKey(const Key('reader-floating-dock'));
      final basic = tester.getRect(dock);
      expect(basic.left, 16);
      expect(basic.right, 384);
      expect(basic.bottom, 869 - 34);
      final status = tester.getRect(find.byKey(const Key('reader-status-bar')));
      expect(status.top, greaterThan(basic.bottom));
      expect(status.left, greaterThanOrEqualTo(64));
      expect(status.right, lessThanOrEqualTo(336));
      await capture(tester, 'dock-basic');
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      expect(tester.getRect(dock).bottom, basic.bottom);
      expect(tester.getRect(dock).top, lessThan(basic.top));
      expect(find.byType(ModalBarrier).hitTestable(), findsNothing);
      expect(find.byType(Switch), findsNothing);
      final row = tester.getRect(find.byKey(const Key('reader-light-row')));
      expect(
        row.contains(
          tester.getCenter(find.byKey(const Key('reader-brightness'))),
        ),
        isTrue,
      );
      expect(
        row.contains(
          tester.getCenter(find.byKey(const Key('reader-eye-care'))),
        ),
        isTrue,
      );
      await capture(tester, 'dock-settings');
      await tester.tap(find.byKey(const Key('reader-eye-care')));
      await tester.pumpAndSettle();
      final sheet = tester.widget<ReaderSettingsSheet>(
        find.byType(ReaderSettingsSheet),
      );
      expect(sheet.preferences.value.eyeCare, isTrue);
      await capture(tester, 'dock-eye-care');
      await tester.tap(find.text('目录').hitTestable());
      await tester.pumpAndSettle();
      expect(tester.getRect(dock).bottom, basic.bottom);
      expect(find.byKey(const Key('reader-dock-catalog')), findsOneWidget);
      await capture(tester, 'dock-catalog');
      final expanded = tester.getRect(dock);
      await tester.tap(find.text('目录').hitTestable());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 130));
      final collapsing = tester.getRect(dock);
      expect(collapsing.top, greaterThan(expanded.top));
      expect(collapsing.top, lessThan(basic.top));
      expect(find.byKey(const Key('reader-dock-catalog')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.getRect(dock), basic);
      expect(find.byKey(const Key('reader-dock-catalog')), findsNothing);
      await tester.tapAt(const Offset(200, 160));
      await tester.pumpAndSettle();
      expect(tester.getRect(dock).top, greaterThan(869));
      expect(
        tester.widget<ReaderDock>(find.byType(ReaderDock)).visible,
        isFalse,
      );
    },
  );

  testWidgets('expanded settings fit compact screen with large text', (
    tester,
  ) async {
    final handler = FlutterError.onError;
    FlutterError.onError = (details) {
      debugPrint(details.toString());
      handler!(details);
    };
    try {
      await mountReader(tester, size: const Size(320, 640), scale: 2);
      await tester.tapAt(const Offset(160, 220));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
      await capture(tester, 'dock-large-settings');
    } finally {
      FlutterError.onError = handler;
    }
  });

  testWidgets('reader dock keeps the main gap without a navigation inset', (
    tester,
  ) async {
    await mountReader(tester, size: const Size(390, 844));
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reader-content'))),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const Key('reader-floating-dock'))).bottom,
      834,
    );
    final footer = find.byKey(const Key('reader-status-overlay'));
    expect(tester.widget<Opacity>(footer).opacity, 0);
    await tester.tapAt(const Offset(195, 220));
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(footer).opacity, 1);
  });

  testWidgets('comic chapter buttons flank the progress slider on one row', (
    tester,
  ) async {
    double? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderDockControls(
            preferences: const ReaderPreferences(),
            progress: .25,
            onProgressChanged: (value) => selected = value,
            onPrevious: () {},
            onNext: () {},
            chapterUnit: '话',
            actions: const [],
          ),
        ),
      ),
    );
    final slider = find.byKey(const Key('reader-progress'));
    final previous = tester.getCenter(find.text('上一话'));
    final next = tester.getCenter(find.text('下一话'));
    final progress = tester.getRect(slider);
    expect(previous.dx, lessThan(progress.left));
    expect(next.dx, greaterThan(progress.right));
    expect(previous.dy, closeTo(progress.center.dy, 1));
    expect(next.dy, closeTo(progress.center.dy, 1));
    await tester.tapAt(progress.center);
    expect(selected, closeTo(.5, .02));
  });

  test(
    'eye care keeps every palette readable and does not wash out dark paper',
    () {
      for (var palette = 0; palette < 6; palette++) {
        final p = ReaderPreferences(palette: palette, eyeCare: true);
        final a = p.background.computeLuminance(), b = p.ink.computeLuminance();
        final contrast = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(contrast, greaterThan(7));
        if (palette >= 4) expect(a, lessThan(.04));
      }
    },
  );
}
