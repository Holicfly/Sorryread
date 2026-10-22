import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/app/router.dart';

Finder navigationLabel(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Future<void> launch(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  await tester.pumpWidget(const ProviderScope(child: ReaderApp()));
  await tester.pumpAndSettle();
}

GoRouter router(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ReaderApp)))
        .read(appRouterProvider);

void main() {
  testWidgets(
    'two tabs retain scroll position; Android back returns to bookshelf',
    (tester) async {
      await launch(tester);
      expect(find.byType(NavigationDestination), findsNWidgets(2));
      expect(find.text('我的书架'), findsOneWidget);

      final shelf = find.byKey(const PageStorageKey('bookshelf-scroll'));
      await tester.drag(shelf, const Offset(0, -230));
      await tester.pumpAndSettle();
      final offset = tester
          .state<ScrollableState>(
            find.descendant(of: shelf, matching: find.byType(Scrollable)),
          )
          .position
          .pixels;
      expect(offset, greaterThan(0));

      await tester.tap(navigationLabel('我的'));
      await tester.pumpAndSettle();
      expect(
        router(tester).routeInformationProvider.value.uri.path,
        '/profile',
      );
      expect(find.text('本地读者'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        router(tester).routeInformationProvider.value.uri.path,
        '/bookshelf',
      );
      expect(
        tester
            .state<ScrollableState>(
              find.descendant(of: shelf, matching: find.byType(Scrollable)),
            )
            .position
            .pixels,
        closeTo(offset, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('placeholder taps do not open pages or change filters', (
    tester,
  ) async {
    await launch(tester);
    await tester.tap(find.text('最近阅读  —'));
    await tester.tap(find.text('与电脑同步'));
    await tester.pumpAndSettle();
    expect(
      router(tester).routeInformationProvider.value.uri.path,
      '/bookshelf',
    );
    expect(find.text('全部  9'), findsOneWidget);
    await tester.tap(navigationLabel('我的'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('阅读记录'));
    await tester.tap(find.text('阅读记录'));
    await tester.pumpAndSettle();
    expect(router(tester).routeInformationProvider.value.uri.path, '/profile');
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (
      name: 'small screen, 200% text',
      size: const Size(320, 640),
      scale: 2.0,
      brightness: Brightness.light,
    ),
    (
      name: 'dark mode',
      size: const Size(390, 844),
      scale: 1.0,
      brightness: Brightness.dark,
    ),
    (
      name: 'landscape safe area',
      size: const Size(844, 390),
      scale: 1.0,
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets('both pages fit ${scenario.name}', (tester) async {
      await launch(
        tester,
        size: scenario.size,
        scale: scenario.scale,
        brightness: scenario.brightness,
      );
      expect(tester.takeException(), isNull);
      final shelf = find.byKey(const PageStorageKey('bookshelf-scroll'));
      await tester.drag(shelf, const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(navigationLabel('我的'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('关于应用'),
        200,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('profile-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('关于应用').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
