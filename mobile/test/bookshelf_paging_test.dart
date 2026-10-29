import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_page.dart';

import 'app_shell_test.dart' show launch;

const _favoritesKey = PageStorageKey('bookshelf-scroll');
const _recentKey = PageStorageKey('bookshelf-recent-scroll');

Finder shelf(bool recent) => find.byKey(recent ? _recentKey : _favoritesKey);
Finder get pager => find.byKey(const Key('bookshelf-pager'));
PageController controller(WidgetTester tester) =>
    tester.widget<PageView>(pager).controller!;

void expectSelected(WidgetTester tester, bool recent) {
  final labels = [find.text('收藏 3'), find.text('最近阅读 3')];
  for (var i = 0; i < labels.length; i++) {
    final text = tester.widget<Text>(labels[i]);
    expect(text.style!.decoration, TextDecoration.none);
    expect(
      text.style!.fontWeight,
      (i == 1) == recent ? FontWeight.w700 : FontWeight.w400,
    );
  }
}

void main() {
  testWidgets(
    'shelf pages snap by distance, and a fast flick switches a short drag',
    (tester) async {
      await launch(tester, bookCount: 3);
      final pages = controller(tester);
      final viewport = tester.getRect(pager);
      final width = viewport.width;

      // Short slow drag, under half a page: springs back.
      await tester.drag(pager, Offset(-width * .2, 0));
      await tester.pumpAndSettle();
      expect(pages.page, 0);
      expectSelected(tester, false);

      // Long slow drag, over half a page: switches.
      await tester.drag(pager, Offset(-width * .7, 0));
      await tester.pumpAndSettle();
      expect(pages.page, 1);
      expectSelected(tester, true);
      expect(find.byType(ReaderPage), findsNothing);

      // Short fast flick back: the finger travels under half a page, the
      // release velocity alone must decide (ViewPager-compatible).
      await tester.fling(pager, Offset(width * .25, 0), 2500);
      await tester.pumpAndSettle();
      expect(pages.page, 0);
      expectSelected(tester, false);

      // Same flick forward.
      await tester.fling(pager, Offset(-width * .25, 0), 2500);
      await tester.pumpAndSettle();
      expect(pages.page, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shelf tabs animate and each page retains its vertical position',
    (tester) async {
      await launch(tester);
      final pages = controller(tester);
      final tabs = find.byKey(const Key('bookshelf-tabs'));
      final headerRect = tester.getRect(tabs);
      expect(find.descendant(of: pager, matching: tabs), findsNothing);
      await tester.tap(find.text('最近阅读 9'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(pages.page!, inExclusiveRange(0, 1));
      expect(tester.getRect(tabs), headerRect);
      await tester.pumpAndSettle();
      expect(pages.page, 1);
      await tester.tap(find.text('收藏 9'));
      await tester.pumpAndSettle();
      expect(pages.page, 0);

      await tester.drag(shelf(false), const Offset(0, -230));
      await tester.pumpAndSettle();
      final favoriteOffset = tester
          .widget<CustomScrollView>(shelf(false))
          .controller!
          .offset;
      expect(favoriteOffset, greaterThan(0));
      expect(pages.page, 0);
      final width = tester.getSize(pager).width;
      await tester.drag(pager, Offset(-width * .75, 0));
      await tester.pumpAndSettle();
      expect(pages.page, 1);
      expect(
        tester.widget<CustomScrollView>(shelf(true)).controller!.offset,
        0,
      );
      await tester.drag(shelf(true), const Offset(0, -150));
      await tester.pumpAndSettle();
      final recentOffset = tester
          .widget<CustomScrollView>(shelf(true))
          .controller!
          .offset;
      expect(recentOffset, greaterThan(0));
      await tester.drag(pager, Offset(width * .75, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CustomScrollView>(shelf(false)).controller!.offset,
        closeTo(favoriteOffset, .01),
      );
      await tester.drag(pager, Offset(-width * .75, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CustomScrollView>(shelf(true)).controller!.offset,
        closeTo(recentOffset, .01),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty shelf pages can switch and stop at the outer edges', (
    tester,
  ) async {
    await launch(tester, bookCount: 0);
    final pages = controller(tester);
    expect(find.text('暂无收藏书籍'), findsOneWidget);
    final width = tester.getSize(pager).width;
    await tester.drag(pager, Offset(width, 0));
    await tester.pumpAndSettle();
    expect(pages.page, 0);
    await tester.drag(pager, Offset(-width * .75, 0));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    expect(find.text('暂无最近阅读'), findsOneWidget);
    await tester.drag(pager, Offset(-width, 0));
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    await tester.drag(pager, Offset(width * .75, 0));
    await tester.pumpAndSettle();
    expect(pages.page, 0);
    expect(find.text('暂无收藏书籍'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
