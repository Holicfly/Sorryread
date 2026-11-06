import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';
import 'package:sorryread_mobile/features/sync/presentation/sync_page.dart';
import 'package:sorryread_mobile/features/sync/presentation/sync_status_card.dart';

import 'app_shell_test.dart' show launch, navigationLabel, router;

void main() {
  for (final origin in [
    (path: '/bookshelf', index: 0, label: '书架'),
    (path: '/profile', index: 2, label: '我的'),
  ]) {
    testWidgets('${origin.label} sync and records return to their own entry', (
      tester,
    ) async {
      await launch(tester, syncState: const SyncViewState());
      if (origin.index != 0) {
        await tester.tap(navigationLabel(origin.label));
        await tester.pumpAndSettle();
      }

      void expectLocation(String path) {
        if (path.endsWith('/records')) {
          // push() keeps RouteInformation on the base URL by default. Check
          // the actual visible records route, including its source branch.
          final page = find.byType(SyncRecordsPage);
          expect(page, findsOneWidget);
          expect(GoRouterState.of(tester.element(page)).uri.path, path);
        } else {
          expect(router(tester).routeInformationProvider.value.uri.path, path);
        }
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          origin.index,
        );
      }

      expectLocation(origin.path);
      final entry = origin.index == 0
          ? find.byType(SyncStatusEntry)
          : find.text('与电脑同步');
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expectLocation('${origin.path}/sync');
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expectLocation(origin.path);

      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('更多记录'));
      await tester.tap(find.text('更多记录'));
      await tester.pumpAndSettle();
      expectLocation('${origin.path}/sync/records');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expectLocation('${origin.path}/sync');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expectLocation(origin.path);
      expect(tester.takeException(), isNull);
    });
  }
}
