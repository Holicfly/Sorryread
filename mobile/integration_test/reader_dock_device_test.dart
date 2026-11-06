// Synthetic offline reading fixture in the separate .dev application.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/features/discover/data/discover_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_platform.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_curl.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_settings_sheet.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import '../test/app_shell_test.dart' show StaticSyncController;
import '../test/support/test_runtime.dart';

class _OfflineReader extends ReaderRepository {
  _OfflineReader(super.directory, super.rules);
  @override
  Future<String> fetch(SourceRule source, String url) async =>
      url.contains('/chapter/')
      ? '<h1>第一章 山间来信</h1><div id="content">${List.generate(40, (i) => '<p>山间有风，书中有远方。阳光穿过枝叶，在书页上留下细碎的光影。我们沿着溪流慢慢走，听水声从石缝间穿过。</p>').join()}</div>'
      : '<div id="chapters">${List.generate(30, (i) => '<a href="/chapter/$i">第${i + 1}章 山间来信</a>').join()}</div>';
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('reader dock and held curl on connected Android', (tester) async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/reader-dock-review');
    await root.create(recursive: true);
    final source = SourceRule({
      'id': 'review',
      'baseUrl': 'https://example.invalid',
      'dynamic': false,
      'detail': <String, dynamic>{},
      'catalog': {'itemSelector': '#chapters a'},
      'chapter': {'contentSelector': '#content', 'titleSelector': 'h1'},
    });
    final reader = _OfflineReader(Directory('${root.path}/reader'), [source]);
    await reader.write('preferences', {
      'font': 'sourceHan',
      'fontSize': 22,
      'mode': 'scroll',
      'palette': 1,
    });
    final sync = await testRepository();
    final book = const DiscoverBook(
      '山间来信 · 阅读布局验收',
      'https://example.invalid/book/1',
      DiscoverMode.normal,
      sourceId: 'review',
      sourceName: '本地验收',
    ).toShelfBook();
    await sync.setFavorite(book, true);
    addTearDown(() async {
      await File('${root.path}/failures.json').writeAsString(
        jsonEncode(
          binding.failureMethodsDetails.map((e) => e.details).toList(),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      reader.dispose();
      await sync.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncRepositoryProvider.overrideWith((ref) async => sync),
          readerRepositoryProvider.overrideWith((ref) async {
            ref.keepAlive();
            return reader;
          }),
          peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
          backgroundSyncEnabledProvider.overrideWithValue(false),
          syncControllerProvider.overrideWith(
            () => StaticSyncController(const SyncViewState()),
          ),
        ],
        child: const RepaintBoundary(
          key: Key('dock-device-capture'),
          child: ReaderApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderApp)),
    );
    final router = container.read(appRouterProvider);
    final shelfRect = tester.getRect(find.byKey(const Key('floating-dock')));
    router.push('/reader', extra: book);
    for (
      var i = 0;
      i < 100 && find.byKey(const Key('reader-content')).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('dock-device-capture')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${root.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    await capture('reading');
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reader-content'))),
    );
    await tester.pumpAndSettle();
    final dock = find.byKey(const Key('reader-floating-dock'));
    final base = tester.getRect(dock);
    expect(base.bottom, closeTo(shelfRect.bottom, 1));
    final status = tester.getRect(find.byKey(const Key('reader-status-bar')));
    expect(status.top, greaterThan(base.bottom));
    await capture('dock');
    await tester.tap(find.text('设置').hitTestable());
    await tester.pumpAndSettle();
    expect(tester.getRect(dock).bottom, closeTo(base.bottom, .1));
    expect(find.byType(ModalBarrier).hitTestable(), findsNothing);
    await capture('settings');
    await tester.tap(find.byKey(const Key('reader-eye-care')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ReaderSettingsSheet>(find.byType(ReaderSettingsSheet))
          .preferences
          .value
          .eyeCare,
      isTrue,
    );
    await capture('eye-care');
    await tester.tap(find.text('目录').hitTestable());
    await tester.pumpAndSettle();
    expect(tester.getRect(dock).bottom, closeTo(base.bottom, .1));
    await capture('catalog');
    await tester.tapAt(const Offset(200, 160));
    await tester.pumpAndSettle();
    expect(find.text('目录').hitTestable(), findsNothing);
    final content = find.byKey(const Key('reader-content'));
    await tester.tapAt(tester.getCenter(content));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').hitTestable());
    await tester.pumpAndSettle();
    final brightness = find.byKey(const Key('reader-brightness'));
    final automatic = find.byKey(const Key('reader-auto-brightness'));
    expect(tester.widget<Slider>(brightness).onChanged, isNull);
    await tester.tap(automatic);
    await tester.pumpAndSettle();
    tester.widget<Slider>(brightness).onChanged!(.55);
    await tester.pumpAndSettle();
    await tester.tap(automatic);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(brightness).onChanged, isNull);
    final simulation = find.text('仿真');
    await tester.ensureVisible(simulation);
    await tester.tap(simulation);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader-bottom-fade')), findsNothing);

    final rect = tester.getRect(content);
    final samples = <Map<String, dynamic>>[];
    final cases = [
      (
        name: 'next-top',
        down: const Offset(.82, .2),
        delta: const Offset(-.23, .1),
        cornerY: 0.0,
        fingerY: .3,
      ),
      (
        name: 'next-upper-middle',
        down: const Offset(.82, .45),
        delta: const Offset(-.23, .05),
        cornerY: 0.0,
        fingerY: -1.0,
      ),
      (
        name: 'next-lower-middle',
        down: const Offset(.82, .55),
        delta: const Offset(-.23, -.05),
        cornerY: 1.0,
        fingerY: 1.0,
      ),
      (
        name: 'next-bottom',
        down: const Offset(.82, .85),
        delta: const Offset(-.23, -.1),
        cornerY: 1.0,
        fingerY: .75,
      ),
      (
        name: 'next-left-bottom',
        down: const Offset(.42, .85),
        delta: const Offset(-.18, -.1),
        cornerY: 1.0,
        fingerY: .75,
      ),
    ];
    for (final scenario in cases) {
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
      await tester.pumpAndSettle();
      final curl = tester
          .widgetList<CustomPaint>(
            find.descendant(of: content, matching: find.byType(CustomPaint)),
          )
          .map((paint) => paint.painter)
          .whereType<PaperCurlPainter>()
          .single;
      expect(curl.corner, Offset(rect.width, rect.height * scenario.cornerY));
      expect(curl.finger.dx, closeTo((start + delta).dx, .01));
      expect(
        curl.finger.dy,
        closeTo(scenario.fingerY < 0 ? 1 : rect.height * scenario.fingerY, .01),
      );
      samples.add({
        'name': scenario.name,
        'x': curl.finger.dx,
        'y': curl.finger.dy,
      });
      expect(
        tester
            .widget<Opacity>(find.byKey(const Key('reader-status-overlay')))
            .opacity,
        0,
      );
      await capture(scenario.name);
      await drag.cancel();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Opacity>(find.byKey(const Key('reader-status-overlay')))
            .opacity,
        1,
      );
    }

    await tester.tapAt(Offset(rect.width * .9, rect.height * .55));
    await tester.pumpAndSettle();
    for (final y in [.2, .85]) {
      final start = Offset(rect.width * .12, rect.height * y);
      final drag = await tester.startGesture(start);
      await drag.moveBy(
        Offset(rect.width * .23, rect.height * (y < .5 ? .1 : -.1)),
      );
      await tester.pumpAndSettle();
      final curl = tester
          .widgetList<CustomPaint>(
            find.descendant(of: content, matching: find.byType(CustomPaint)),
          )
          .map((paint) => paint.painter)
          .whereType<PaperCurlPainter>()
          .single;
      expect(curl.corner, rect.size.bottomRight(Offset.zero));
      expect(curl.finger.dy, rect.height);
      final name = y < .5 ? 'previous-top' : 'previous-bottom';
      expect(
        tester
            .widget<Opacity>(find.byKey(const Key('reader-status-overlay')))
            .opacity,
        0,
      );
      await capture(name);
      samples.add({'name': name, 'x': curl.finger.dx, 'y': curl.finger.dy});
      await drag.cancel();
      await tester.pumpAndSettle();
    }
    final insets = await ReaderPlatform().windowInsets();
    await File('${root.path}/result.json').writeAsString(
      jsonEncode({
        'passed': true,
        'curlSamples': samples,
        'footerRecordedInPaper': true,
        'shelfDockBottom': shelfRect.bottom,
        'readerDockBottom': base.bottom,
        'footerTop': status.top,
        'footerBottom': status.bottom,
        'navigationBottom': insets.navigation,
        'cornerRadius': insets.radius,
      }),
    );
  });
}
