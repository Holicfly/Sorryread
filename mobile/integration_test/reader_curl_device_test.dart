// Focused curl follow-up: isolated offline data in the .dev application.
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
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_curl.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import '../test/app_shell_test.dart' show StaticSyncController;
import '../test/support/reader_footer_pixels.dart';
import '../test/support/test_runtime.dart';

class _OfflineReader extends ReaderRepository {
  _OfflineReader(super.directory, super.rules);
  @override
  Future<String> fetch(SourceRule source, String url) async =>
      url.contains('/chapter/')
      ? '<h1>第一章 山间来信</h1><div id="content">${List.generate(100, (i) => '<p>山间有风，书中有远方。阳光穿过枝叶，在书页上留下细碎的光影。我们沿着溪流慢慢走，听水声从石缝间穿过。</p>').join()}</div>'
      : '<div id="chapters">${List.generate(10, (i) => '<a href="/chapter/$i">第${i + 1}章 山间来信</a>').join()}</div>';
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('curl faces footer and rapid input on connected Android', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/reader-curl-review');
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
      'mode': 'curl',
      'palette': 1,
    });
    final sync = await testRepository();
    final book = const DiscoverBook(
      '卷页定向验收',
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
          key: Key('curl-device-capture'),
          child: ReaderApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderApp)),
    );
    container.read(appRouterProvider).push('/reader', extra: book);
    for (
      var i = 0;
      i < 100 && find.byKey(const Key('reader-content')).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    final content = find.byKey(const Key('reader-content'));
    final rect = tester.getRect(content);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('curl-device-capture')),
    );
    Future<void> capture(String name) async {
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('${root.path}/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    }

    int page() {
      final label = tester
          .widgetList<Semantics>(
            find.descendant(of: content, matching: find.byType(Semantics)),
          )
          .map((w) => w.properties.label)
          .whereType<String>()
          .singleWhere((s) => s.endsWith(' 页'));
      return int.parse(RegExp(r'第 (\d+) 页$').firstMatch(label)!.group(1)!);
    }

    PaperCurlPainter curl() => tester
        .widgetList<CustomPaint>(
          find.descendant(of: content, matching: find.byType(CustomPaint)),
        )
        .map((p) => p.painter)
        .whereType<PaperCurlPainter>()
        .single;
    final status = tester.getRect(find.byKey(const Key('reader-status-bar')));
    final idleImage = await boundary.toImage(pixelRatio: 3);
    final idle = (await idleImage.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List().toList();
    idleImage.dispose();
    await capture('idle');
    List<Map<String, dynamic>> footerMetrics = [];
    for (final top in [false, true]) {
      final drag = await tester.startGesture(
        Offset(rect.width * .9, rect.height * (top ? .2 : .9)),
      );
      await drag.moveBy(
        Offset(-rect.width * .3, rect.height * (top ? .12 : -.18)),
      );
      await tester.pump();
      await capture(top ? 'top' : 'bottom');
      if (!top) {
        final (snapshot, image) = await footerPicturePixels(
          curl().front,
          rect.size,
          3,
        );
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${root.path}/front-footer.png')
            .writeAsBytes(png.buffer.asUint8List());
        image.dispose();
        footerMetrics = compareFooterPixels(
          idle,
          snapshot,
          rect.size,
          status,
          3,
        );
        await File('${root.path}/footer-metrics.json')
            .writeAsString(jsonEncode(footerMetrics));
        expectFooterSizes(footerMetrics);
      }
      await drag.cancel();
      await tester.pumpAndSettle();
    }
    final initial = page();
    for (var i = 0; i < 8; i++) {
      await tester.tapAt(Offset(rect.width * .9, rect.height * .55));
      await tester.pump(const Duration(milliseconds: 90));
    }
    await tester.pumpAndSettle();
    expect(page(), initial + 8);
    final afterTaps = page();
    for (var i = 0; i < 3; i++) {
      final drag = await tester.startGesture(
        Offset(rect.width * .9, rect.height * .55),
      );
      await drag.moveBy(Offset(-rect.width * .7, 0));
      await tester.pump();
      await drag.up();
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
    expect(page(), initial + 11);
    final afterSwipes = page();
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(Offset(rect.width * .1, rect.height * .55));
      await tester.pump(const Duration(milliseconds: 90));
    }
    await tester.pumpAndSettle();
    expect(page(), initial + 8);
    final cancelled = await tester.startGesture(
      Offset(rect.width * .9, rect.height * .85),
    );
    await cancelled.moveBy(Offset(-rect.width * .12, -rect.height * .1));
    await tester.pump();
    await cancelled.cancel();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(Offset(rect.width * .9, rect.height * .55));
    await tester.pumpAndSettle();
    expect(page(), initial + 9);
    await capture('after-rapid');
    await File('${root.path}/result.json').writeAsString(
      jsonEncode({
        'passed': true,
        'initialPage': initial,
        'afterEightTaps': afterTaps,
        'afterThreeSwipes': afterSwipes,
        'afterReverseAndCancel': page(),
        'footerMetrics': footerMetrics,
      }),
    );
  });
}
