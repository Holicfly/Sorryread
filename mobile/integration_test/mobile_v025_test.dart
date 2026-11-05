import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/features/discover/data/yeshe_index.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_opening.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import '../test/support/test_runtime.dart' show MemoryPeerStorage;

class _ReviewReader extends ReaderRepository {
  _ReviewReader(super.directory, super.rules);
  @override
  Future<String> fetch(SourceRule source, String url) async {
    if (source.id != 'fixture') return super.fetch(source, url);
    if (url.contains('/chapter/')) {
      return '<h1>第一章 山间来信</h1><div id="content">${List.generate(50, (i) => '<p>第$i 段：用于观察封面打开和合上的合成正文，山间有风，书中有远方。</p>').join()}</div>';
    }
    return '<div id="chapters"><a href="/chapter/1">第一章 山间来信</a></div>';
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('v025 isolated book animation and native background index', (
    tester,
  ) async {
    final root = await getApplicationSupportDirectory();
    final reportFile = File('${root.path}/v025-result.json');
    await reportFile.writeAsString('{"passed":false,"phase":"startup"}');
    addTearDown(() async {
      final report =
          jsonDecode(await reportFile.readAsString()) as Map<String, dynamic>;
      report['failures'] = binding.failureMethodsDetails
          .map((e) => e.details)
          .toList();
      await reportFile.writeAsString(jsonEncode(report), flush: true);
    });
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final sync = SyncRepository(
      SyncDatabase(
        NativeDatabase.createInBackground(File('${root.path}/v025-$stamp.db')),
      ),
    );
    await sync.initialize();
    final book = ShelfBook(
      'book:fixture|https://fixture.invalid/book/1',
      {
        'kind': 'book',
        'title': '开合动画验收',
        'sourceId': 'fixture',
        'sourceName': '测试书源',
        'detailUrl': 'https://fixture.invalid/book/1',
        'chapterUrl': '',
        'chapterTitle': '',
        'progress': 0,
        'active': true,
      },
      true,
      true,
      null,
    );
    await sync.setFavorite(book, true);
    await sync.localChange(book.id, 'recent', book.metadata);
    final rules =
        (jsonDecode(await rootBundle.loadString('assets/reader_sources.json'))
                as List)
            .map((e) => SourceRule(Map<String, dynamic>.from(e as Map)))
            .toList();
    rules.add(
      SourceRule({
        'id': 'fixture',
        'baseUrl': 'https://fixture.invalid',
        'dynamic': false,
        'detail': <String, dynamic>{},
        'catalog': {'itemSelector': '#chapters a'},
        'chapter': {'titleSelector': 'h1', 'contentSelector': '#content'},
      }),
    );
    final reader = _ReviewReader(Directory('${root.path}/v025-reader'), rules);
    final repository = YesheIndexRepository();
    final result = <String, dynamic>{'passed': false};
    Future<void> progress(String phase) async {
      result['phase'] = phase;
      await File('${root.path}/v025-result.json')
          .writeAsString(jsonEncode(result), flush: true);
    }

    addTearDown(() async {
      result['failures'] = binding.failureMethodsDetails
          .map((e) => e.details)
          .toList();
      await progress(result['phase'] as String? ?? 'startup');
      await repository.pause();
    });
    Future<void> until(
      Future<bool> Function() ready,
      String reason, {
      int seconds = 60,
    }) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(end)) {
        if (await ready()) return;
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail(reason);
    }

    Future<void> capture(String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('phone-review')),
      );
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${root.path}/v025-$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

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
        ],
        child: const RepaintBoundary(
          key: Key('phone-review'),
          child: ReaderApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await until(
      () async => find.text(book.title).evaluate().isNotEmpty,
      'Shelf seed missing',
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderApp)),
    );
    final router = container.read(appRouterProvider);
    await progress('opening');
    await tester.tap(find.text(book.title).last);
    await tester.pump(const Duration(milliseconds: 460));
    await capture('cover-opening');
    await tester.pumpAndSettle();
    await until(
      () async => find.byKey(const Key('reader-content')).evaluate().isNotEmpty,
      'Fixture reader failed',
    );
    result['shelfReaderLoaded'] = true;
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reader-content'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回书架').hitTestable());
    await until(() async {
      final transitions = find.byType(BookOpeningTransition).evaluate();
      return transitions.isNotEmpty &&
          tester
                  .widget<BookOpeningTransition>(
                    find.byType(BookOpeningTransition),
                  )
                  .animation
                  .status ==
              AnimationStatus.reverse;
    }, 'Closing animation did not start');
    await tester.pump(const Duration(milliseconds: 300));
    result['closingAnimationValue'] = tester
        .widget<BookOpeningTransition>(find.byType(BookOpeningTransition))
        .animation
        .value;
    await capture('cover-closing');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bookshelf-tabs')), findsOneWidget);
    result['closedToShelf'] = true;
    router.go('/discover/results?mode=yeshe');
    await tester.pumpAndSettle();
    await until(
      () async =>
          find.byKey(const Key('yeshe-index-action')).evaluate().isNotEmpty,
      'Cache controls missing',
    );
    await tester.tap(find.byKey(const Key('yeshe-index-help')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('yeshe-index-help-overlay')), findsOneWidget);
    await tester.tap(find.byKey(const Key('yeshe-index-help')));
    await tester.pumpAndSettle();
    await progress('cache-start');
    final initial = await repository.status();
    await tester.tap(find.byKey(const Key('yeshe-index-action')));
    await until(
      () async => (await repository.status()).pages >= initial.pages + 3,
      'First catalog pages failed',
      seconds: 90,
    );
    final before = await repository.status();
    result['beforeBackground'] = before.data;
    await progress('background');
    // The host sends this isolated activity Home, waits, then foregrounds it and
    // touches a gate file. No dependency on the device's Flutter log channel.
    final gate = File('${root.path}/v025-continue-$stamp');
    result['gate'] = gate.path.split('/').last;
    await progress('background');
    final end = DateTime.now().add(const Duration(minutes: 2));
    while (!await gate.exists() && DateTime.now().isBefore(end)) {
      result['backgroundSample'] = (await repository.status()).data;
      await progress('background');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(
      await gate.exists(),
      isTrue,
      reason: 'Host did not complete background check',
    );
    final after = await repository.status();
    result['afterBackground'] = after.data;
    expect(after.pages, greaterThan(before.pages + 1));
    await repository.pause();
    await until(
      () async => !(await repository.status()).running,
      'Pause failed',
    );
    final paused = await repository.status();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect((await repository.status()).pages, paused.pages);
    await repository.start();
    await until(
      () async => (await repository.status()).pages >= paused.pages + 2,
      'Resume did not advance',
    );
    await repository.pause();
    await until(
      () async => !(await repository.status()).running,
      'Final pause failed',
    );
    final snapshot = await repository.status();
    result['pausedSnapshot'] = snapshot.data;
    final (books, count) = await repository.search('', 0);
    expect(count, greaterThanOrEqualTo(150));
    expect(books, isNotEmpty);
    final query = books.first.title;
    await tester.enterText(find.byType(TextField).hitTestable(), query);
    tester.widget<TextField>(find.byType(TextField).hitTestable()).onSubmitted!(
      query,
    );
    await tester.pumpAndSettle();
    await until(
      () async => find.widgetWithText(ListTile, query).evaluate().isNotEmpty,
      'Local title search failed',
    );
    result['localSearchTitle'] = query;
    result['localSearchCount'] = (await repository.search(query, 0)).$2;
    await capture('local-title-search');
    result['passed'] = true;
    await progress('complete');
    await tester.pumpWidget(const SizedBox.shrink());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    reader.dispose();
    await sync.close();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
