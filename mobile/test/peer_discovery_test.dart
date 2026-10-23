import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:sorryread_mobile/core/discovery/peer_discovery.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

const server = '11111111111111111111111111111111';
const short = Duration(milliseconds: 25);

nsd.Discovery found([String id = 'test']) => nsd.Discovery(id)
  ..add(
    nsd.Service(
      name: id,
      type: '_sorryread._tcp',
      port: 54321,
      txt: {'id': Uint8List.fromList(utf8.encode(server))},
      addresses: [
        InternetAddress('fe80::1'),
        InternetAddress('10.0.0.2'),
        InternetAddress('fd00::1'),
      ],
    ),
  );

void main() {
  test(
    'multi-NIC desktop TXT supplies Wi-Fi even when native host is wired only',
    () async {
      final native = nsd.Discovery('multi')
        ..add(
          nsd.Service(
            name: 'multi',
            type: '_sorryread._tcp',
            host: '172.16.56.36',
            port: 54321,
            txt: {
              'id': Uint8List.fromList(utf8.encode(server)),
              'a': Uint8List.fromList(
                utf8.encode('172.16.56.36,10.0.50.152,8.8.8.8,fe80::1'),
              ),
            },
          ),
        );
      final discovery = PeerDiscovery(
        startDiscovery: () async => native,
        stopDiscovery: (_) async {},
      );
      expect(await discovery.find(server), [
        'https://172.16.56.36:54321',
        'https://10.0.50.152:54321',
      ]);
    },
  );
  test('foreground reconnect backs off but never waits five minutes', () {
    expect([0, 1, 2, 3, 4, 20].map(syncRetryDelaySeconds), [
      15,
      5,
      10,
      20,
      30,
      30,
    ]);
  });
  test(
    'native start timeout finishes; late handles are stopped once',
    () async {
      final start = Completer<nsd.Discovery>();
      final stopped = <String>[];
      final discovery = PeerDiscovery(
        startDiscovery: () => start.future,
        stopDiscovery: (value) async {
          stopped.add(value.id);
        },
        startTimeout: short,
      );
      expect(
        await discovery.find(server).timeout(const Duration(seconds: 1)),
        isEmpty,
      );
      start.complete(found('late'));
      await Future<void>.delayed(short);
      expect(stopped, ['late']);
      await discovery.stop();
      expect(stopped, ['late']);
    },
  );

  test(
    'native stop timeout does not hold a successful result or the next search',
    () async {
      var starts = 0;
      final discovery = PeerDiscovery(
        startDiscovery: () async => found('${++starts}'),
        stopDiscovery: (_) => Completer<void>().future,
        stopTimeout: short,
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        expect(
          await discovery.find(server).timeout(const Duration(seconds: 1)),
          ['https://10.0.0.2:54321', 'https://[fd00::1]:54321'],
        );
      }
      expect(starts, 2);
    },
  );

  test(
    'cancellation stops a search without waiting for discovery timeout',
    () async {
      var stops = 0;
      final discovery = PeerDiscovery(
        startDiscovery: () async => nsd.Discovery('waiting'),
        stopDiscovery: (_) async {
          stops++;
        },
      );
      final pending = discovery.find(server);
      await Future<void>.delayed(short);
      await discovery.stop();
      expect(await pending.timeout(const Duration(seconds: 1)), isEmpty);
      expect(stops, 1);
    },
  );

  test(
    'cancel during native start cannot replace a subsequent discovery',
    () async {
      final late = Completer<nsd.Discovery>();
      final stopped = <String>[];
      var starts = 0;
      final discovery = PeerDiscovery(
        startDiscovery: () =>
            ++starts == 1 ? late.future : Future.value(found('new')),
        stopDiscovery: (value) async {
          stopped.add(value.id);
        },
      );
      final first = discovery.find(server);
      await Future<void>.delayed(short);
      await discovery.stop();
      expect(await first, isEmpty);
      expect(await discovery.find(server), contains('https://10.0.0.2:54321'));
      late.complete(found('old'));
      await Future<void>.delayed(short);
      expect(stopped, ['new', 'old']);
    },
  );

  test(
    'wrong desktop identity is ignored and the search remains bounded',
    () async {
      final discovery = PeerDiscovery(
        startDiscovery: () async => found(),
        stopDiscovery: (_) async {},
        searchTimeout: short,
      );
      expect(await discovery.find('22222222222222222222222222222222'), isEmpty);
    },
  );

  test('native start failure does not poison the next discovery', () async {
    var fail = true;
    final discovery = PeerDiscovery(
      startDiscovery: () async {
        if (fail) throw StateError('synthetic failure');
        return found();
      },
      stopDiscovery: (_) async {},
    );
    await expectLater(discovery.find(server), throwsStateError);
    fail = false;
    expect(await discovery.find(server), contains('https://10.0.0.2:54321'));
  });
}
