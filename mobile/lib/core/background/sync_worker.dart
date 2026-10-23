import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../app/dependencies.dart';
import '../../sync_engine/sync_coordinator.dart';
import '../../sync_engine/sync_transport.dart';

const syncWorkerName = 'sorryread.lan-sync';

@pragma('vm:entry-point')
void syncWorkerDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    final repo = await openSyncRepository();
    final storage = SecurePeerStorage();
    final engine = SyncCoordinator(repo, storage);
    try {
      final peer = await storage.read();
      if (peer == null || await repo.meta('paused') == '1') return true;
      await engine.synchronize(peer);
      return true;
    } on SyncCancelled {
      return true;
    } on PairingRevoked {
      return true;
    } catch (_) {
      return false;
    } finally {
      await engine.cancel();
      await repo.close();
    }
  });
}

Future<void> registerSyncWorker() async {
  await Workmanager().initialize(syncWorkerDispatcher);
  await Workmanager().registerPeriodicTask(
    syncWorkerName,
    syncWorkerName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 1),
  );
}

Future<void> cancelSyncWorker() =>
    Workmanager().cancelByUniqueName(syncWorkerName);
