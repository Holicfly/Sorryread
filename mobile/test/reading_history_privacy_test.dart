import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/features/profile/presentation/reading_history_page.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import 'app_shell_test.dart' show launch, router;

void main() {
  testWidgets(
    'special titles default to ***, toggle independently and reset after leaving history',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await launch(
        tester,
        bookCount: 0,
        syncState: const SyncViewState(),
        seed: (repo) async {
          final local = LocalLibrary(repo);
          await local.initialize();
          final now = DateTime.now();
          for (final item in [
            (title: '特殊记录甲', source: '18mh', hour: 13),
            (title: '特殊记录乙', source: 'yeshe', hour: 12),
            (title: '普通阅读记录', source: 'ordinary', hour: 11),
          ]) {
            await local.recordReading(
              {'title': item.title, 'author': '作者', 'sourceId': item.source},
              DateTime(now.year, now.month, now.day, item.hour),
              60000,
            );
          }
          await local.close();
        },
      );
      router(tester).go('/profile/history');
      await tester.pumpAndSettle();
      expect(find.text('***'), findsNWidgets(2));
      expect(find.text('特殊记录甲'), findsNothing);
      expect(find.text('特殊记录乙'), findsNothing);
      expect(find.text('普通阅读记录'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('显示书名').first).value,
        '***',
      );
      await tester.tap(find.text('***').first);
      await tester.pumpAndSettle();
      expect(find.text('特殊记录甲'), findsOneWidget);
      expect(find.text('***'), findsOneWidget);
      expect(
        GoRouterState.of(tester.element(find.byType(ReadingHistoryPage)))
            .uri
            .path,
        '/profile/history',
      );
      await tester.tap(find.text('特殊记录甲'));
      await tester.pumpAndSettle();
      expect(find.text('***'), findsNWidgets(2));
      await tester.tap(find.text('***').last);
      await tester.pumpAndSettle();
      expect(find.text('特殊记录乙'), findsOneWidget);
      router(tester).go('/profile');
      await tester.pumpAndSettle();
      router(tester).go('/profile/history');
      await tester.pumpAndSettle();
      expect(find.text('***'), findsNWidgets(2));
      await tester.tap(find.text('普通阅读记录'));
      await tester.pumpAndSettle();
      expect(
        GoRouterState.of(tester.element(find.byType(ReadingHistoryPage)))
            .uri
            .path,
        '/profile/history',
      );
      expect(find.text('***'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}
