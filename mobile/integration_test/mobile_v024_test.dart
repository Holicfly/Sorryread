import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/discover/presentation/normal_search_page.dart';
import 'package:sorryread_mobile/features/discover/data/normal_search.dart';
import 'package:sorryread_mobile/features/profile/data/daily_saying.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import '../test/support/test_runtime.dart' show MemoryPeerStorage;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('v024 isolated phone review', (tester) async {
    final root = await getApplicationSupportDirectory();
    final suffix = DateTime.now().millisecondsSinceEpoch;
    final sync = SyncRepository(
      SyncDatabase(
        NativeDatabase.createInBackground(File('${root.path}/v024-$suffix.db')),
      ),
    );
    await sync.initialize();
    final rules =
        (jsonDecode(await rootBundle.loadString('assets/reader_sources.json'))
                as List)
            .map((e) => SourceRule(Map<String, dynamic>.from(e as Map)))
            .toList();
    final reader = ReaderRepository(
      Directory('${root.path}/v024-reading-$suffix'),
      rules,
    );
    final result = <String, dynamic>{'passed': false};
    Future<void> progress(String phase) async {
      result['phase'] = phase;
      await File('${root.path}/v024-result.json')
          .writeAsString(jsonEncode(result), flush: true);
    }

    addTearDown(() async {
      result['failures'] = binding.failureMethodsDetails
          .map((e) => e.details)
          .toList();
      await progress(result['phase'] as String? ?? 'startup');
    });
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('phone-review')),
      );
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${root.path}/v024-$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    Future<void> until(
      bool Function() ready,
      String message, {
      int seconds = 90,
    }) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 150));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: message);
    }

    Future<void> taps(Finder heading) async {
      for (var i = 0; i < 5; i++) {
        await tester.tap(heading);
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpAndSettle();
    }

    Future<void> submit(String text) async {
      final input = find.byType(TextField).hitTestable();
      await tester.enterText(input, text);
      tester.widget<TextField>(input).onSubmitted!(text);
      await tester.pumpAndSettle();
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
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderApp)),
    );
    final router = container.read(appRouterProvider);

    router.go('/discover');
    await progress('18mh-search');
    await tester.pumpAndSettle();
    await taps(find.byKey(const Key('discover-heading')));
    await submit('魅魔的丝袜');
    final specialBook = find.widgetWithText(ListTile, '魅魔的丝袜');
    await until(
      () => specialBook.evaluate().isNotEmpty,
      '18mh search returned no matching book',
    );
    await tester.ensureVisible(specialBook);
    await tester.pumpAndSettle();
    await tester.tap(specialBook);
    await until(
      () => find.byKey(const Key('reader-content')).evaluate().isNotEmpty,
      '18mh reader did not load',
    );
    await tester.pumpAndSettle();
    result['18mhReaderLoaded'] = true;
    await progress('18mh-reading');
    result['bottomClearance'] = await reader.platform.bottomClearance();
    final status = tester.getRect(find.byKey(const Key('reader-status-bar')));
    result['statusBottomDistance'] =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        status.bottom;
    expect(result['statusBottomDistance'] as double, greaterThanOrEqualTo(12));
    await capture('special-reader-footer');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reader-content'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reader-favorite')));
    await until(
      () => find.text('已在书架').hitTestable().evaluate().isNotEmpty,
      'Favorite state not updated',
    );
    await tester.tap(find.byTooltip('返回书架').hitTestable());
    await tester.pumpAndSettle();
    router.go('/bookshelf');
    await tester.pumpAndSettle();
    await taps(find.text('我的书架'));
    await until(
      () => find.text('魅魔的丝袜').evaluate().isNotEmpty,
      'Special favorite missing',
    );
    await tester.longPress(find.text('魅魔的丝袜').last);
    await progress('pin-menu');
    await tester.pumpAndSettle();
    expect(find.text('置顶').hitTestable(), findsOneWidget);
    await tester.tap(find.text('置顶').hitTestable());
    await until(
      () => find.byType(BottomSheet).evaluate().isEmpty,
      'Pin action did not finish',
    );
    await until(
      () => find
          .byIcon(Icons.push_pin_rounded)
          .hitTestable()
          .evaluate()
          .isNotEmpty,
      'Pinned badge missing',
    );
    result['pinBadgeVisible'] = true;
    final library = await container.read(localLibraryProvider.future);
    expect(library.pins, isNotEmpty);
    expect(library.stats.milliseconds, greaterThan(0));
    result['specialReadingMs'] = library.stats.milliseconds;
    await capture('pinned-bookshelf');

    router.go('/discover');
    await tester.pumpAndSettle();
    await taps(find.byKey(const Key('discover-heading')));
    await submit('斗破苍穹');
    await progress('normal-search');
    await until(
      () => find.byType(NormalSearchPage).evaluate().isNotEmpty,
      'Normal search page missing',
    );
    final source = find.byKey(const ValueKey('normal-source-shuhaige'));
    await until(() => source.evaluate().isNotEmpty, 'Source tabs missing');
    await tester.ensureVisible(source);
    await tester.pumpAndSettle();
    await tester.tap(source);
    final rows = find.descendant(
      of: find.byType(NormalSearchPage),
      matching: find.byType(ListTile),
    );
    await until(
      () =>
          find
              .byKey(const ValueKey('normal-source-shuhaige'))
              .evaluate()
              .isNotEmpty &&
          tester
              .widget<ChoiceChip>(
                find.byKey(const ValueKey('normal-source-shuhaige')),
              )
              .selected &&
          find.textContaining('书海阁小说网 …').evaluate().isEmpty &&
          rows.evaluate().isNotEmpty,
      'Shuhaige returned no normal search results',
    );
    expect(find.text('全部'), findsNothing);
    expect(find.text('综合排序'), findsNothing);
    expect(find.textContaining('我的书城网'), findsNothing);
    result['normalSourceTabCount'] = rules.where(normalSource).length;
    expect(result['normalSourceTabCount'], 12);
    final row = tester.widget<ListTile>(rows.first);
    result['normalAuthorPresent'] = row.subtitle != null;
    await capture('normal-source-results');
    await tester.tap(rows.first);
    await progress('normal-reading');
    await until(
      () => find.byKey(const Key('reader-content')).evaluate().isNotEmpty,
      'Normal-source book did not open',
    );
    result['normalReaderLoaded'] = true;
    await capture('normal-reader-footer');
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('reader-content'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回书架').hitTestable());
    await tester.pumpAndSettle();
    router.go('/profile');
    await progress('profile');
    await tester.pumpAndSettle();
    await until(
      () => find.text('每日一句').evaluate().isNotEmpty,
      'Daily quote section missing',
    );
    expect(find.text('资料占位'), findsNothing);
    expect(find.text('专注阅读与同步'), findsNothing);
    expect(find.text('笔记'), findsNothing);
    try {
      final quote = await container.read(dailySayingProvider.future);
      result['dailyQuoteLoaded'] = quote.text.isNotEmpty;
    } catch (_) {
      result['dailyQuoteLoaded'] = false;
    }
    expect(library.stats.bookCount, greaterThanOrEqualTo(2));
    result['readBookCount'] = library.stats.bookCount;
    result['totalReadingMs'] = library.stats.milliseconds;
    await capture('profile-statistics');

    // Reopen the actual isolated phone database to verify durable pins/stats.
    final expectedPins = Map<String, int>.of(library.pins);
    final reopened = LocalLibrary(sync);
    await reopened.initialize();
    expect(reopened.pins, expectedPins);
    expect(reopened.stats.milliseconds, library.stats.milliseconds);
    await reopened.close();
    result['persistedLocalData'] = true;
    result['passed'] = true;
    await progress('complete');
    binding.reportData = result;
    // ignore: avoid_print
    print('MOBILE_V024_RESULT ${jsonEncode(result)}');
    await tester.pumpWidget(const SizedBox.shrink());
    await Future<void>.delayed(const Duration(milliseconds: 400));
    reader.dispose();
    await sync.close();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
