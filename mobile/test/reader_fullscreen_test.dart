import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/features/reader/data/reader_platform.dart';
import 'package:sorryread_mobile/features/reader/data/reader_fonts.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_bottom_fade.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_curl.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_preferences.dart';

import 'reader_page_test.dart' show mountReader, flushReader, settleReader;

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('READER_POLISH_SCREENSHOTS')) return;
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('reader-review')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../artifacts/reader-polish-preview/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Register native fonts outside each widget test's fake async zone.
    await ReaderFonts().load('sourceHan');
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/sourceHan.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final mode in PageMode.values) {
    for (final night in [false, true]) {
      testWidgets(
        '${mode.name} full screen and compact fade ${night ? 'night' : 'day'}',
        (tester) async {
          final prefs = ReaderPreferences(
            mode: mode,
            night: night,
            palette: 3,
            font: 'sourceHan',
          );
          await mountReader(
            tester,
            preferences: prefs,
            safePadding: const FakeViewPadding(top: 44, bottom: 24),
          );
          final body = find.byKey(const Key('reader-content'));
          final fade = tester.getRect(
            find.byKey(const Key('reader-bottom-fade')),
          );
          final status = tester.getRect(
            find.byKey(const Key('reader-status-bar')),
          );
          expect(tester.getRect(body).top, 0);
          expect(status.height, closeTo(16, .01));
          expect(status.bottom, closeTo(844 - 24 - 12, .01));
          expect(status.top, greaterThan(fade.top + ReaderBottomFade.extent));
          expect(
            tester
                .widget<ReaderBottomFade>(find.byType(ReaderBottomFade))
                .background,
            prefs.background,
          );
          if (mode != PageMode.scroll) {
            final paint = tester
                .widgetList<CustomPaint>(
                  find.descendant(of: body, matching: find.byType(CustomPaint)),
                )
                .singleWhere((p) => p.painter is ScreenLeafPainter);
            final painter = paint.painter! as ScreenLeafPainter;
            expect(painter.insets.top, 0);
            // All page slices stay fully readable above the gradient. Only the
            // next-page preview occupies the fading band and will repeat in full.
            for (final slice in painter.leaf.slices) {
              expect(
                slice.y + slice.bottom - slice.top,
                lessThanOrEqualTo(fade.top + .01),
              );
            }
            final preview = tester.getRect(
              find.byKey(const Key('reader-page-tail')),
            );
            expect(preview.top, closeTo(fade.top, .01));
            await tester.tapAt(Offset(tester.getRect(body).right - 15, 350));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          } else {
            final padding = tester
                .widgetList<Padding>(
                  find.descendant(of: body, matching: find.byType(Padding)),
                )
                .first;
            expect((padding.padding as EdgeInsets).top, 0);
            await tester.drag(body, const Offset(0, -110));
            await tester.pumpAndSettle();
          }
          await capture(tester, '${mode.name}-${night ? 'night' : 'day'}');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'favorite action toggles, survives re-entry and follows repository updates',
    (tester) async {
      await mountReader(
        tester,
        preferences: const ReaderPreferences(font: 'sourceHan'),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderApp)),
      );
      final sync = await container.read(syncRepositoryProvider.future);
      final book = (await tester.runAsync(sync.books))!.single;
      final body = find.byKey(const Key('reader-content'));
      await tester.tapAt(tester.getCenter(body));
      await tester.pumpAndSettle();
      expect(find.text('添加到书架').hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const Key('reader-favorite')));
      await tester.tap(find.byKey(const Key('reader-favorite')));
      await flushReader(tester);
      expect((await tester.runAsync(sync.books))!.single.favorite, isTrue);
      expect(find.text('已在书架').hitTestable(), findsOneWidget);
      await capture(tester, 'menu-in-bookshelf');
      await tester.tap(find.byKey(const Key('reader-favorite')));
      await flushReader(tester);
      expect((await tester.runAsync(sync.books))!.single.favorite, isFalse);
      expect(find.text('添加到书架').hitTestable(), findsOneWidget);
      await capture(tester, 'menu-add-to-bookshelf');
      await tester.runAsync(() => sync.setFavorite(book, true));
      await flushReader(tester);
      expect(find.text('已在书架').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('返回书架').hitTestable());
      await flushReader(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试书籍 0').last);
      await settleReader(tester);
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('reader-content'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('已在书架').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large text menu fits a small screen', (tester) async {
    await mountReader(
      tester,
      size: const Size(320, 640),
      scale: 2,
      preferences: const ReaderPreferences(
        mode: PageMode.none,
        font: 'sourceHan',
      ),
    );
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reader-content'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('添加到书架').hitTestable(), findsOneWidget);
    await capture(tester, 'menu-large-text');
    expect(tester.takeException(), isNull);
  });

  test('native bridge enables and restores reader cutout mode', () async {
    final calls = <bool>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
      if (call.method == 'readerFullscreen') calls.add(call.arguments as bool);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(ReaderPlatform.channel, null),
    );
    await ReaderPlatform().fullscreen(true);
    await ReaderPlatform().fullscreen(false);
    expect(calls, [true, false]);
  });
}
