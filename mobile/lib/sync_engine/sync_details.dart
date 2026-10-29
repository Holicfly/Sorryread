import 'sync_model.dart';

/// One final state per entity/field group, so fast progress saves do not flood logs.
class SyncDetails {
  final _sent = <String, SyncChange>{};
  final _received = <String, SyncChange>{};
  void sent(Iterable<SyncChange> changes) {
    for (final c in changes) {
      _sent['${c.entityId}/${c.group}'] = c;
    }
  }

  void received(Iterable<SyncChange> changes) {
    for (final c in changes) {
      _received['${c.entityId}/${c.group}'] = c;
    }
  }

  List<String> get messages => [
    for (final c in _sent.values) describeSyncChange(c, '手机 → 电脑'),
    for (final c in _received.values) describeSyncChange(c, '电脑 → 手机'),
  ];
}

String describeSyncChange(SyncChange c, String direction) {
  final p = c.payload;
  String clean(Object? value) =>
      '$value'.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  final title = clean(p['title'] ?? '未命名').split('').take(200).join();
  final active = p['active'] == true;
  final detail = switch (c.group) {
    'favorite' => '书架收藏 · ${active ? '已收藏' : '取消收藏'}',
    'recent' => '最近阅读 · ${active ? '更新记录' : '移除记录'}',
    _ =>
      !active
          ? '阅读进度 · 移除记录'
          : '阅读进度 · ${clean(p['chapterTitle'] ?? '').isEmpty ? '阅读位置' : clean(p['chapterTitle'])} · ${(((p['progress'] as num?) ?? 0) * 100).toStringAsFixed(1)}%',
  };
  return '$direction · 《$title》\n$detail';
}
