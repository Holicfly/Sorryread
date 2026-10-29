import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../data/local_library.dart';
import '../../../data/sync_repository.dart';
import '../../reader/data/reader_source.dart';

class DailySaying {
  const DailySaying(this.text, this.date, {this.cached = false});
  final String text, date;
  final bool cached;
}

class DailySayingRepository {
  DailySayingRepository(this.sync, {Dio? http})
    : http =
          http ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 6),
            ),
          );
  final SyncRepository sync;
  final Dio http;
  final _pending = <String, Future<DailySaying>>{};

  Future<DailySaying> load(String date) async {
    DailySaying? saved;
    try {
      final raw = await sync.meta('local:daily-saying');
      if (raw != null) {
        final json = jsonDecode(raw) as Map;
        saved = DailySaying(
          json['text'] as String,
          json['date'] as String,
          cached: true,
        );
        if (saved.date == date && saved.text.isNotEmpty) return saved;
      }
    } on FormatException {
      /* A bad cache must not block a new request. */
    } on TypeError {
      /* Older or incomplete cache. */
    }
    try {
      return await _pending.putIfAbsent(date, () => _fetch(date, saved));
    } finally {
      _pending.remove(date);
    }
  }

  Future<DailySaying> _fetch(String date, DailySaying? fallback) async {
    try {
      final response = await http.get<Object>('https://uapis.cn/api/v1/saying');
      final data = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      final text = data is Map ? (data['text'] as String? ?? '').trim() : '';
      if (text.isEmpty || text.length > 2000) {
        throw const ReaderFailure('每日一句返回内容无效。');
      }
      await sync.setMeta(
        'local:daily-saying',
        jsonEncode({'date': date, 'text': text}),
      );
      return DailySaying(text, date);
    } catch (_) {
      if (fallback != null && fallback.text.isNotEmpty) return fallback;
      throw const ReaderFailure('每日一句暂不可用，点击重试。');
    }
  }

  void dispose() => http.close(force: true);
}

final dailySayingRepositoryProvider = FutureProvider<DailySayingRepository>((
  ref,
) async {
  final repo = DailySayingRepository(
    await ref.watch(syncRepositoryProvider.future),
  );
  ref.onDispose(repo.dispose);
  return repo;
});
final dailySayingProvider = FutureProvider<DailySaying>((ref) async {
  final date =
      ref.watch(localDayProvider).asData?.value ?? localDate(DateTime.now());
  return (await ref.watch(dailySayingRepositoryProvider.future)).load(date);
});
