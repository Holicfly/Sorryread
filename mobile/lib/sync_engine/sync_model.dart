import 'dart:convert';

typedef Json = Map<String, dynamic>;

int sequence(String text) {
  if (!RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(text)) {
    throw const FormatException('同步序号无效');
  }
  final value = int.parse(text);
  if (value < 0) throw const FormatException('同步序号无效');
  return value;
}

class SyncChange {
  SyncChange({
    required this.entityId,
    required this.group,
    required this.origin,
    required this.seq,
    required this.clock,
    required this.payload,
  });
  final String entityId, group, origin, seq;
  final Map<String, String> clock;
  final Json payload;

  factory SyncChange.fromJson(Json json) => SyncChange(
    entityId: json['entityId'] as String,
    group: json['group'] as String,
    origin: json['origin'] as String,
    seq: json['seq'] as String,
    clock: Map<String, String>.from(json['clock'] as Map),
    payload: Map<String, dynamic>.from(json['payload'] as Map),
  )..validate();

  Json toJson() => {
    'entityId': entityId,
    'group': group,
    'origin': origin,
    'seq': seq,
    'clock': clock,
    'payload': payload,
  };

  void validate() {
    final p = payload;
    final id = RegExp(r'^[a-f0-9]{32}$');
    final kind = p['kind'];
    final detail = p['detailUrl'];
    bool web(dynamic value) {
      if (value is! String || value.length > 4096) return false;
      final uri = Uri.tryParse(value);
      return uri != null &&
          ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty;
    }

    final expected = kind == 'book'
        ? 'book:${(p['sourceId'] as String).trim().toLowerCase()}|${(detail as String).trim().replaceFirst(RegExp(r'/+$'), '')}'
        : 'url:$detail';
    if (!['favorite', 'recent', 'position'].contains(group) ||
        !['book', 'url'].contains(kind) ||
        (kind == 'url' && group != 'position') ||
        !id.hasMatch(origin) ||
        sequence(seq) < 1 ||
        clock.isEmpty ||
        clock.length > 64 ||
        clock[origin] != seq ||
        entityId != expected ||
        !web(detail) ||
        (p['chapterUrl'] != '' && !web(p['chapterUrl'])) ||
        p['active'] is! bool ||
        p['progress'] is! num ||
        !(p['progress'] as num).isFinite ||
        (p['progress'] as num) < 0 ||
        (p['progress'] as num) > 1 ||
        (p['title'] as String).length > 512 ||
        (p['chapterTitle'] as String).length > 512 ||
        (p['sourceId'] as String).length > 128 ||
        (p['sourceName'] as String).length > 128 ||
        DateTime.tryParse(p['updatedUtc'] as String) == null ||
        (p['paragraphIndex'] != null &&
            (p['paragraphIndex'] is! int || p['paragraphIndex'] < 0)) ||
        (p['characterOffset'] != null &&
            (p['characterOffset'] is! int || p['characterOffset'] < 0)) ||
        (p['contentHash'] != null &&
            (p['contentHash'] as String).length > 128)) {
      throw const FormatException('不支持的同步记录或字段格式');
    }
    for (final entry in clock.entries) {
      if (!id.hasMatch(entry.key) || sequence(entry.value) < 1) {
        throw const FormatException('同步因果版本无效');
      }
    }
  }
}

class SyncRecord {
  SyncRecord(this.entityId, this.group, this.versions);
  final String entityId, group;
  final List<SyncChange> versions;
  factory SyncRecord.fromJson(Json json) {
    final result = SyncRecord(
      json['entityId'] as String,
      json['group'] as String,
      (json['versions'] as List)
          .map((v) => SyncChange.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList(),
    );
    if (result.versions.isEmpty ||
        result.versions.length > 64 ||
        result.versions.any(
          (v) => v.entityId != result.entityId || v.group != result.group,
        )) {
      throw const FormatException('同步状态无效');
    }
    return result;
  }
  Json toJson() => {
    'entityId': entityId,
    'group': group,
    'versions': versions.map((v) => v.toJson()).toList(),
  };
  SyncChange get effective {
    if (group == 'position') return versions.first;
    final sorted = [...versions]
      ..sort((a, b) {
        final removal = (a.payload['active'] == true ? 1 : 0).compareTo(
          b.payload['active'] == true ? 1 : 0,
        );
        return removal != 0 ? removal : compareChanges(a, b);
      });
    return sorted.first;
  }
}

int compareChanges(SyncChange a, SyncChange b) {
  final origin = a.origin.compareTo(b.origin);
  return origin != 0 ? origin : sequence(a.seq).compareTo(sequence(b.seq));
}

Map<String, String> joinClocks(Iterable<SyncChange> versions) {
  final result = <String, String>{};
  for (final v in versions) {
    for (final e in v.clock.entries) {
      if (sequence(e.value) > sequence(result[e.key] ?? '0')) {
        result[e.key] = e.value;
      }
    }
  }
  return result;
}

bool _covers(SyncChange newer, SyncChange older) => older.clock.entries.every(
  (e) => sequence(newer.clock[e.key] ?? '0') >= sequence(e.value),
);

String canonicalJson(dynamic value) {
  dynamic sorted(dynamic v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(v[key])};
    }
    if (v is List) return v.map(sorted).toList();
    if (v is num && v == v.toInt()) return v.toInt();
    return v;
  }

  return jsonEncode(sorted(value));
}

SyncRecord mergeRecord(SyncRecord? old, SyncChange incoming) {
  incoming.validate();
  if (old != null &&
      (old.entityId != incoming.entityId || old.group != incoming.group)) {
    throw const FormatException('记录分组不一致');
  }
  final versions = old?.versions ?? <SyncChange>[];
  for (final v in versions) {
    if (v.origin == incoming.origin && v.seq == incoming.seq) {
      if (canonicalJson(v.toJson()) != canonicalJson(incoming.toJson())) {
        throw const FormatException('同一变更身份包含不同内容');
      }
      return old!;
    }
  }
  if (versions.any((v) => _covers(v, incoming))) return old!;
  final merged = [...versions.where((v) => !_covers(incoming, v)), incoming]
    ..sort(compareChanges);
  if (merged.length > 64) throw const FormatException('进度冲突候选过多，请先处理冲突');
  return SyncRecord(incoming.entityId, incoming.group, merged);
}
