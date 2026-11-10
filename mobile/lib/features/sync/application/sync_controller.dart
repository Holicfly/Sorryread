import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../core/background/sync_worker.dart';
import '../../../data/sync_repository.dart';
import '../../../sync_engine/sync_coordinator.dart';
import '../../../sync_engine/local_book_sync.dart';
import '../../../sync_engine/sync_model.dart';
import '../../../sync_engine/sync_transport.dart';

final peerStorageProvider = Provider<PeerStorage>((ref) => SecurePeerStorage());
final backgroundSyncEnabledProvider = Provider<bool>(
  (ref) => Platform.isAndroid,
);
final allowLoopbackSyncProvider = Provider<bool>((ref) => false);
final syncCoordinatorProvider = Provider<SyncCoordinator>(
  (ref) => SyncCoordinator(
    ref.watch(syncRepositoryProvider).requireValue,
    ref.watch(peerStorageProvider),
    allowLoopback: ref.watch(allowLoopbackSyncProvider),
  ),
);
final syncControllerProvider =
    AsyncNotifierProvider<SyncController, SyncViewState>(SyncController.new);

int syncRetryDelaySeconds(int failures) =>
    failures == 0 ? 15 : min(30, 5 * pow(2, min(failures - 1, 3)).toInt());

class SyncViewState {
  const SyncViewState({
    this.peer,
    this.connected = false,
    this.busy = false,
    this.paused = false,
    this.error,
    this.lastSuccess,
    this.conflicts = const [],
  });
  final LinkedPeer? peer;
  final bool connected, busy, paused;
  final String? error;
  final DateTime? lastSuccess;
  final List<SyncRecord> conflicts;
  SyncViewState copyWith({
    LinkedPeer? peer,
    bool clearPeer = false,
    bool? connected,
    bool? busy,
    bool? paused,
    String? error,
    bool clearError = false,
    DateTime? lastSuccess,
    List<SyncRecord>? conflicts,
  }) => SyncViewState(
    peer: clearPeer ? null : peer ?? this.peer,
    connected: connected ?? this.connected,
    busy: busy ?? this.busy,
    paused: paused ?? this.paused,
    error: clearError ? null : error ?? this.error,
    lastSuccess: lastSuccess ?? this.lastSuccess,
    conflicts: conflicts ?? this.conflicts,
  );
}

class SyncController extends AsyncNotifier<SyncViewState>
    with WidgetsBindingObserver {
  late SyncRepository _repo;
  late PeerStorage _storage;
  late SyncCoordinator _engine;
  Timer? _timer, _debounce, _maxDebounce;
  Future<void>? _operation, _refreshing;
  bool _refreshAgain = false;
  CancelToken? _watchCancel;
  SyncTransport? _watchTransport;
  bool _watchSupported = false, _rerun = false, _queuedManual = false;
  bool _leaseRetry = false;
  int _idleRounds = 0;
  bool _visible = true, _editingPair = false;
  int _failures = 0;

  @override
  Future<SyncViewState> build() async {
    _repo = await ref.watch(syncRepositoryProvider.future);
    _storage = ref.watch(peerStorageProvider);
    _engine = ref.watch(syncCoordinatorProvider);
    final peer = await _storage.read();
    await _repo.setMeta(
      'paused',
      '0',
    ); // A deliberate disconnect lasts only for this application run.
    final subscription = _repo.changes.stream.listen(
      (_) => unawaited(_refresh()),
    );
    final localSubscription = _repo.localChanges.stream.listen(
      (_) => _queueLocalSync(),
    );
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _timer?.cancel();
      _debounce?.cancel();
      _maxDebounce?.cancel();
      _stopWatch();
      unawaited(subscription.cancel());
      unawaited(localSubscription.cancel());
      unawaited(_engine.cancel());
      WidgetsBinding.instance.removeObserver(this);
    });
    final initial = SyncViewState(
      peer: peer,
      lastSuccess: DateTime.tryParse(await _repo.meta('lastSuccess') ?? ''),
      conflicts: (await _repo.records())
          .where((r) => r.hasPositionConflict)
          .toList(),
    );
    if (peer != null) {
      Timer.run(() async {
        if (!ref.mounted) return;
        unawaited(_background());
        await synchronize();
      });
    }
    return initial;
  }

  void _queueLocalSync() {
    if (!_visible || _editingPair || _current.paused || _current.peer == null) {
      return;
    }
    _debounce?.cancel();
    _maxDebounce ??= Timer(const Duration(seconds: 8), _flushLocalSync);
    _debounce = Timer(const Duration(seconds: 2), _flushLocalSync);
  }

  void _flushLocalSync() {
    _debounce?.cancel();
    _maxDebounce?.cancel();
    _maxDebounce = null;
    if (_visible && !_editingPair) unawaited(synchronize());
  }

  SyncViewState get _current => state.asData?.value ?? const SyncViewState();
  void _publish(SyncViewState value) {
    if (ref.mounted) state = AsyncData(value);
  }

  Future<void> _refresh() {
    _refreshAgain = true;
    return _refreshing ??= _drainRefresh().whenComplete(
      () => _refreshing = null,
    );
  }

  Future<void> _drainRefresh() async {
    do {
      _refreshAgain = false;
      if (!ref.mounted) return;
      try {
        final conflicts = (await _repo.records(group: 'position'))
            .where((r) => r.hasPositionConflict)
            .toList();
        final time = DateTime.tryParse(await _repo.meta('lastSuccess') ?? '');
        _publish(_current.copyWith(conflicts: conflicts, lastSuccess: time));
      } catch (_) {
        /* Preserve visible state while a connection is closing. */
      }
    } while (_refreshAgain && ref.mounted);
  }

  Future<void> _background() async {
    if (!ref.read(backgroundSyncEnabledProvider)) return;
    try {
      await registerSyncWorker();
    } catch (_) {
      _publish(_current.copyWith(error: '后台同步暂不可用，打开应用时仍会自动同步'));
    }
  }

  Future<void> pair(PairTicket ticket) async {
    if (_editingPair || _current.busy || _current.peer != null) return;
    _editingPair = true;
    _publish(_current.copyWith(busy: true, clearError: true));
    try {
      final peer = await _engine.pair(ticket);
      _publish(
        _current.copyWith(
          peer: peer,
          paused: false,
          connected: true,
          busy: false,
        ),
      );
      await _background();
    } catch (error) {
      _publish(_current.copyWith(busy: false, error: syncErrorMessage(error)));
    } finally {
      _editingPair = false;
    }
    if (_current.peer != null) await synchronize(manual: true);
  }

  Future<void> synchronize({bool manual = false}) async {
    if (_editingPair) return;
    if (_operation != null) {
      _rerun = true;
      _queuedManual |= manual;
      await _operation;
      return;
    }
    if (_current.peer == null || _current.paused) return;
    _timer?.cancel();
    _debounce?.cancel();
    _maxDebounce?.cancel();
    _maxDebounce = null;
    _stopWatch();
    final task = _drainSync(manual);
    _operation = task;
    try {
      await task;
    } finally {
      _operation = null;
      _schedule();
    }
  }

  Future<void> _drainSync(bool manual) async {
    do {
      _rerun = false;
      _queuedManual = false;
      await _performSync(manual);
      manual = _queuedManual;
    } while (_rerun &&
        _visible &&
        !_editingPair &&
        !_current.paused &&
        _current.peer != null);
  }

  Future<void> _performSync(bool manual) async {
    _leaseRetry = false;
    // Background work never disables or recolors the manual action.
    _publish(_current.copyWith(busy: manual, clearError: true));
    try {
      final report = await _engine.synchronize(
        _current.peer!,
        manual: manual,
        eagerDiscovery: !_current.connected,
        onConnected: (peer) {
          if (!_editingPair && !_current.paused) {
            _publish(_current.copyWith(peer: peer, connected: true));
          }
        },
      );
      if (report != null) {
        _leaseRetry = false;
        _failures = 0;
        _watchSupported = report.watchSupported;
        _idleRounds = report.uploaded + report.downloaded == 0
            ? _idleRounds + 1
            : 0;
        _publish(
          _current.copyWith(
            peer: report.peer,
            connected: true,
            busy: false,
            clearError: true,
          ),
        );
        await _refresh();
      } else {
        // A background worker may own the DB lease. Retain a retry rather than
        // waiting indefinitely for a remote notification with local work pending.
        _leaseRetry = true;
        _publish(_current.copyWith(busy: false));
      }
    } on SyncCancelled {
      _publish(_current.copyWith(busy: false));
    } on PairingRevoked {
      await _storage.delete();
      await _repo.setMeta('generation', randomId());
      if (ref.read(backgroundSyncEnabledProvider)) {
        try {
          await cancelSyncWorker();
        } catch (_) {}
      }
      _publish(
        _current.copyWith(
          clearPeer: true,
          connected: false,
          busy: false,
          error: '配对已失效，请重新连接设备',
        ),
      );
    } catch (error) {
      _failures++;
      _publish(
        _current.copyWith(
          connected: false,
          busy: false,
          error: syncErrorMessage(error),
        ),
      );
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!ref.mounted ||
        !_visible ||
        _current.peer == null ||
        _current.paused ||
        _editingPair) {
      return;
    }
    if (_watchSupported && _failures == 0 && !_leaseRetry) {
      unawaited(_watch());
      return;
    }
    final seconds = _leaseRetry
        ? 5
        : _failures == 0 && _idleRounds > 1
        ? 30
        : !_current.connected && _failures > 0
        ? syncRetryDelaySeconds(_failures).clamp(1, 5)
        : syncRetryDelaySeconds(_failures);
    _timer = Timer(Duration(seconds: seconds), () => unawaited(synchronize()));
  }

  void _stopWatch() {
    _watchCancel?.cancel();
    _watchTransport?.close();
    _watchCancel = null;
    _watchTransport = null;
  }

  Future<void> _watch() async {
    final peer = _current.peer;
    if (peer == null || _watchCancel != null) return;
    final cancel = _watchCancel = CancelToken();
    SyncTransport? transport;
    try {
      final endpoint =
          await _repo.meta('endpoint:${peer.serverId}') ?? peer.endpoints.first;
      if (cancel.isCancelled || !ref.mounted) return;
      transport = SyncTransport(
        endpoint,
        peer.pin,
        credential: peer.credential,
        allowLoopback: ref.read(allowLoopbackSyncProvider),
      );
      _watchTransport = transport;
      while (!cancel.isCancelled &&
          _visible &&
          !_current.paused &&
          !_editingPair) {
        final cursor = await _repo.received(peer.serverId);
        final readingCursor = await _repo.desktopReadingCursor(peer.serverId);
        final booksCursor = await _repo.meta(localBookCursorKey(peer.serverId));
        final response = await transport.get(
          '/v1/watch?after=$cursor&readingAfter=$readingCursor'
          '${booksCursor == null ? '' : '&localBooksAfter=$booksCursor'}',
          cancel,
          timeout: const Duration(seconds: 32),
        );
        if (cancel.isCancelled || !ref.mounted) return;
        if (sequence(response['serverSeq'] as String) != cursor ||
            response['readingChanged'] == true ||
            response['localBooksChanged'] == true) {
          _stopWatch();
          await synchronize();
          return;
        }
      }
    } catch (error) {
      if (cancel.isCancelled || !ref.mounted) return;
      // A missing optional endpoint falls back without changing protocol v1.
      if (error is DioException &&
          [404, 405].contains(error.response?.statusCode)) {
        _watchSupported = false;
      } else {
        _publish(_current.copyWith(connected: false));
        _stopWatch();
        await synchronize();
        return;
      }
      _stopWatch();
      _schedule();
    } finally {
      transport?.close();
      if (identical(_watchCancel, cancel)) {
        _watchCancel = null;
        _watchTransport = null;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    if (!_visible) {
      _timer?.cancel();
      _debounce?.cancel();
      _maxDebounce?.cancel();
      _maxDebounce = null;
      _stopWatch();
      unawaited(_engine.discovery.stop());
    } else {
      _failures = 0;
      unawaited(synchronize());
    }
  }

  Future<void> disconnect() async {
    if (_editingPair || _current.peer == null) return;
    _editingPair = true;
    _timer?.cancel();
    _debounce?.cancel();
    _maxDebounce?.cancel();
    _maxDebounce = null;
    _stopWatch();
    final peer = _current.peer!;
    await _repo.setMeta('paused', '1');
    _publish(
      _current.copyWith(
        paused: true,
        connected: false,
        busy: true,
        clearError: true,
      ),
    );
    try {
      await _engine.cancel();
      await _operation;
      await _tellPeer(peer, delete: false);
      await _repo.log(true, '已断开连接，本次运行暂停自动重连');
    } finally {
      _editingPair = false;
      _publish(_current.copyWith(busy: false));
    }
  }

  Future<void> reconnect() async {
    if (_editingPair || _current.peer == null) return;
    if (_current.paused) await _repo.setMeta('paused', '0');
    _failures = 0;
    _publish(_current.copyWith(paused: false, clearError: true));
    await synchronize(manual: true);
  }

  Future<void> forgetPeer() async {
    if (_editingPair || _current.peer == null) return;
    _editingPair = true;
    _timer?.cancel();
    _debounce?.cancel();
    _maxDebounce?.cancel();
    _maxDebounce = null;
    _stopWatch();
    final peer = _current.peer!;
    _publish(_current.copyWith(busy: true));
    try {
      await _repo.setMeta('paused', '1');
      await _repo.setMeta('generation', randomId());
      await _engine.cancel();
      await _operation;
      await _tellPeer(peer, delete: true);
      await _storage.delete();
      if (ref.read(backgroundSyncEnabledProvider)) {
        try {
          await cancelSyncWorker();
        } catch (_) {}
      }
      await _repo.setMeta('paused', '0');
      await _repo.log(true, '已删除连接设备，阅读数据保留');
      _publish(
        _current.copyWith(
          clearPeer: true,
          paused: false,
          connected: false,
          busy: false,
          clearError: true,
        ),
      );
    } catch (_) {
      _publish(
        _current.copyWith(
          busy: false,
          paused: true,
          connected: false,
          error: '删除配对信息失败，请重试',
        ),
      );
    } finally {
      _editingPair = false;
    }
  }

  Future<void> _tellPeer(LinkedPeer peer, {required bool delete}) async {
    final endpoint =
        await _repo.meta('endpoint:${peer.serverId}') ?? peer.endpoints.first;
    final transport = SyncTransport(
      endpoint,
      peer.pin,
      credential: peer.credential,
      allowLoopback: ref.read(allowLoopbackSyncProvider),
    );
    try {
      if (delete) {
        await transport.delete('/v1/pair', CancelToken());
      } else {
        await transport.post('/v1/disconnect', {}, CancelToken());
      }
    } catch (_) {
      /* Offline deletion is local; desktop can release its own pairing. */
    } finally {
      transport.close();
    }
  }

  Future<void> resolve(SyncRecord record, SyncChange choice) async {
    await _repo.resolvePosition(record, choice);
    await synchronize(manual: true);
  }
}
