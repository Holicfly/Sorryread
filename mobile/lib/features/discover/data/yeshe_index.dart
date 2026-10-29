import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'discover_repository.dart';

class YesheIndexStatus {
  const YesheIndexStatus(this.data);
  final Map<String, dynamic> data;
  int number(String key) => (data[key] as num?)?.toInt() ?? 0;
  int get count => number('count');
  int get pages => number('pages');
  int get total => number('total');
  String get status => data['status'] as String? ?? 'idle';
  String get error => data['error'] as String? ?? '';
  bool get running => status == 'running';
  bool get complete => status == 'complete';
  double? get progress =>
      total == 0 ? null : (pages / ((total + 29) ~/ 30)).clamp(0, 1);
  String get remaining {
    final cooldown =
        number('cooldownUntil') - DateTime.now().millisecondsSinceEpoch;
    if (running && cooldown > 0) {
      return '网站要求等待 ${(cooldown / 1000).ceil()} 秒，已自动降低请求速度';
    }
    final measuredPages = number('sessionPages') > 0
        ? number('sessionPages')
        : pages;
    final measuredMs = number('sessionElapsed') > 0
        ? number('sessionElapsed')
        : number('elapsed');
    if (!running || measuredPages < 3 || measuredMs <= 0 || total == 0) {
      return '正在测速，完成几页后显示剩余时间';
    }
    final ms = measuredMs / measuredPages * (((total + 29) ~/ 30) - pages);
    return '预计剩余 ${(ms / 60000).ceil().clamp(1, 9999)} 分钟';
  }

  String? get speed {
    final elapsed = number('sessionElapsed');
    if (!running || elapsed <= 0 || number('sessionPages') < 3) return null;
    return '约 ${(number('sessionPages') * 30000 / elapsed).round()} 本/秒 · ${number('parallelism').clamp(1, 4)} 路并发';
  }
}

class YesheIndexRepository {
  static const channel = MethodChannel('sorryread/yeshe_index');
  Future<YesheIndexStatus> status() async => YesheIndexStatus(
    Map<String, dynamic>.from(
      await channel.invokeMapMethod<String, dynamic>('status') ?? {},
    ),
  );
  Future<void> start() => channel.invokeMethod<void>('start');
  Future<void> pause() => channel.invokeMethod<void>('pause');
  Future<void> refresh() => channel.invokeMethod<void>('refresh');
  Future<(List<DiscoverBook>, int)> search(String query, int offset) async {
    final json =
        await channel.invokeMapMethod<String, dynamic>('search', {
          'query': query,
          'offset': offset,
        }) ??
        {};
    final books = (json['books'] as List? ?? []).map((item) {
      final b = Map<String, dynamic>.from(item as Map);
      final url = b['url'] as String;
      parseYesheInput(url);
      return DiscoverBook(b['title'] as String, url, DiscoverMode.yeshe);
    }).toList();
    return (books, (json['total'] as num?)?.toInt() ?? 0);
  }
}

final yesheIndexRepositoryProvider = Provider((ref) => YesheIndexRepository());

class YesheIndexController extends ChangeNotifier with WidgetsBindingObserver {
  YesheIndexController(this.repository);
  final YesheIndexRepository repository;
  YesheIndexStatus state = const YesheIndexStatus({});
  final books = <DiscoverBook>[];
  final _seen = <String>{};
  int _offset = 0;
  bool _end = false;
  bool get hasMore => !_end && _offset < total;
  String? query, error, statusError;
  int total = 0, _generation = 0;
  bool loading = false, _disposed = false, _polling = false, actionBusy = false;
  Timer? _timer;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void initialize() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(poll());
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(poll());
      _startTimer();
    } else {
      _timer?.cancel();
    }
  }

  Future<void> poll() async {
    if (_disposed || _polling) return;
    _polling = true;
    try {
      final value = await repository.status();
      if (_disposed) return;
      state = value;
      statusError = null;
    } catch (_) {
      if (!_disposed) statusError = '本地书目状态暂不可用，请重试';
    } finally {
      _polling = false;
      _notify();
    }
  }

  Future<void> action({bool refresh = false}) async {
    if (actionBusy || _disposed) return;
    actionBusy = true;
    _notify();
    try {
      if (refresh) {
        await repository.refresh();
        await repository.start();
      } else if (state.running) {
        await repository.pause();
      } else {
        await repository.start();
      }
      await poll();
    } catch (e) {
      if (!_disposed) {
        statusError = e is PlatformException ? e.message : '书目缓存操作失败，请重试';
      }
    } finally {
      actionBusy = false;
      _notify();
    }
  }

  void browse() {
    _generation++;
    query = null;
    books.clear();
    _seen.clear();
    _offset = 0;
    _end = false;
    loading = false;
    error = null;
    _notify();
  }

  Future<void> search(String keyword) async {
    final generation = ++_generation;
    query = keyword;
    books.clear();
    _seen.clear();
    _offset = 0;
    _end = false;
    total = 0;
    loading = true;
    error = null;
    _notify();
    await _load(generation, 0);
  }

  Future<void> loadMore() async {
    if (query == null || loading || !hasMore) return;
    loading = true;
    error = null;
    _notify();
    await _load(_generation, _offset);
  }

  Future<void> _load(int generation, int offset) async {
    try {
      final (batch, count) = await repository.search(query!, offset);
      if (_disposed || generation != _generation) return;
      books.addAll(batch.where((book) => _seen.add(book.url)));
      _offset = offset + batch.length;
      _end = batch.isEmpty;
      total = count;
    } catch (_) {
      if (!_disposed && generation == _generation) error = '本地搜索失败，点击重试';
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
