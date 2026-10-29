// Standalone, isolated review app: real Android input and normal Flutter frames,
// without a paused integration-test isolate or the user's database/credentials.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import '../test/app_shell_test.dart' show StaticSyncController;
import '../test/reader_parsing_test.dart' show FixtureReaderRepository;
import '../test/support/test_runtime.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sync = await testRepository();
  const titles = [
    '山间来信',
    '人间草木',
    '山海之间',
    '竹林听风',
    '湖上来信',
    '海风与云',
    '分组验收甲',
    '分组验收乙',
  ];
  for (var i = 0; i < titles.length; i++) {
    final source = i >= 6 ? '18mh' : 'test';
    final payload = <String, dynamic>{
      'kind': 'book',
      'title': titles[i],
      'sourceId': source,
      'sourceName': '合成验收样例',
      'detailUrl': 'https://example.invalid/book/$i',
      'chapterUrl': '',
      'chapterTitle': '',
      'progress': 0,
      'active': true,
      'updatedUtc': '2026-10-26T00:00:00Z',
    };
    await sync.localChange(
      'book:$source|${payload['detailUrl']}',
      'favorite',
      payload,
    );
    if (i.isEven) {
      await sync.localChange(
        'book:$source|${payload['detailUrl']}',
        'recent',
        payload,
      );
    }
  }
  final dir = Directory(
    '${(await getApplicationSupportDirectory()).path}/reader-review',
  );
  await dir.create(recursive: true);
  final rules = [
    for (final id in ['test', '18mh'])
      SourceRule({
        'id': id,
        'baseUrl': 'https://example.invalid',
        'dynamic': false,
        'detail': <String, dynamic>{},
        'catalog': {'itemSelector': '#chapters a'},
        'chapter': {'contentSelector': '#content', 'titleSelector': 'h1'},
      }),
  ];
  const names = [
    '山间来信',
    '雨后的路',
    '灯火',
    '沿河的风',
    '远处的山',
    '茶与书',
    '湖光',
    '星夜',
    '归途',
    '清晨',
  ];
  final reader = FixtureReaderRepository(dir, rules, {
    for (var book = 0; book < titles.length; book++)
      'https://example.invalid/book/$book':
          '<div id="chapters">${List.generate(10, (c) => '<a href="/chapter/$c">第${c + 1}章 ${names[c]}</a>').join()}</div>',
    for (var c = 0; c < 10; c++)
      'https://example.invalid/chapter/$c':
          '<h1>第${c + 1}章 ${names[c]}</h1><div id="content">${List.generate(40, (p) => '<p>${['山里的清晨，总是从一阵轻风开始。窗外的树叶轻轻摇动，阳光穿过枝叶，在书页上留下细碎的光影。', '我把昨天没有读完的信重新展开。纸上的文字安静而清晰，像一条缓缓流过山谷的小溪。', '远处传来鸟鸣，桌上的茶还冒着热气。这是一个适合读书的早晨，时间仿佛也慢了下来。'][p % 3]}</p>').join()}</div>',
  });
  runApp(
    ProviderScope(
      overrides: [
        syncRepositoryProvider.overrideWith((ref) async => sync),
        readerRepositoryProvider.overrideWith((ref) async => reader),
        peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
        backgroundSyncEnabledProvider.overrideWithValue(false),
        syncControllerProvider.overrideWith(
          () => StaticSyncController(SyncViewState()),
        ),
      ],
      child: const ReaderApp(),
    ),
  );
}
