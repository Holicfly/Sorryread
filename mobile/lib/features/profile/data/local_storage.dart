import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class StorageSnapshot {
  const StorageSnapshot({
    required this.necessary,
    required this.downloads,
    required this.cache,
    required this.deviceTotal,
    required this.deviceFree,
    required this.indexCount,
    this.indexUpdated = 0,
    this.indexRunning = false,
    this.failedFiles = 0,
  });

  factory StorageSnapshot.fromMap(Map<String, dynamic> data) {
    int number(String key) =>
        ((data[key] as num?)?.toInt() ?? 0).clamp(0, 1 << 62);
    return StorageSnapshot(
      necessary: number('necessary'),
      downloads: number('downloads'),
      cache: number('cache'),
      deviceTotal: number('deviceTotal'),
      deviceFree: number('deviceFree'),
      indexCount: number('indexCount'),
      indexUpdated: number('indexUpdated'),
      indexRunning: data['indexRunning'] == true,
      failedFiles: number('failedFiles'),
    );
  }

  final int necessary, downloads, cache, deviceTotal, deviceFree;
  final int indexCount, indexUpdated, failedFiles;
  final bool indexRunning;
  int get total => necessary + downloads + cache;
  bool get hasIndex => downloads > 0 || indexCount > 0 || indexRunning;
}

String storageSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class LocalStorageRepository {
  static const channel = MethodChannel('sorryread/local_storage');
  Future<StorageSnapshot> _call(String method) async => StorageSnapshot.fromMap(
    Map<String, dynamic>.from(
      await channel.invokeMapMethod<String, dynamic>(method) ?? {},
    ),
  );
  Future<StorageSnapshot> snapshot() => _call('snapshot');
  Future<StorageSnapshot> clearCache() => _call('clearCache');
  Future<StorageSnapshot> deleteYesheIndex() => _call('deleteYesheIndex');
  // Future book/media download managers should supply aggregate entries here.
  // The current managed resource is only the Yeshe title/link search index.
}

final localStorageRepositoryProvider = Provider(
  (ref) => LocalStorageRepository(),
);
final localStorageProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(localStorageRepositoryProvider).snapshot(),
);
