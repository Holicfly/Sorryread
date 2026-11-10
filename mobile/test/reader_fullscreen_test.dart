import 'dart:async';
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
import 'package:sorryread_mobile/features/reader/presentation/reader_status_bar.dart';

import 'reader_page_test.dart' show mountReader, flushReader, settleReader;
import 'support/reader_footer_pixels.dart';

Future<void> capture(
  WidgetTester tester,
  String name, {
  String directory = '../artifacts/reader-polish-preview',
}) async {
  if (!const bool.fromEnvironment('READER_POLISH_SCREENSHOTS')) return;
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('reader-review')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$name.png');
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
        '${mode.name} full screen and mode-specific footer ${night ? 'night' : 'day'}',
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
          final status = tester.getRect(
            find.byKey(const Key('reader-status-bar')),
          );
          expect(tester.getRect(body).top, 0);
          expect(status.height, closeTo(16, .01));
          expect(
            status.bottom,
            closeTo(844 - ReaderPlatform.fallbackBottomClearance, .01),
          );
          final fade = find.byKey(const Key('reader-bottom-fade'));
          if (mode != PageMode.scroll) {
            expect(fade, findsNothing);
            expect(find.byKey(const Key('reader-page-tail')), findsNothing);
            final paint = tester
                .widgetList<CustomPaint>(
                  find.descendant(of: body, matching: find.byType(CustomPaint)),
                )
                .singleWhere((p) => p.painter is ScreenLeafPainter);
            final painter = paint.painter! as ScreenLeafPainter;
            expect(painter.insets.top, 0);
            final textBottom =
                tester.getRect(body).bottom - painter.insets.bottom;
            expect(textBottom, closeTo(status.top - 2, .01));
            for (final slice in painter.leaf.slices) {
              expect(
                slice.y + slice.bottom - slice.top,
                lessThanOrEqualTo(textBottom + .01),
              );
            }
            await tester.tapAt(Offset(tester.getRect(body).right - 15, 350));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          } else {
            expect(
              status.top,
              greaterThan(tester.getRect(fade).top + ReaderBottomFade.extent),
            );
            expect(
              tester
                  .widget<ReaderBottomFade>(find.byType(ReaderBottomFade))
                  .background,
              prefs.background,
            );
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
    'curl follows a held corner drag and commits only after settling',
    (tester) async {
      await mountReader(
        tester,
        preferences: const ReaderPreferences(font: 'sourceHan'),
      );
      final body = find.byKey(const Key('reader-content'));
      final rect = tester.getRect(body);
      int page() {
        final label = tester
            .widgetList<Semantics>(
              find.descendant(of: body, matching: find.byType(Semantics)),
            )
            .map((widget) => widget.properties.label)
            .whereType<String>()
            .singleWhere((label) => label.endsWith(' 页'));
        return int.parse(RegExp(r'第 (\d+) 页$').firstMatch(label)!.group(1)!);
      }

      final initialPage = page();
      PaperCurlPainter? curl() => tester
          .widgetList<CustomPaint>(
            find.descendant(of: body, matching: find.byType(CustomPaint)),
          )
          .map((p) => p.painter)
          .whereType<PaperCurlPainter>()
          .firstOrNull;

      final drag = await tester.startGesture(
        rect.bottomRight - const Offset(12, 30),
      );
      await drag.moveBy(const Offset(-106, -90));
      await tester.pump();
      final first = curl()!;
      expect(first.corner, rect.bottomRight);
      expect(first.finger, rect.bottomRight - const Offset(118, 120));
      expect(page(), initialPage);
      await drag.moveBy(const Offset(-25, -60));
      await tester.pump();
      expect(curl()!.finger.dx, lessThan(first.finger.dx));
      expect(curl()!.finger.dy, lessThan(first.finger.dy));
      await capture(tester, 'curl-held-bottom-right');
      await drag.moveBy(const Offset(80, 75));
      await tester.pump();
      expect(curl()!.finger.dx, greaterThan(first.finger.dx));
      await drag.cancel();
      await tester.pumpAndSettle();
      expect(curl(), isNull);
      expect(page(), initialPage);

      final across = await tester.startGesture(
        rect.centerRight - const Offset(10, 0),
      );
      await across.moveBy(const Offset(-240, -20));
      await tester.pump();
      expect(curl()!.corner, rect.topRight);
      expect(curl()!.finger.dy, 1);
      expect(page(), initialPage);
      await across.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(page(), initialPage);
      await tester.pumpAndSettle();
      expect(curl(), isNull);
      expect(page(), initialPage + 1);

      final back = await tester.startGesture(
        rect.topLeft + const Offset(20, 80),
      );
      await back.moveBy(const Offset(240, 60));
      await tester.pump();
      expect(curl()!.corner, rect.bottomRight);
      expect(curl()!.finger, Offset(rect.left + 260, rect.bottom));
      await back.up();
      await tester.pumpAndSettle();
      expect(page(), initialPage);
    },
  );

  testWidgets(
    'curl reference matrix uses absolute touches and correct page faces',
    (tester) async {
      await mountReader(
        tester,
        preferences: const ReaderPreferences(font: 'sourceHan'),
      );
      final body = find.byKey(const Key('reader-content'));
      final rect = tester.getRect(body);
      final baseline = tester
          .widgetList<CustomPaint>(
            find.descendant(of: body, matching: find.byType(CustomPaint)),
          )
          .map((p) => p.painter)
          .whereType<ScreenLeafPainter>()
          .single;
      final current = PaperCurlPainter.record(
        baseline.leaf,
        baseline.paper,
        baseline.insets,
        rect.size,
      );
      Future<List<int>> pixels(ui.Picture picture) async =>
          (await tester.runAsync(() async {
            final image = await picture.toImage(
              rect.width.round(),
              rect.height.round(),
            );
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List().toList();
            image.dispose();
            final bodyChannels =
                rect.width.round() *
                (rect.height - baseline.insets.bottom).floor() *
                4;
            return bytes.take(bodyChannels).toList();
          }))!;
      final expectedCurrent = await pixels(current);
      current.dispose();
      final cases = [
        (
          name: 'next-top',
          down: const Offset(.82, .2),
          delta: const Offset(-.23, .1),
          forward: true,
          cornerY: 0.0,
          fingerY: .3,
        ),
        (
          name: 'next-upper-middle',
          down: const Offset(.82, .45),
          delta: const Offset(-.23, .05),
          forward: true,
          cornerY: 0.0,
          fingerY: -1.0,
        ),
        (
          name: 'next-lower-middle',
          down: const Offset(.82, .55),
          delta: const Offset(-.23, -.05),
          forward: true,
          cornerY: 1.0,
          fingerY: 1.0,
        ),
        (
          name: 'next-bottom',
          down: const Offset(.82, .85),
          delta: const Offset(-.23, -.1),
          forward: true,
          cornerY: 1.0,
          fingerY: .75,
        ),
        (
          name: 'next-left-bottom',
          down: const Offset(.42, .85),
          delta: const Offset(-.18, -.1),
          forward: true,
          cornerY: 1.0,
          fingerY: .75,
        ),
        (
          name: 'previous-top',
          down: const Offset(.12, .2),
          delta: const Offset(.23, .1),
          forward: false,
          cornerY: 1.0,
          fingerY: 1.0,
        ),
        (
          name: 'previous-bottom',
          down: const Offset(.12, .85),
          delta: const Offset(.23, -.1),
          forward: false,
          cornerY: 1.0,
          fingerY: 1.0,
        ),
      ];
      for (final scenario in cases) {
        final visible = tester
            .widgetList<CustomPaint>(
              find.descendant(of: body, matching: find.byType(CustomPaint)),
            )
            .map((p) => p.painter)
            .whereType<ScreenLeafPainter>()
            .single;
        expect(
          visible.leaf,
          same(baseline.leaf),
          reason: 'Visible page changed before ${scenario.name}',
        );
        final start = Offset(
          rect.width * scenario.down.dx,
          rect.height * scenario.down.dy,
        );
        final delta = Offset(
          rect.width * scenario.delta.dx,
          rect.height * scenario.delta.dy,
        );
        final drag = await tester.startGesture(start);
        await drag.moveBy(delta);
        await tester.pump();
        final painter = tester
            .widgetList<CustomPaint>(
              find.descendant(of: body, matching: find.byType(CustomPaint)),
            )
            .map((p) => p.painter)
            .whereType<PaperCurlPainter>()
            .single;
        expect(
          painter.corner,
          Offset(rect.width, rect.height * scenario.cornerY),
          reason: scenario.name,
        );
        expect(
          painter.finger.dx,
          closeTo((start + delta).dx, .001),
          reason: scenario.name,
        );
        final y = scenario.fingerY < 0 ? 1.0 : rect.height * scenario.fingerY;
        expect(painter.finger.dy, closeTo(y, .001), reason: scenario.name);
        await capture(
          tester,
          scenario.name,
          directory: const String.fromEnvironment(
            'READER_CURL_SCREENSHOT_DIR',
            defaultValue: '../artifacts/reader-curl-revised-20261105',
          ),
        );
        expect(
          await pixels(scenario.forward ? painter.front : painter.under!),
          orderedEquals(expectedCurrent),
          reason: scenario.name,
        );
        await drag.cancel();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('curl reveals the preloaded previous chapter before committing', (
    tester,
  ) async {
    await mountReader(tester, startChapter: 1);
    await flushReader(tester);
    final body = find.byKey(const Key('reader-content'));
    final rect = tester.getRect(body);
    final footer = find.byKey(const Key('reader-chapter-status'));
    String chapter() => tester.widget<Text>(footer).data!;
    expect(chapter(), contains('第2章'));
    final drag = await tester.startGesture(
      rect.centerLeft + const Offset(18, 0),
    );
    await drag.moveBy(Offset(rect.width * .7, 0));
    await tester.pump();
    final curl = tester
        .widgetList<CustomPaint>(
          find.descendant(of: body, matching: find.byType(CustomPaint)),
        )
        .map((paint) => paint.painter)
        .whereType<PaperCurlPainter>()
        .single;
    expect(curl.under, isNotNull);
    expect(chapter(), contains('第2章'));
    await drag.up();
    await tester.pumpAndSettle();
    await flushReader(tester);
    expect(chapter(), contains('第1章'));
  });

  testWidgets(
    'curl accepts rapid swipes during settling and cancels without an extra page',
    (tester) async {
      await mountReader(tester);
      final body = find.byKey(const Key('reader-content'));
      final rect = tester.getRect(body);
      int page() {
        final label = tester
            .widgetList<Semantics>(
              find.descendant(of: body, matching: find.byType(Semantics)),
            )
            .map((widget) => widget.properties.label)
            .whereType<String>()
            .singleWhere((label) => label.endsWith(' 页'));
        return int.parse(RegExp(r'第 (\d+) 页$').firstMatch(label)!.group(1)!);
      }

      final initial = page();
      Future<TestGesture> next() async {
        final drag = await tester.startGesture(
          Offset(rect.width * .9, rect.height * .55),
        );
        await drag.moveBy(Offset(-rect.width * .65, 0));
        await tester.pump();
        return drag;
      }

      final first = await next();
      await first.up();
      await tester.pump(const Duration(milliseconds: 50));
      final second = await next();
      await second.up();
      await tester.pumpAndSettle();
      expect(page(), initial + 2);
      final accepted = await next();
      await accepted.up();
      await tester.pumpAndSettle();
      expect(page(), initial + 3);

      final cancel = await tester.startGesture(
        Offset(rect.width * .1, rect.height * .2),
      );
      await cancel.moveBy(Offset(rect.width * .2, rect.height * .05));
      await tester.pump();
      await cancel.cancel();
      await tester.pumpAndSettle();
      expect(page(), initial + 3);
      final again = await next();
      await again.up();
      await tester.pumpAndSettle();
      expect(page(), initial + 4);
    },
  );

  testWidgets('curl accepts every rapid tap and reverses during settling', (
    tester,
  ) async {
    await mountReader(tester);
    final body = find.byKey(const Key('reader-content'));
    final rect = tester.getRect(body);
    int page() {
      final label = tester
          .widgetList<Semantics>(
            find.descendant(of: body, matching: find.byType(Semantics)),
          )
          .map((w) => w.properties.label)
          .whereType<String>()
          .singleWhere((s) => s.endsWith(' 页'));
      return int.parse(RegExp(r'第 (\d+) 页$').firstMatch(label)!.group(1)!);
    }

    final initial = page();
    for (var i = 0; i < 5; i++) {
      await tester.tapAt(Offset(rect.width * .9, rect.height * .55));
      await tester.pump(const Duration(milliseconds: 90));
      expect(page(), initial + i);
    }
    await tester.pumpAndSettle();
    expect(page(), initial + 5);
    await tester.tapAt(Offset(rect.width * .9, rect.height * .55));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(Offset(rect.width * .1, rect.height * .55));
    // This fixture reaches a chapter boundary here. Let its real repository
    // writes finish before draining animation frames in the fake test clock.
    await flushReader(tester);
    await tester.pumpAndSettle();
    expect(page(), initial + 5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('curl footer keeps the visible text and battery sizes', (
    tester,
  ) async {
    await mountReader(
      tester,
      preferences: const ReaderPreferences(font: 'sourceHan'),
      chapterName: '保持字号不变的长标题',
    );
    await flushReader(tester);
    final body = find.byKey(const Key('reader-content'));
    final rect = tester.getRect(body);
    final statusRect = tester.getRect(
      find.byKey(const Key('reader-status-bar')),
    );
    const factor = 3.0;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('reader-review')),
    );
    final idle = (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: factor);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List().toList();
      image.dispose();
      return bytes;
    }))!;
    final drag = await tester.startGesture(
      Offset(rect.width * .85, rect.height * .85),
    );
    await drag.moveBy(Offset(-rect.width * .3, -rect.height * .15));
    await tester.pump();
    final curl = tester
        .widgetList<CustomPaint>(
          find.descendant(of: body, matching: find.byType(CustomPaint)),
        )
        .map((p) => p.painter)
        .whereType<PaperCurlPainter>()
        .single;
    final snapshot = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..scale(factor)
        ..drawPicture(curl.front);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        (rect.width * factor).round(),
        (rect.height * factor).round(),
      );
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List().toList();
      image.dispose();
      picture.dispose();
      return bytes;
    }))!;
    expectFooterSizes(
      compareFooterPixels(idle, snapshot, rect.size, statusRect, factor),
    );
    await drag.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'curl accepts input while a completed turn activates the next chapter',
    (tester) async {
      await mountReader(tester, startChapter: 1);
      await flushReader(tester);
      final content = find.byKey(const Key('reader-content'));
      final size = tester.getSize(content);
      final chapter = find.byKey(const Key('reader-chapter-status'));
      await tester.tapAt(Offset(size.width * .1, size.height * .55));
      await tester.pumpAndSettle();
      await flushReader(tester);
      expect(tester.widget<Text>(chapter).data, contains('第1章'));
      await tester.tapAt(Offset(size.width * .9, size.height * .55));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tapAt(Offset(size.width * .9, size.height * .55));
      await flushReader(tester);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(chapter).data, contains('第2章'));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              (w.properties.label?.endsWith('第 2 页') ?? false),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'previous chapter waits for its front page and remains draggable after committing',
    (tester) async {
      final ready = Completer<void>();
      addTearDown(() {
        if (!ready.isCompleted) ready.complete();
      });
      await mountReader(
        tester,
        startChapter: 1,
        delayedPages: {'https://example.invalid/chapter/0': ready.future},
      );
      final body = find.byKey(const Key('reader-content'));
      final rect = tester.getRect(body);
      Finder curl() => find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is PaperCurlPainter,
      );
      Future<TestGesture> previous() async {
        final drag = await tester.startGesture(Offset(20, rect.height * .2));
        await drag.moveBy(Offset(rect.width * .7, rect.height * .1));
        await tester.pump();
        return drag;
      }

      final waiting = await previous();
      expect(curl(), findsNothing);
      await waiting.cancel();
      ready.complete();
      await flushReader(tester);
      final loaded = await previous();
      expect(curl(), findsOneWidget);
      await loaded.up();
      await tester.pumpAndSettle();
      await flushReader(tester);
      expect(curl(), findsNothing);
      final nextDrag = await previous();
      expect(curl(), findsOneWidget);
      await nextDrag.cancel();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'curl records the footer while its fixed overlay becomes transparent',
    (tester) async {
      await mountReader(
        tester,
        preferences: const ReaderPreferences(font: 'sourceHan'),
      );
      final body = find.byKey(const Key('reader-content'));
      final rect = tester.getRect(body);
      final status = find.byKey(const Key('reader-status-overlay'));
      expect(tester.widget<Opacity>(status).opacity, 1);
      final drag = await tester.startGesture(
        rect.bottomRight - const Offset(20, 45),
      );
      await drag.moveBy(const Offset(-160, -130));
      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(status).opacity, 0);
      expect(tester.widget<Opacity>(status).alwaysIncludeSemantics, isTrue);
      expect(find.byType(ReaderStatusBar), findsOneWidget);
      final curl = tester
          .widgetList<CustomPaint>(
            find.descendant(of: body, matching: find.byType(CustomPaint)),
          )
          .map((paint) => paint.painter)
          .whereType<PaperCurlPainter>()
          .single;
      final statusRect = tester.getRect(
        find.byKey(const Key('reader-status-bar')),
      );
      final hasFooter = await tester.runAsync(() async {
        final image = await curl.front.toImage(
          rect.width.round(),
          rect.height.round(),
        );
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var inkPixels = 0;
        for (
          var y = statusRect.top.ceil();
          y < statusRect.bottom.floor();
          y++
        ) {
          for (
            var x = statusRect.left.ceil();
            x < statusRect.right.floor();
            x++
          ) {
            final index = (y * rect.width.round() + x) * 4;
            if (bytes.getUint8(index) < 220 &&
                bytes.getUint8(index + 1) < 220) {
              inkPixels++;
            }
          }
        }
        image.dispose();
        return inkPixels > 30;
      });
      expect(hasFooter, isTrue);
      await drag.cancel();
      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(status).opacity, 1);
    },
  );

  testWidgets('manual brightness lasts across reader routes in one session', (
    tester,
  ) async {
    final calls = <double?>[];
    final (reader, _) = await mountReader(tester, onBrightness: calls.add);
    final body = find.byKey(const Key('reader-content'));
    final auto = find.byKey(const Key('reader-auto-brightness'));
    Slider slider() =>
        tester.widget<Slider>(find.byKey(const Key('reader-brightness')));
    Future<void> openSettings() async {
      await tester.tapAt(tester.getCenter(body));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').hitTestable());
      await tester.pumpAndSettle();
    }

    expect(calls.last, isNull);
    await openSettings();
    expect(slider().onChanged, isNull);
    await tester.tap(auto);
    await tester.pumpAndSettle();
    slider().onChanged!(.68);
    await tester.pumpAndSettle();
    expect(calls.last, .68);
    expect(reader.storage['preferences']?['brightness'], isNull);

    await tester.tap(find.byTooltip('返回书架').hitTestable());
    await flushReader(tester);
    await tester.pumpAndSettle();
    expect(calls.last, isNull);
    await tester.tap(find.text('测试书籍 0').last);
    await settleReader(tester);
    expect(calls.last, .68);
    await openSettings();
    expect(slider().value, .68);
    await tester.tap(auto);
    await tester.pumpAndSettle();
    expect(calls.last, isNull);
    expect(slider().onChanged, isNull);
  });

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
      expect(find.text('添加到收藏').hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const Key('reader-favorite')));
      await tester.tap(find.byKey(const Key('reader-favorite')));
      await flushReader(tester);
      expect((await tester.runAsync(sync.books))!.single.favorite, isTrue);
      expect(find.text('已在收藏').hitTestable(), findsOneWidget);
      await capture(tester, 'menu-in-bookshelf');
      await tester.tap(find.byKey(const Key('reader-favorite')));
      await flushReader(tester);
      expect((await tester.runAsync(sync.books))!.single.favorite, isFalse);
      expect(find.text('添加到收藏').hitTestable(), findsOneWidget);
      await capture(tester, 'menu-add-to-bookshelf');
      await tester.runAsync(() => sync.setFavorite(book, true));
      await flushReader(tester);
      expect(find.text('已在收藏').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('返回书架').hitTestable());
      await flushReader(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试书籍 0').last);
      await settleReader(tester);
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('reader-content'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('已在收藏').hitTestable(), findsOneWidget);
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
    expect(find.text('添加到收藏').hitTestable(), findsOneWidget);
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
