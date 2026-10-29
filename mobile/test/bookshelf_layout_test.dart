import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_cover.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_page.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';
import 'package:sorryread_mobile/features/sync/presentation/sync_status_card.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import 'app_shell_test.dart' show launch, router;

void main() {
  testWidgets(
    'shelf has emphasized text tabs, compact sync and three columns',
    (tester) async {
      await launch(
        tester,
        bookCount: 3,
        syncState: SyncViewState(
          peer: LinkedPeer(
            serverId: '2' * 32,
            name: '测试电脑',
            endpoints: ['https://192.168.1.2:12345'],
            pin: 'a' * 64,
            credential: 'b' * 64,
          ),
          connected: true,
        ),
      );
      expect(find.text('我的书架'), findsNothing);
      expect(find.text('收藏书籍'), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(SyncStatusCard), findsNothing);
      expect(find.byType(SyncStatusEntry), findsOneWidget);
      expect(find.text('测试电脑'), findsOneWidget);
      final favorites = tester.widget<Text>(find.text('收藏 3'));
      final recent = tester.widget<Text>(find.text('最近阅读 3'));
      expect(favorites.style!.fontWeight, FontWeight.w700);
      expect(favorites.style!.fontSize!, greaterThan(recent.style!.fontSize!));
      expect(favorites.style!.color, isNot(recent.style!.color));
      expect(favorites.style!.decoration, TextDecoration.none);
      expect(recent.style!.decoration, TextDecoration.none);
      final tabs = tester.getRect(find.byKey(const Key('bookshelf-tabs')));
      final sync = tester.getRect(find.byType(SyncStatusEntry));
      final covers = find.byType(BookCover);
      expect(covers, findsNWidgets(3));
      final first = tester.getRect(covers.at(0));
      final second = tester.getRect(covers.at(1));
      final third = tester.getRect(covers.at(2));
      expect(first.top, second.top);
      expect(second.top, third.top);
      expect(sync.left, greaterThan(tabs.right));
      expect((sync.center.dy - tabs.center.dy).abs(), lessThan(1));
      expect(first.top - tabs.bottom, inInclusiveRange(0, 30));
      await tester.tap(find.text('与电脑同步'));
      await tester.pumpAndSettle();
      expect(
        router(tester).routeInformationProvider.value.uri.path,
        '/bookshelf/sync',
      );
      expect(find.text('测试电脑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'book overflow menu opens management without opening the reader',
    (tester) async {
      await launch(tester, bookCount: 1);
      var haptics = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') haptics++;
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.tap(find.byTooltip('管理《测试书籍 0》'));
      await tester.pumpAndSettle();
      expect(haptics, 1);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('取消收藏'), findsOneWidget);
      expect(find.text('移出最近阅读'), findsOneWidget);
      expect(find.byType(ReaderPage), findsNothing);
      expect(
        router(tester).routeInformationProvider.value.uri.path,
        '/bookshelf',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
