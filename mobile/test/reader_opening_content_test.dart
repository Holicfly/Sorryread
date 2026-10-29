import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_opening.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_layout.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_page.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_preferences.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_resume_cache.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_scroll_sliver.dart';

import 'reader_page_test.dart' show mountReader, settleReader;

void main() {
  testWidgets(
    'a pending idle font warmup never gates the first tap or opening animation',
    (tester) async {
      final preferences = Completer<void>();
      await mountReader(
        tester,
        awaitBody: false,
        delayedReads: {'preferences': preferences.future},
        fontWarmup: preferences.future,
      );
      final transition = tester.widget<BookOpeningTransition>(
        find.byType(BookOpeningTransition),
      );
      expect(transition.animation.value, lessThan(1));
      expect(find.byKey(const Key('reader-loading-paper')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(transition.animation.value, greaterThan(0));
      expect(transition.animation.value, lessThan(1));
      expect(find.byKey(const Key('reader-content')), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      expect(transition.animation.isCompleted, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在加载章节'), findsOneWidget);
      expect(find.text('加载中'), findsNothing);
      final loading = find.byKey(const Key('reader-loading-paper'));
      expect(
        tester.getCenter(
          find
              .ancestor(of: find.text('正在加载章节'), matching: find.byType(Column))
              .first,
        ),
        tester.getCenter(loading),
      );
      preferences.complete();
      await settleReader(tester);
      expect(find.byKey(const Key('reader-content')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
  testWidgets(
    'cold opening has one centered loading indicator; body appears before completion',
    (tester) async {
      final gate = Completer<void>();
      final (repository, _) = await mountReader(
        tester,
        awaitBody: false,
        delayedPages: {'https://example.invalid/book/0': gate.future},
      );
      final transition = tester.widget<BookOpeningTransition>(
        find.byType(BookOpeningTransition),
      );
      expect(transition.animation.value, lessThan(1));
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(find.byKey(const Key('reader-loading-paper')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在加载章节'), findsOneWidget);
      expect(find.text('加载中'), findsNothing);
      expect(find.byKey(const ValueKey('book-stable-paper')), findsNothing);
      await tester.pump(const Duration(milliseconds: 140));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('加载中'), findsNothing);
      final initialMetrics = MediaQuery.of(
        tester.element(find.byType(ReaderPage)),
      );
      gate.complete();
      // Run real IO without advancing the animation clock by 600ms. Each small
      // pump also allows one bounded text shaping batch to finish.
      for (
        var i = 0;
        i < 180 && find.byKey(const Key('reader-content')).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 3)),
        );
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(transition.animation.value, lessThan(1));
      expect(find.byKey(const Key('reader-content')), findsOneWidget);
      expect(find.byKey(const Key('reader-loading-paper')), findsNothing);
      final content = tester.element(find.byKey(const Key('reader-content')));
      final requests = repository.catalogRequests;
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester.element(find.byKey(const Key('reader-content'))),
        same(content),
      );
      expect(
        repository.catalogRequests,
        requests,
        reason: 'Completion does not reload the reader',
      );
      expect(
        MediaQuery.of(tester.element(find.byType(ReaderPage))),
        initialMetrics,
      );
      await settleReader(tester);
    },
  );

  testWidgets(
    'warm reopening transfers actual layout and precise scroll position without a loading flash',
    (tester) async {
      final (repository, _) = await mountReader(
        tester,
        preferences: const ReaderPreferences(mode: PageMode.scroll),
      );
      final context = tester.element(find.byType(ReaderPage));
      final container = ProviderScope.containerOf(context);
      final router = container.read(appRouterProvider);
      final scroll = find.descendant(
        skipOffstage: false,
        of: find.byKey(const Key('reader-content'), skipOffstage: false),
        matching: find.byType(CustomScrollView, skipOffstage: false),
      );
      await tester.drag(scroll, const Offset(0, -543));
      await tester.pumpAndSettle();
      final beforeOffset = tester
          .widget<CustomScrollView>(scroll)
          .controller!
          .offset;
      final beforePainter =
          tester
                  .widget<CustomPaint>(
                    find
                        .descendant(
                          of: find
                              .byType(ReaderScrollSliver, skipOffstage: false)
                              .last,
                          matching: find.byType(
                            CustomPaint,
                            skipOffstage: false,
                          ),
                        )
                        .first,
                  )
                  .painter
              as BlockPainter;
      final beforeBlock = beforePainter.block;
      final catalogs = repository.catalogRequests;
      final chapters =
          repository.chapterRequests['https://example.invalid/chapter/0'];
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsNothing);
      await tester.tap(find.text('测试书籍 0').last);
      for (
        var i = 0;
        i < 20 && find.byType(ReaderPage).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump();
      }
      final transition = tester.widget<BookOpeningTransition>(
        find.byType(BookOpeningTransition),
      );
      expect(transition.animation.value, lessThan(1));
      expect(find.byKey(const Key('reader-loading-paper')), findsNothing);
      expect(find.byKey(const Key('reader-prepared-paper')), findsOneWidget);
      expect(
        find.byKey(const Key('reader-content'), skipOffstage: false),
        findsOneWidget,
      );
      final restoredElement = tester.element(
        find.byKey(const Key('reader-content'), skipOffstage: false),
      );
      final restoredScroll = tester.widget<CustomScrollView>(
        find.descendant(
          skipOffstage: false,
          of: find.byKey(const Key('reader-content'), skipOffstage: false),
          matching: find.byType(CustomScrollView, skipOffstage: false),
        ),
      );
      expect(restoredScroll.controller!.offset, closeTo(beforeOffset, .001));
      final restoredPainter =
          tester
                  .widget<CustomPaint>(
                    find
                        .descendant(
                          of: find
                              .byType(ReaderScrollSliver, skipOffstage: false)
                              .last,
                          matching: find.byType(
                            CustomPaint,
                            skipOffstage: false,
                          ),
                        )
                        .first,
                  )
                  .painter
              as BlockPainter;
      expect(
        restoredPainter.block,
        same(beforeBlock),
        reason: 'Warm route reuses the same already-shaped text, not an imitation screenshot',
      );
      await tester.pump(const Duration(milliseconds: 610));
      expect(find.byKey(const Key('reader-prepared-paper')), findsNothing);
      expect(
        tester.element(find.byKey(const Key('reader-content'))),
        same(restoredElement),
      );
      expect(repository.catalogRequests, catalogs);
      expect(
        repository.chapterRequests['https://example.invalid/chapter/0'],
        chapters,
      );
      expect(restoredScroll.controller!.offset, closeTo(beforeOffset, .001));
      expect(tester.takeException(), isNull);
      // The cache provider is scoped to the application, never static/global.
      expect(
        container.read(readerResumeCacheProvider),
        isA<ReaderResumeCache>(),
      );
    },
  );
}
