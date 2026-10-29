import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:sorryread_mobile/features/discover/data/yeshe_index.dart';
import 'package:sorryread_mobile/features/discover/data/discover_repository.dart';

class FakeYesheIndex extends YesheIndexRepository {
  YesheIndexStatus saved = const YesheIndexStatus({
    'count': 120,
    'status': 'paused',
    'pages': 4,
    'total': 25230,
  });
  final calls = <(String, int)>[];
  final delayed = Completer<(List<DiscoverBook>, int)>();
  int starts = 0, pauses = 0, refreshes = 0;
  int statusCalls = 0;
  @override
  Future<YesheIndexStatus> status() async {
    statusCalls++;
    return saved;
  }

  @override
  Future<void> start() async {
    starts++;
    saved = const YesheIndexStatus({'status': 'running', 'count': 120});
  }

  @override
  Future<void> pause() async {
    pauses++;
    saved = const YesheIndexStatus({'status': 'paused', 'count': 120});
  }

  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  Future<(List<DiscoverBook>, int)> search(String query, int offset) async {
    calls.add((query, offset));
    if (query == '延迟') return delayed.future;
    return (
      [
        for (var i = offset; i < (offset + 50).clamp(0, 73); i++)
          DiscoverBook(
            '$query $i',
            'https://yeshezy1.com/artdetail-${i + 1}.html',
            DiscoverMode.yeshe,
          ),
      ],
      73,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'parallel ETA uses this run instead of historical slow download time',
    () {
      const s = YesheIndexStatus({
        'status': 'running',
        'total': 25266,
        'pages': 500,
        'elapsed': 1200000,
        'sessionPages': 24,
        'sessionElapsed': 8000,
        'parallelism': 4,
      });
      expect(s.remaining, '预计剩余 2 分钟');
      expect(s.speed, '约 90 本/秒 · 4 路并发');
      final limited = YesheIndexStatus({
        'status': 'running',
        'cooldownUntil': DateTime.now().millisecondsSinceEpoch + 10000,
      });
      expect(limited.remaining, contains('网站要求等待'));
    },
  );
  testWidgets(
    'UI polling sleeps in background while the native download remains independent',
    (tester) async {
      final repository = FakeYesheIndex();
      final controller = YesheIndexController(repository)..initialize();
      await tester.pump();
      final calls = repository.statusCalls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 10));
      expect(repository.statusCalls, calls);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(repository.statusCalls, greaterThan(calls));
      controller.dispose();
    },
  );
  test('partial cached title search pages locally, ignores stale responses and can return to browsing', () async {
    final repository = FakeYesheIndex();
    final controller = YesheIndexController(repository);
    addTearDown(controller.dispose);
    await controller.poll();
    expect(controller.state.count, 120);
    final old = controller.search('延迟');
    await controller.search('山间');
    repository.delayed.complete((<DiscoverBook>[], 0));
    await old;
    expect(controller.books.length, 50);
    expect(controller.total, 73);
    expect(controller.query, '山间');
    await controller.loadMore();
    expect(controller.books.length, 73);
    await controller.loadMore();
    expect(repository.calls, [('延迟', 0), ('山间', 0), ('山间', 50)]);
    controller.browse();
    expect(controller.query, isNull);
    expect(controller.books, isEmpty);
  });
  test('cache action resumes, pauses and refreshes while preserving partial catalog', () async {
    final repository = FakeYesheIndex();
    final controller = YesheIndexController(repository);
    addTearDown(controller.dispose);
    await controller.poll();
    await controller.action();
    expect(controller.state.running, isTrue);
    await controller.action();
    expect(controller.state.running, isFalse);
    expect(controller.state.count, 120);
    await controller.action(refresh: true);
    expect(repository.refreshes, 1);
    expect(repository.starts, 2);
    expect(repository.pauses, 1);
  });
  test('remaining time uses completed page cost rather than book count', () {
    const state = YesheIndexStatus({
      'status': 'running',
      'total': 300,
      'pages': 3,
      'elapsed': 6000,
    });
    expect(state.progress, .3);
    expect(state.remaining, '预计剩余 1 分钟');
  });
}
