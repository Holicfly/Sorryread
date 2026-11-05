import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/app/shell.dart';
import 'package:sorryread_mobile/design_system/components.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_cover.dart';
import 'package:sorryread_mobile/features/profile/presentation/profile_page.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import 'app_shell_test.dart' show launch, navigationLabel;

Future<void> captureHeader(WidgetTester tester, String name) async {
  final imageContext = tester.element(find.byType(AppShell));
  final images = tester
      .widgetList<Image>(find.byType(Image))
      .map((image) => image.image)
      .toSet();
  await tester.runAsync(
    () => Future.wait([
      for (final provider in images) precacheImage(provider, imageContext),
    ]),
  );
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find
        .ancestor(
          of: find.byType(AppShell),
          matching: find.byType(RepaintBoundary),
        )
        .first,
  );
  await tester.runAsync(() async {
    final frame = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../artifacts/top-headers-v0212-review/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    frame.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/wenkai.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final scenario in [
    (
      name: 'normal',
      size: const Size(390, 844),
      scale: 1.0,
      padding: const FakeViewPadding(top: 24, bottom: 24),
    ),
    (
      name: 'camera',
      size: const Size(393, 852),
      scale: 1.0,
      padding: const FakeViewPadding(top: 64, bottom: 34),
    ),
    (
      name: 'large-text',
      size: const Size(320, 640),
      scale: 2.0,
      padding: const FakeViewPadding(top: 64, bottom: 24),
    ),
    (
      name: 'landscape',
      size: const Size(844, 390),
      scale: 1.0,
      padding: const FakeViewPadding(left: 48, right: 24, bottom: 16),
    ),
  ]) {
    testWidgets('home headers align below the safe area: ${scenario.name}', (
      tester,
    ) async {
      await launch(
        tester,
        size: scenario.size,
        scale: scenario.scale,
        safePadding: scenario.padding,
        bookCount: 3,
        syncState: const SyncViewState(),
      );
      final positions = <String, Map<String, double>>{};
      for (final page in ['bookshelf', 'discover', 'profile']) {
        late Finder title;
        late Finder content;
        if (page == 'bookshelf') {
          title = find.descendant(
            of: find.byKey(const Key('shelf-tab-favorites')),
            matching: find.byType(Text),
          );
          content = find.byType(BookCover).first;
        } else if (page == 'discover') {
          await tester.tap(navigationLabel('发现'));
          await tester.pumpAndSettle();
          title = find.descendant(
            of: find.byKey(const Key('discover-heading')),
            matching: find.byType(Text),
          );
          content = find.byKey(const Key('discover-search-input'));
        } else {
          await tester.tap(navigationLabel('我的'));
          await tester.pumpAndSettle();
          title = find.descendant(
            of: find.byType(ProfilePage),
            matching: find.text('我的'),
          );
          content = find.text('本地读者');
        }
        expect(title, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(title);
        final rect = tester.getRect(title);
        final baseline = paragraph.getDryBaseline(
          paragraph.constraints,
          TextBaseline.alphabetic,
        )!;
        positions[page] = {
          'top': rect.top,
          'baseline': paragraph.localToGlobal(Offset(0, baseline)).dy,
          'left': rect.left,
        };
        expect(
          rect.top,
          closeTo(scenario.padding.top + PageHeader.textPadding, .5),
        );
        expect(rect.left, greaterThanOrEqualTo(scenario.padding.left));
        expect(
          rect.right,
          lessThanOrEqualTo(scenario.size.width - scenario.padding.right),
        );
        expect(tester.getRect(content).top, greaterThanOrEqualTo(rect.bottom));
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('HEADER_SCREENSHOTS') &&
            scenario.name == 'camera') {
          await captureHeader(tester, page);
        }
      }
      for (final position in positions.values.skip(1)) {
        for (final metric in ['top', 'baseline', 'left']) {
          expect(
            position[metric],
            closeTo(positions['bookshelf']![metric]!, .5),
          );
        }
      }
      if (const bool.fromEnvironment('HEADER_SCREENSHOTS') &&
          scenario.name == 'camera') {
        await tester.runAsync(
          () => File('../artifacts/top-headers-v0212-review/positions.json')
              .writeAsString(
                const JsonEncoder.withIndent('  ').convert(positions),
              ),
        );
      }
    });
  }
}
