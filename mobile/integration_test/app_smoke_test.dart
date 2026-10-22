import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sorryread_mobile/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('CAPTURE_SCREENSHOTS');

  testWidgets('device: tabs, scroll, placeholders and back', (tester) async {
    app.main();
    await tester.pumpAndSettle();
    expect(find.text('我的书架'), findsOneWidget);
    if (capture) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot('bookshelf');
    }
    await tester.tap(find.text('与电脑同步'));
    await tester.pumpAndSettle();
    expect(find.text('我的书架'), findsOneWidget);

    final mine = find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('我的'),
    );
    await tester.tap(mine);
    await tester.pumpAndSettle();
    expect(find.text('本地读者'), findsOneWidget);
    if (capture) await binding.takeScreenshot('profile');
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
    if (capture) await binding.takeScreenshot('profile-options');
    await tester.tap(find.text('关于应用').hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('我的书架'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
