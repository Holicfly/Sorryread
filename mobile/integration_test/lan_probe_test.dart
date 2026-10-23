import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:sorryread_mobile/core/discovery/peer_discovery.dart';
import 'package:sorryread_mobile/sync_engine/sync_coordinator.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import '../test/support/test_runtime.dart';

// Explicit opt-in diagnostic target: no USB forwarding and no loopback allowance.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('LAN: discover, pair and exchange isolated synthetic state', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await getApplicationSupportDirectory();
      final input = File('${directory.path}/sync-ticket.json');
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (!await input.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Missing isolated test ticket');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final ticket = PairTicket.parse(await input.readAsString());
      await input.delete();
      final image = File('${directory.path}/sync-qr.png');
      if (await image.exists()) {
        final scanner = MobileScannerController();
        try {
          expect((await image.readAsBytes()).take(8).toList(), [
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
          ]);
          final decoded = await scanner.analyzeImage(
            image.path,
            formats: [BarcodeFormat.qrCode],
          );
          final parsed = PairTicket.parse(decoded!.barcodes.single.rawValue!);
          expect(parsed.serverId, ticket.serverId);
          expect(parsed.token, ticket.token);
          debugPrint('LAN: native QR image decoder passed');
        } finally {
          await scanner.dispose();
          await image.delete();
        }
      }
      final discovery = PeerDiscovery();
      final discovered = await discovery.find(ticket.serverId);
      debugPrint(
        'LAN: native discovery matched ${discovered.length} endpoint(s)',
      );
      binding.reportData = {'discovered': discovered.length};
      final repo = await testRepository();
      final engine = SyncCoordinator(repo, MemoryPeerStorage());
      try {
        final peer = await engine.pair(ticket);
        await engine.synchronize(peer, manual: true);
        expect((await repo.books()).single.favorite, isTrue);
        binding.reportData = {...?binding.reportData, 'exchange': true};
      } finally {
        await engine.cancel();
        await repo.close();
      }
    });
    expect(tester.takeException(), isNull);
  });
}
