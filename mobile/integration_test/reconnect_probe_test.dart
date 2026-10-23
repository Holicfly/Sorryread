import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/core/discovery/peer_discovery.dart';
import 'package:sorryread_mobile/sync_engine/sync_coordinator.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import '../test/support/test_runtime.dart';

class _RecordingDiscovery extends PeerDiscovery {
  int calls = 0;
  @override
  Future<List<String>> find(String serverId) async {
    calls++;
    final endpoints = await super.find(serverId);
    debugPrint('RECONNECT: engine discovered LAN endpoints $endpoints');
    return endpoints;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'RECONNECT: phone survives desktop process restart and changed port',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await getApplicationSupportDirectory();
        Future<void> waitFor(String name) async {
          final file = File('${directory.path}/$name');
          final deadline = DateTime.now().add(const Duration(minutes: 2));
          while (!await file.exists()) {
            if (DateTime.now().isAfter(deadline)) {
              throw StateError('Missing test signal: $name');
            }
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }

        debugPrint('RECONNECT: ready');
        await waitFor('sync-ticket.json');
        final ticketFile = File('${directory.path}/sync-ticket.json');
        final ticket = PairTicket.parse(await ticketFile.readAsString());
        await ticketFile.delete();
        final repo = await testRepository();
        final storage = MemoryPeerStorage();
        final discovery = _RecordingDiscovery();
        final engine = SyncCoordinator(repo, storage, discovery: discovery);
        try {
          var peer = await engine.pair(ticket);
          var report = await engine.synchronize(peer, manual: true);
          expect(report, isNotNull);
          peer = report!.peer;
          final initialEndpoint = peer.endpoints.first;
          var book = (await repo.books()).single;
          await repo.setFavorite(book, false);
          debugPrint('RECONNECT: restart stable');
          await waitFor('reconnect-stable');
          await File('${directory.path}/reconnect-stable').delete();
          report = await engine.synchronize(
            peer,
            manual: true,
            discover: false,
          );
          expect(report, isNotNull);
          expect(report!.peer.endpoints.first, initialEndpoint);
          expect(discovery.calls, 0);
          peer = report.peer;
          book = (await repo.books()).single;
          expect(book.favorite, isFalse);
          expect(book.progress, .6);
          debugPrint('RECONNECT: stable passed');

          await repo.setFavorite(book, true);
          debugPrint('RECONNECT: restart changed');
          await waitFor('reconnect-changed');
          await File('${directory.path}/reconnect-changed').delete();
          report = await engine.synchronize(peer, manual: true);
          expect(report, isNotNull);
          expect(discovery.calls, 1);
          expect(report!.peer.endpoints.first, isNot(initialEndpoint));
          book = (await repo.books()).single;
          expect(book.favorite, isTrue);
          expect(book.progress, .8);
          expect((await storage.read())!.credential, peer.credential);
          binding.reportData = {
            'stableRestart': true,
            'changedPortDiscovery': true,
            'bidirectional': true,
            'samePhoneProcess': true,
          };
          debugPrint('RECONNECT: changed passed');
        } finally {
          await engine.cancel();
          await repo.close();
        }
      });
      expect(tester.takeException(), isNull);
    },
  );
}
