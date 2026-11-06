import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/discovery/peer_discovery.dart';
import '../data/reading_history.dart';
import '../data/sync_repository.dart';
import 'sync_model.dart';
import 'sync_details.dart';
import 'sync_transport.dart';
import 'local_book_sync.dart';

class PairingRevoked implements Exception {}

class SyncCancelled implements Exception {}

class SyncFailure implements Exception {
  SyncFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class SyncReport {
  SyncReport(
    this.peer,
    this.uploaded,
    this.downloaded, {
    this.watchSupported = false,
  });
  final LinkedPeer peer;
  final int uploaded, downloaded;
  final bool watchSupported;
}

String syncErrorMessage(Object error) {
  if (error is SyncFailure) return error.message;
  if (error is PairingRevoked) return '配对已失效，请重新连接设备';
  if (error is FormatException || error is TypeError) {
    return '同步数据格式或版本不匹配，请更新两端后重试';
  }
  if (error is DioException && error.response?.statusCode == 409) {
    return '电脑已配对或配对已取消，请在电脑检查后重试';
  }
  if (error is DioException && error.response?.statusCode == 413) {
    return '同步数据超过单次安全上限，请先处理进度冲突';
  }
  return '无法连接电脑，请确认两端处于同一局域网，且电脑程序已打开并允许私有网络连接';
}

class SyncCoordinator {
  SyncCoordinator(
    this.repo,
    this.storage, {
    this.allowLoopback = false,
    PeerDiscovery? discovery,
  }) : discovery = discovery ?? PeerDiscovery();
  final SyncRepository repo;
  final PeerStorage storage;
  final bool allowLoopback;
  final PeerDiscovery discovery;
  CancelToken? _cancel;
  bool _running = false;
  Future<void> cancel() async {
    _cancel?.cancel();
    await discovery.stop();
  }

  Future<LinkedPeer> pair(PairTicket ticket) async {
    if (_running) throw SyncFailure('正在连接，请稍候');
    if (await storage.read() != null) throw SyncFailure('请先删除当前连接设备');
    _running = true;
    final cancel = _cancel = CancelToken();
    try {
      Object? lastError;
      for (final endpoint in ticket.endpoints) {
        final transport = SyncTransport(
          endpoint,
          ticket.pin,
          allowLoopback: allowLoopback,
        );
        try {
          final result = await transport.post(
            '/v1/pair',
            {
              'deviceId': repo.deviceId,
              'name': '素若阅读 · Android',
              'token': ticket.token,
            },
            cancel,
            pairing: true,
          );
          if (result['version'] != 1 ||
              result['serverId'] != ticket.serverId ||
              result['credential'] is! String ||
              !RegExp(r'^[a-f0-9]{64}$')
                  .hasMatch(result['credential'] as String)) {
            throw const FormatException('配对响应身份不一致');
          }
          final peer = LinkedPeer(
            serverId: ticket.serverId,
            name: ticket.name,
            endpoints: [
              endpoint,
              ...ticket.endpoints.where((e) => e != endpoint),
            ],
            pin: ticket.pin,
            credential: result['credential'] as String,
          );
          await storage.write(peer);
          await repo.setMeta('snapshot:${peer.serverId}', '0');
          await repo.setMeta('generation', randomId());
          await repo.setMeta('paused', '0');
          await repo.log(true, '设备配对成功');
          return peer;
        } on DioException catch (error) {
          if (CancelToken.isCancel(error)) throw SyncCancelled();
          if (error.response != null) {
            if (error.response!.statusCode == 401) {
              throw SyncFailure('二维码已过期，请在电脑刷新后重新扫码');
            }
            if (error.response!.statusCode == 408) {
              throw SyncFailure('等待电脑确认超时，请重新扫码');
            }
            rethrow;
          }
          lastError = error;
        } finally {
          transport.close();
        }
      }
      throw lastError ?? SyncFailure('没有可用的局域网地址');
    } finally {
      _running = false;
      _cancel = null;
    }
  }

  Future<SyncReport?> synchronize(
    LinkedPeer peer, {
    bool manual = false,
    bool discover = true,
  }) async {
    if (_running || await repo.meta('paused') == '1') return null;
    _running = true;
    final cancel = _cancel = CancelToken();
    final lease = randomId();
    SyncTransport? transport;
    bool acquired = false;
    String? generation;
    Future<void> checkSession() async {
      if (cancel.isCancelled ||
          await repo.meta('generation') != generation ||
          await repo.meta('paused') == '1') {
        throw SyncCancelled();
      }
    }

    Future<void> alive() async {
      await checkSession();
      await repo.renewLease(lease);
    }

    try {
      generation = await repo.meta('generation');
      acquired = await repo.acquireLease(lease);
      if (!acquired) return null;
      Json? hello;
      String? chosen;
      final cached = await repo.meta('endpoint:${peer.serverId}');
      final candidates = [?cached, ...peer.endpoints];
      Future<bool> connectCandidates() async {
        for (final endpoint in candidates.toSet()) {
          if (!isLanEndpoint(endpoint, allowLoopback: allowLoopback)) continue;
          await alive();
          transport?.close();
          transport = SyncTransport(
            endpoint,
            peer.pin,
            credential: peer.credential,
            allowLoopback: allowLoopback,
          );
          try {
            hello = await transport!.get('/v1/hello', cancel);
            if (hello!['version'] != 1 ||
                hello!['serverId'] != peer.serverId ||
                (hello!['clientId'] != null &&
                    hello!['clientId'] != repo.deviceId)) {
              throw SyncFailure('设备身份或协议已变化，请删除当前连接后重新配对');
            }
            chosen = endpoint;
            return true;
          } on DioException catch (error) {
            if (CancelToken.isCancel(error)) throw SyncCancelled();
            if (error.response?.statusCode == 401) throw PairingRevoked();
          }
        }
        return false;
      }

      if (!await connectCandidates()) {
        if (discover) {
          try {
            candidates
              ..clear()
              ..addAll(await discovery.find(peer.serverId));
          } catch (_) {
            candidates.clear();
          }
        } else {
          candidates.clear();
        }
        if (candidates.isEmpty || !await connectCandidates()) {
          throw SyncFailure(syncErrorMessage(Object()));
        }
      }
      final updatedPeer = peer.withEndpoint(chosen!);
      await alive();
      await repo.setMeta('endpoint:${peer.serverId}', chosen!);
      int uploaded = 0, downloaded = 0;
      final details = SyncDetails();
      int acknowledged = sequence(hello!['receivedClientSeq'] as String);
      var localMax = sequence(await repo.meta('seq') ?? '0');
      if (acknowledged > localMax) throw SyncFailure('本机数据与配对身份不一致，请删除连接后重新配对');
      Future<void> pushSnapshot() async {
        await alive();
        final (watermark, records) = await repo.exportSnapshot();
        if (records.length > 50000) throw SyncFailure('本机元数据超过同步上限');
        final descriptor = await transport!.post('/v1/client-snapshot', {
          'seq': '$watermark',
        }, cancel);
        final id = descriptor['id'] as String;
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
          throw const FormatException('快照标识无效');
        }
        final pages = <List<SyncRecord>>[];
        var chunk = <SyncRecord>[];
        int bytes = 0;
        for (final record in records) {
          final size = utf8.encode(jsonEncode(record.toJson())).length;
          if (chunk.length == 128 ||
              (bytes + size > 512 * 1024 && chunk.isNotEmpty)) {
            pages.add(chunk);
            chunk = [];
            bytes = 0;
          }
          if (size > 512 * 1024) throw SyncFailure('单条进度冲突过多，请先选择位置');
          chunk.add(record);
          bytes += size;
        }
        if (chunk.isNotEmpty || pages.isEmpty) pages.add(chunk);
        for (var page = 0; page < pages.length; page++) {
          await alive();
          final last = page == pages.length - 1;
          final response = await transport!.post(
            '/v1/client-snapshot/$id?page=$page&complete=$last',
            {'records': pages[page].map((r) => r.toJson()).toList()},
            cancel,
          );
          if (last &&
              sequence(response['receivedClientSeq'] as String) != watermark) {
            throw const FormatException('快照确认水位无效');
          }
        }
        acknowledged = watermark;
        localMax = watermark;
        uploaded += records.length;
        details.sent(records.map((r) => r.effective));
      }

      if (await repo.meta('snapshot:${peer.serverId}') != '1') {
        await pushSnapshot();
      }
      while (acknowledged < localMax) {
        await alive();
        final available = await repo.localChangesAfter(acknowledged);
        final batch = <SyncChange>[];
        int bytes = 0;
        for (final event in available) {
          if (sequence(event.seq) > localMax) break;
          final size = utf8.encode(jsonEncode(event.toJson())).length;
          if (bytes + size > 512 * 1024 && batch.isNotEmpty) break;
          batch.add(event);
          bytes += size;
        }
        if (batch.isEmpty || sequence(batch.first.seq) != acknowledged + 1) {
          await pushSnapshot();
          break;
        }
        final response = await transport!.post('/v1/push', {
          'changes': batch.map((v) => v.toJson()).toList(),
        }, cancel);
        final next = sequence(response['receivedClientSeq'] as String);
        if (next < sequence(batch.last.seq) || next > localMax) {
          throw const FormatException('同步确认水位无效');
        }
        acknowledged = next;
        uploaded += batch.length;
        details.sent(batch);
      }

      bool snapshot = await repo.meta('snapshot:${peer.serverId}') != '1';
      Future<void> pullSnapshot() async {
        await alive();
        final descriptor = await transport!.post('/v1/snapshot', {}, cancel);
        final pages = descriptor['pages'] as int;
        final watermark = sequence(descriptor['serverSeq'] as String);
        final id = descriptor['id'] as String;
        if (pages < 1 ||
            pages > 391 ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
          throw const FormatException('快照分页无效');
        }
        final records = <SyncRecord>[];
        for (var page = 0; page < pages; page++) {
          await alive();
          final body = await transport!.get(
            '/v1/snapshot/$id?page=$page',
            cancel,
          );
          final chunk = body['records'] as List;
          if (chunk.length > 128) throw const FormatException('快照分页过大');
          records.addAll(
            chunk.map(
              (v) => SyncRecord.fromJson(Map<String, dynamic>.from(v as Map)),
            ),
          );
          if (records.length > 50000) throw const FormatException('快照记录过多');
        }
        await alive();
        details.received(
          await repo.applySnapshot(
            peer.serverId,
            watermark,
            records,
            guard: checkSession,
          ),
        );
        downloaded += records.length;
      }

      if (snapshot) await pullSnapshot();
      while (true) {
        await alive();
        final cursor = await repo.received(peer.serverId);
        final body = await transport!.get('/v1/changes?after=$cursor', cancel);
        final serverSeq = sequence(body['serverSeq'] as String);
        if (body['snapshotRequired'] == true) {
          await pullSnapshot();
          continue;
        }
        final events = (body['changes'] as List)
            .map(
              (v) => SyncChange.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList();
        if (events.isEmpty) {
          if (cursor < serverSeq) {
            await pullSnapshot();
            continue;
          }
          break;
        }
        await alive();
        details.received(
          await repo.applyRemote(peer.serverId, events, guard: checkSession),
        );
        downloaded += events.length;
        if (await repo.received(peer.serverId) >= serverSeq) break;
      }
      if ((hello!['capabilities'] as List?)?.contains('reading-history') ==
          true) {
        var cursor = await repo.desktopReadingCursor(peer.serverId);
        while (true) {
          await alive();
          final page = await transport!.get(
            '/v1/reading-history?after=$cursor',
            cancel,
          );
          final entries = (page['entries'] as List)
              .map((row) => DesktopReadingEntry.fromJson(row as Json))
              .toList();
          if (entries.isEmpty) break;
          if (entries.length > 128 || entries.first.revision <= cursor) {
            throw const FormatException('Invalid desktop reading page');
          }
          await repo.applyDesktopReading(
            peer.serverId,
            entries,
            guard: checkSession,
          );
          cursor = entries.last.revision;
          if (entries.length < 128) break;
        }
      }
      await alive();
      final books = repo.importedBooks;
      if (books != null &&
          (hello!['capabilities'] as List?)?.contains(
                'local-books-lifecycle',
              ) ==
              true) {
        final (sent, received) = await LocalBookSync(
          repo,
          books,
          transport!,
          peer,
          cancel,
          alive,
        ).run();
        uploaded += sent;
        downloaded += received;
      }
      final meaningful = manual || snapshot || uploaded != 0 || downloaded != 0;
      final messages = details.messages;
      // Page detail logs to keep each request bounded, including a large first snapshot.
      for (var i = 0; i < messages.length; i += 128) {
        await alive();
        await transport!.post('/v1/complete', {
          'record': false,
          'details': messages.skip(i).take(128).toList(),
        }, cancel);
      }
      await transport!.post('/v1/complete', {'record': meaningful}, cancel);
      await alive();
      await repo.acknowledge(acknowledged);
      if (meaningful) {
        await repo.logBatch(true, [
          ...messages,
          '同步完成：上传 $uploaded 项，接收 $downloaded 项',
        ]);
      } else {
        await repo.setMeta(
          'lastSuccess',
          DateTime.now().toUtc().toIso8601String(),
        );
      }
      repo.notifyChanges();
      return SyncReport(
        updatedPeer,
        uploaded,
        downloaded,
        watchSupported:
            (hello!['capabilities'] as List?)?.contains('watch') == true,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) throw SyncCancelled();
      if (error.response?.statusCode == 401) throw PairingRevoked();
      await repo.log(false, syncErrorMessage(error));
      rethrow;
    } on SyncCancelled {
      rethrow;
    } catch (error) {
      await repo.log(false, syncErrorMessage(error));
      rethrow;
    } finally {
      transport?.close();
      if (acquired) await repo.releaseLease(lease);
      _cancel = null;
      _running = false;
    }
  }
}
