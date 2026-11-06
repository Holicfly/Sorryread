import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/sync_engine/sync_coordinator.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import 'support/test_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final path = Platform.environment['SORRYREAD_LOCAL_BOOK_TICKET'];
  test(
    'pinned HTTPS syncs originals, catalog, pauses, reimports and deletes both ways',
    () async {
      final host = File(path!).parent;
      final root = await Directory.systemTemp.createTemp(
        'sorryread-local-live-',
      );
      final repo = SyncRepository(
        SyncDatabase(NativeDatabase.memory()),
        bookDirectory: Directory('${root.path}/books'),
      );
      final storage = MemoryPeerStorage();
      final engine = SyncCoordinator(repo, storage, allowLoopback: true);
      addTearDown(() async {
        await engine.cancel();
        await repo.close();
        await root.delete(recursive: true);
      });
      await repo.initialize();
      final store = repo.importedBooks!;
      Future<void> command(Map<String, dynamic> value) async {
        final target = File('${host.path}/command.json');
        final staged = await File('${host.path}/command.next')
            .writeAsString(jsonEncode(value));
        await staged.rename(target.path);
        final limit = DateTime.now().add(const Duration(seconds: 12));
        while (await target.exists() && DateTime.now().isBefore(limit)) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        expect(
          await target.exists(),
          isFalse,
          reason: 'C# test host did not process ${value['kind']}',
        );
      }

      Future<List<Map<String, dynamic>>> desktopBooks() async {
        for (var retry = 0; retry < 10; retry++) {
          try {
            final data = jsonDecode(
              await File('${host.path}/state.json').readAsString(),
            ) as Map;
            return (data['local'] as List)
                .map(
                  (item) =>
                      (item as Map<String, dynamic>)['state']
                          as Map<String, dynamic>,
                )
                .toList();
          } on FormatException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        throw const FormatException('Could not read desktop fixture state');
      }

      final source = await File('${root.path}/电脑测试.txt')
          .writeAsString('第一章 出发\n这是电脑导入的正文。\n第二章 抵达\n这里是第二节正文。');
      await command({'kind': 'local-import', 'path': source.path});
      final peer = await engine.pair(
        PairTicket.parse(await File(path).readAsString(), allowLoopback: true),
      );
      Future<void> sync() async {
        expect(await engine.synchronize(peer, manual: true), isNotNull);
      }

      await sync();
      final desktop = (await store.books()).single;
      expect(desktop.ready, isTrue);
      expect(
        await store.original(desktop).readAsBytes(),
        await source.readAsBytes(),
      );
      expect((await store.catalog(desktop.hash)).map((unit) => unit.title), [
        '第一章 出发',
        '第二章 抵达',
      ]);
      await store.updatePosition(desktop.hash, desktop.epoch, 0, .52);
      await sync();
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect((await desktopBooks()).single['position'], {
        'index': 0,
        'progress': .52,
      });

      final phoneSource = await File('${root.path}/手机测试.txt')
          .writeAsString('第一章 本地\n来自手机的正文。');
      final phone = await store.importFile(
        phoneSource,
        '手机测试.txt',
        server: peer.serverId,
      );
      await sync();
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect(
        (await desktopBooks()).map((row) => row['sha256']),
        contains(phone.hash),
      );
      expect(
        await File('${host.path}/books/${phone.hash}.txt').readAsBytes(),
        await phoneSource.readAsBytes(),
      );
      expect(
        (await repo.books())
            .where((book) => book.imported != null)
            .every((book) => !book.recent),
        isTrue,
      );

      await store.remove(desktop.hash, server: peer.serverId, both: false);
      await sync();
      await command({
        'kind': 'local-read',
        'sha': desktop.hash,
        'index': 1,
        'progress': .35,
      });
      await sync();
      expect(await store.book(desktop.hash), isNull);
      expect(
        (await desktopBooks()).map((row) => row['sha256']),
        contains(desktop.hash),
      );
      await store.importFile(source, '改名.txt', server: peer.serverId);
      await sync();
      expect((await store.book(desktop.hash))!.index, 1);
      expect((await store.book(desktop.hash))!.progress, .35);

      await command({
        'kind': 'local-remove',
        'sha': desktop.hash,
        'both': false,
      });
      await sync();
      await store.updatePosition(desktop.hash, 0, 1, .8);
      await sync();
      expect(await store.book(desktop.hash), isNotNull);
      expect(
        (await desktopBooks()).map((row) => row['sha256']),
        isNot(contains(desktop.hash)),
      );
      await command({'kind': 'local-import', 'path': source.path});
      await sync();
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect(
        (await desktopBooks()).firstWhere(
          (row) => row['sha256'] == desktop.hash,
        )['position'],
        {'index': 1, 'progress': .8},
      );

      await command({
        'kind': 'local-remove',
        'sha': desktop.hash,
        'both': true,
      });
      await sync();
      expect(await store.book(desktop.hash), isNull);
      expect(await store.original(desktop).exists(), isFalse);
      final renewed = await store.importFile(
        source,
        '新一轮.txt',
        server: peer.serverId,
      );
      expect(renewed.epoch, 1);
      await sync();
      expect((await store.book(desktop.hash))!.position, isNull);
      await store.remove(phone.hash, server: peer.serverId, both: true);
      await sync();
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect(
        (await desktopBooks()).map((row) => row['sha256']),
        isNot(contains(phone.hash)),
      );
      expect(
        await File('${host.path}/books/${phone.hash}.txt').exists(),
        isFalse,
      );
      expect(await phoneSource.exists(), isTrue);
      final epubPath = Platform.environment['SORRYREAD_LOCAL_BOOK_EPUB'];
      final mobiPath = Platform.environment['SORRYREAD_MOBI_SAMPLES'];
      for (final (path, name) in [
        if (epubPath != null) (epubPath, '跨端漫画.epub'),
        if (mobiPath != null)
          ('$mobiPath/sample-unicode-huffdic.mobi', '跨端压缩书.mobi'),
      ]) {
        final file = File(path);
        final book = await store.importFile(file, name, server: peer.serverId);
        await sync();
        expect(
          await File('${host.path}/books/${book.hash}.${book.format}')
              .readAsBytes(),
          await file.readAsBytes(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 550));
        expect(
          (await desktopBooks()).firstWhere(
            (row) => row['sha256'] == book.hash,
          )['catalogHash'],
          book.catalogHash,
        );
      }
    },
    skip: path == null,
    timeout: const Timeout(Duration(seconds: 80)),
  );
}
