import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../features/local_books/local_book_parser.dart';
import '../sync_engine/sync_model.dart';

class ImportedBook {
  const ImportedBook(
    this.state,
    this.epoch,
    this.ready,
    this.coverPath,
    this.dirty,
  );
  final Json state;
  final int epoch;
  final bool ready, dirty;
  final String? coverPath;
  String get hash => state['sha256'] as String;
  String get id => localBookId(hash);
  String get title => state['title'] as String;
  String get format => state['format'] as String;
  String get catalogHash => state['catalogHash'] as String;
  int get unitCount => state['unitCount'] as int;
  int get size => state['size'] as int;
  bool get comic => state['comic'] == true;
  bool get favorite => state['favorite'] == true;
  Json? get position => state['position'] as Json?;
  int get index => position?['index'] as int? ?? 0;
  double get progress => (position?['progress'] as num?)?.toDouble() ?? 0;
  double get overall => ((index + progress) / unitCount).clamp(0, 1);
}

class BookPolicy {
  const BookPolicy(
    this.hash,
    this.revision,
    this.epoch,
    this.removed,
    this.desktopExcluded,
    this.phoneExcluded, [
    this.resetEpoch = 0,
  ]);
  factory BookPolicy.fromJson(Json json) {
    final hash = json['sha256'] as String;
    final revision = int.parse(json['revision'] as String);
    final epoch = json['epoch'] as int;
    final reset =
        json['resetEpoch'] as int? ?? (json['removed'] == true ? epoch : 0);
    if (!isBookHash(hash) ||
        revision < 0 ||
        epoch < 0 ||
        reset < 0 ||
        reset > epoch)
      throw const FormatException('无效的本地书移出状态');
    return BookPolicy(
      hash,
      revision,
      epoch,
      json['removed'] == true,
      json['desktopExcluded'] == true,
      json['phoneExcluded'] == true,
      reset,
    );
  }
  final String hash;
  final int revision, epoch, resetEpoch;
  final bool removed, desktopExcluded, phoneExcluded;
  bool get blocked => removed || desktopExcluded || phoneExcluded;
}

class BookOperation {
  const BookOperation(this.order, this.id, this.hash, this.action, this.epoch);
  final int order, epoch;
  final String id, hash, action;
  Json toJson() => {'id': id, 'action': action, 'epoch': epoch};
}

class ImportedBooks {
  ImportedBooks(
    this.db,
    this.root,
    this._changed,
    this._id,
    this._removed,
    this._remotePosition,
  );
  final GeneratedDatabase db;
  final Directory root;
  final void Function(bool local) _changed;
  final String Function() _id;
  final void Function(String id) _removed;
  final void Function(ImportedBook book) _remotePosition;

  static const schema = [
    'CREATE TABLE imported_books(sha TEXT PRIMARY KEY,state TEXT NOT NULL,epoch INTEGER NOT NULL,ready INTEGER NOT NULL,cover INTEGER NOT NULL,dirty INTEGER NOT NULL)',
    'CREATE TABLE imported_units(sha TEXT NOT NULL,idx INTEGER NOT NULL,title TEXT NOT NULL,address TEXT NOT NULL,blocks TEXT NOT NULL,PRIMARY KEY(sha,idx))',
    'CREATE TABLE imported_policies(server TEXT NOT NULL,sha TEXT NOT NULL,revision INTEGER NOT NULL,epoch INTEGER NOT NULL,removed INTEGER NOT NULL,desktop INTEGER NOT NULL,phone INTEGER NOT NULL,reset_epoch INTEGER NOT NULL,PRIMARY KEY(server,sha))',
    'CREATE TABLE imported_mutes(sha TEXT PRIMARY KEY)',
    'CREATE TABLE imported_ops(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL,server TEXT NOT NULL,sha TEXT NOT NULL,action TEXT NOT NULL,epoch INTEGER NOT NULL)',
  ];

  File original(ImportedBook book) =>
      File('${root.path}/${book.hash}.${book.format}');
  File partial(String peer, String hash, int epoch) =>
      File('${root.path}/$peer-$hash-$epoch.part');
  File _cover(String hash) => File('${root.path}/$hash.cover');

  ImportedBook _read(QueryRow row) {
    final state = jsonDecode(row.read<String>('state')) as Json;
    return ImportedBook(
      state,
      row.read<int>('epoch'),
      row.read<int>('ready') == 1,
      row.read<int>('cover') == 1
          ? _cover(state['sha256'] as String).path
          : null,
      row.read<int>('dirty') == 1,
    );
  }

  Future<List<ImportedBook>> books() async =>
      (await db
              .customSelect('SELECT * FROM imported_books ORDER BY rowid DESC')
              .get())
          .map(_read)
          .toList();

  Future<ImportedBook?> book(String hash) async {
    final row = await db
        .customSelect(
          'SELECT * FROM imported_books WHERE sha=?',
          variables: [Variable(hash)],
        )
        .getSingleOrNull();
    return row == null ? null : _read(row);
  }

  Future<List<BookUnit>> catalog(String hash) async =>
      (await db
              .customSelect(
                'SELECT title,address FROM imported_units WHERE sha=? ORDER BY idx',
                variables: [Variable(hash)],
              )
              .get())
          .map(
            (row) => BookUnit(
              row.read<String>('title'),
              row.read<String>('address'),
              const [],
            ),
          )
          .toList();

  Future<List<BookBlock>> blocks(String hash, int index) async {
    final row = await db
        .customSelect(
          'SELECT blocks FROM imported_units WHERE sha=? AND idx=?',
          variables: [Variable(hash), Variable(index)],
        )
        .getSingleOrNull();
    if (row == null) throw const FormatException('章节内容尚未就绪');
    return (jsonDecode(row.read<String>('blocks')) as List)
        .map((item) => BookBlock.fromJson(item as Json))
        .toList();
  }

  Future<BookPolicy> policy(String server, String hash) async {
    final row = await db
        .customSelect(
          'SELECT * FROM imported_policies WHERE server=? AND sha=?',
          variables: [Variable(server), Variable(hash)],
        )
        .getSingleOrNull();
    return row == null
        ? BookPolicy(hash, 0, 0, false, false, false)
        : BookPolicy(
            hash,
            row.read<int>('revision'),
            row.read<int>('epoch'),
            row.read<int>('removed') == 1,
            row.read<int>('desktop') == 1,
            row.read<int>('phone') == 1,
            row.read<int>('reset_epoch'),
          );
  }

  Future<bool> _muted(String hash) async =>
      (await db
          .customSelect(
            'SELECT 1 AS yes FROM imported_mutes WHERE sha=?',
            variables: [Variable(hash)],
          )
          .getSingleOrNull()) !=
      null;

  Future<bool> allowed(String server, String hash, int epoch) async {
    final current = await policy(server, hash);
    if (current.blocked || current.epoch != epoch || await _muted(hash))
      return false;
    final pending = await db
        .customSelect(
          "SELECT 1 AS yes FROM imported_ops WHERE sha=? AND (server=? OR server='') AND action<>'resume' LIMIT 1",
          variables: [Variable(hash), Variable(server)],
        )
        .getSingleOrNull();
    return pending == null;
  }

  Future<void> _write(ImportedBook book) => db.customStatement(
    'INSERT INTO imported_books VALUES(?,?,?,?,?,?) ON CONFLICT(sha) DO UPDATE SET '
    'state=excluded.state,epoch=excluded.epoch,ready=excluded.ready,cover=excluded.cover,dirty=excluded.dirty',
    [
      book.hash,
      jsonEncode(book.state),
      book.epoch,
      book.ready ? 1 : 0,
      book.coverPath == null ? 0 : 1,
      book.dirty ? 1 : 0,
    ],
  );

  static Json validate(Json state) {
    final hash = state['sha256'],
        format = state['format'],
        size = state['size'];
    final title = state['title'],
        count = state['unitCount'],
        catalog = state['catalogHash'];
    final position = state['position'];
    if (hash is! String ||
        !isBookHash(hash) ||
        !bookFormats.contains(format) ||
        size is! int ||
        size <= 0 ||
        size > maxBookBytes ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 512 ||
        state['parserVersion'] != 1 ||
        count is! int ||
        count <= 0 ||
        count > maxUnits ||
        catalog is! String ||
        !isBookHash(catalog) ||
        state['comic'] is! bool ||
        state['comic'] == true && format != 'epub' ||
        state['favoriteChangedUtc'] != null &&
            DateTime.tryParse(state['favoriteChangedUtc'].toString()) == null ||
        state['favorite'] == true && state['favoriteChangedUtc'] == null ||
        position != null &&
            (position is! Json ||
                position['index'] is! int ||
                (position['index'] as int) < 0 ||
                (position['index'] as int) >= count ||
                position['progress'] is! num ||
                !(position['progress'] as num).isFinite ||
                (position['progress'] as num) < 0 ||
                (position['progress'] as num) > 1 ||
                state['comic'] == true && position['progress'] != 0)) {
      throw const FormatException('本地书书目或阅读位置无效');
    }
    return {...state, 'recent': false, 'recentChangedUtc': null};
  }

  static bool _sameCatalog(Json a, Json b) => const [
    'format',
    'size',
    'parserVersion',
    'catalogHash',
    'unitCount',
    'comic',
  ].every((key) => a[key] == b[key]);

  static Json merge(Json saved, Json incoming) {
    if (!_sameCatalog(saved, incoming)) throw const FormatException('章节目录不一致');
    final old = saved['position'] as Json?,
        next = incoming['position'] as Json?;
    final farther =
        next != null &&
        (old == null ||
            (next['index'] as int) > (old['index'] as int) ||
            next['index'] == old['index'] &&
                (next['progress'] as num) > (old['progress'] as num));
    final before = DateTime.tryParse(
      saved['favoriteChangedUtc']?.toString() ?? '',
    );
    final after = DateTime.tryParse(
      incoming['favoriteChangedUtc']?.toString() ?? '',
    );
    final newer =
        after != null &&
        (before == null ||
            after.isAfter(before) ||
            after.isAtSameMomentAs(before) &&
                saved['favorite'] == true &&
                incoming['favorite'] != true);
    return {
      ...saved,
      if (farther) 'position': next,
      if (newer) ...{
        'favorite': incoming['favorite'] == true,
        'favoriteChangedUtc': incoming['favoriteChangedUtc'],
      },
    };
  }

  Future<void> updatePosition(
    String hash,
    int epoch,
    int index,
    double progress, {
    Json? anchor,
  }) async {
    final changed = await db.transaction(() async {
      final old = await book(hash);
      if (old == null || old.epoch != epoch || !old.ready) return false;
      final merged = merge(old.state, {
        ...old.state,
        'position': {
          'index': index.clamp(0, old.unitCount - 1),
          'progress': old.comic ? 0 : progress.clamp(0, 1),
        },
      });
      final position = merged['position'] as Json;
      if (anchor != null &&
          position['index'] == index &&
          (old.comic || position['progress'] == progress)) {
        final saved = await readerAnchor(hash);
        if (saved?['chapterIndex'] != index ||
            (saved?['progress'] as num? ?? 0) <= progress) {
          await db.customStatement(
            'INSERT OR REPLACE INTO sync_meta(key,value) VALUES(?,?)',
            ['imported:anchor:$hash', jsonEncode(anchor)],
          );
        }
      }
      if (identical(merged['position'], old.state['position'])) return false;
      await _write(ImportedBook(merged, epoch, true, old.coverPath, true));
      return true;
    });
    if (changed) _changed(true);
  }

  Future<Json?> readerAnchor(String hash) async {
    final row = await db
        .customSelect(
          'SELECT value FROM sync_meta WHERE key=?',
          variables: [Variable('imported:anchor:$hash')],
        )
        .getSingleOrNull();
    return row == null ? null : jsonDecode(row.read<String>('value')) as Json;
  }

  Future<void> favorites(Iterable<String> hashes, bool active) async {
    var changed = false;
    await db.transaction(() async {
      for (final hash in hashes) {
        final old = await book(hash);
        if (old == null || old.favorite == active) continue;
        await _write(
          ImportedBook(
            {
              ...old.state,
              'favorite': active,
              'favoriteChangedUtc': DateTime.now().toUtc().toIso8601String(),
            },
            old.epoch,
            old.ready,
            old.coverPath,
            true,
          ),
        );
        changed = true;
      }
    });
    if (changed) _changed(true);
  }

  Future<void> _queue(
    String server,
    String hash,
    String action,
    int epoch,
  ) => db.customStatement(
    'INSERT INTO imported_ops(id,server,sha,action,epoch) VALUES(?,?,?,?,?)',
    [_id(), server, hash, action, epoch],
  );

  Future<List<BookOperation>> operations(String server) async =>
      (await db
              .customSelect(
                "SELECT * FROM imported_ops WHERE server=? OR server='' ORDER BY seq",
                variables: [Variable(server)],
              )
              .get())
          .map(
            (row) => BookOperation(
              row.read<int>('seq'),
              row.read<String>('id'),
              row.read<String>('sha'),
              row.read<String>('action'),
              row.read<int>('epoch'),
            ),
          )
          .toList();

  Future<void> acknowledge(BookOperation op) =>
      db.customStatement('DELETE FROM imported_ops WHERE seq=?', [op.order]);

  Future<void> remove(
    String hash, {
    required String? server,
    required bool both,
  }) => removeBooks([hash], server: server, both: both);

  Future<void> removeBooks(
    Iterable<String> hashes, {
    required String? server,
    required bool both,
  }) async {
    if (both && server == null) return;
    final removed = <String>[];
    await db.transaction(() async {
      for (final hash in hashes.toSet()) {
        final existing = await book(hash);
        if (existing == null) continue;
        final current = await policy(server ?? '', hash);
        if (both) {
          await db.customStatement('DELETE FROM imported_mutes WHERE sha=?', [
            hash,
          ]);
        } else {
          await db.customStatement(
            'INSERT OR IGNORE INTO imported_mutes VALUES(?)',
            [hash],
          );
        }
        await _queue(
          server ?? '',
          hash,
          both ? 'removeBoth' : 'removeHere',
          max(existing.epoch, current.epoch),
        );
        await _purge(hash);
        removed.add(hash);
      }
    });
    if (removed.isEmpty) return;
    for (final hash in removed) {
      _removed(localBookId(hash));
    }
    _changed(true);
  }

  Future<void> _purge(String hash) async {
    final id = localBookId(hash);
    await db.customStatement('DELETE FROM sync_meta WHERE key=?', [
      'imported:anchor:$hash',
    ]);
    await db.customStatement(
      'DELETE FROM local_reading_chapters WHERE book_key IN (SELECT book_key FROM local_reading_history WHERE book_id=?)',
      [id],
    );
    await db.customStatement(
      'DELETE FROM local_reading_history WHERE book_id=?',
      [id],
    );
    final pin = await db
        .customSelect(
          "SELECT value FROM sync_meta WHERE key='local:shelf-pins'",
        )
        .getSingleOrNull();
    if (pin != null) {
      final pins = jsonDecode(pin.read<String>('value')) as Map;
      if (pins.remove(id) != null) {
        await db.customStatement(
          "UPDATE sync_meta SET value=? WHERE key='local:shelf-pins'",
          [jsonEncode(pins)],
        );
      }
    }
    await db.customStatement('DELETE FROM imported_units WHERE sha=?', [hash]);
    await db.customStatement('DELETE FROM imported_books WHERE sha=?', [hash]);
    for (final format in bookFormats) {
      await _delete(File('${root.path}/$hash.$format'));
    }
    await _delete(_cover(hash));
    if (await root.exists()) {
      await for (final file in root.list()) {
        if (file is File &&
            file.path.endsWith('.part') &&
            file.path.contains('-$hash-')) {
          await _delete(file);
        }
      }
    }
  }

  Future<void> applyPolicy(String server, BookPolicy update) async {
    var changed = false, removed = false;
    await db.transaction(() async {
      final old = await policy(server, update.hash);
      if (update.revision <= old.revision) return;
      await db.customStatement(
        'INSERT OR REPLACE INTO imported_policies VALUES(?,?,?,?,?,?,?,?)',
        [
          server,
          update.hash,
          update.revision,
          update.epoch,
          update.removed ? 1 : 0,
          update.desktopExcluded ? 1 : 0,
          update.phoneExcluded ? 1 : 0,
          update.resetEpoch,
        ],
      );
      final existing = await book(update.hash);
      final resumed = await db
          .customSelect(
            "SELECT 1 AS yes FROM imported_ops WHERE sha=? AND server=? AND action='resume' AND epoch=? LIMIT 1",
            variables: [
              Variable(update.hash),
              Variable(server),
              Variable(update.epoch),
            ],
          )
          .getSingleOrNull();
      if (existing != null &&
          (existing.epoch < update.resetEpoch ||
              update.removed && resumed == null ||
              update.phoneExcluded && resumed == null)) {
        await _purge(update.hash);
        changed = removed = true;
      } else if (existing != null &&
          (existing.epoch < update.epoch ||
              old.blocked && !update.blocked && existing.ready)) {
        await _write(
          ImportedBook(
            existing.state,
            update.epoch,
            existing.ready,
            existing.coverPath,
            true,
          ),
        );
        changed = true;
      }
    });
    if (removed) _removed(localBookId(update.hash));
    if (changed) _changed(false);
  }

  Future<ImportedBook?> receive(String server, int epoch, Json incoming) async {
    final state = validate(incoming);
    final hash = state['sha256'] as String;
    var changed = false, advanced = false;
    final received = await db.transaction(() async {
      if (!await allowed(server, hash, epoch)) return null;
      final old = await book(hash);
      final merged = old == null ? state : merge(old.state, state);
      final result = ImportedBook(
        merged,
        epoch,
        old?.ready ?? false,
        old?.coverPath,
        old?.dirty ?? false,
      );
      if (old == null || jsonEncode(old.state) != jsonEncode(merged)) {
        await _write(result);
        changed = true;
        advanced =
            old != null &&
            old.ready &&
            old.epoch == epoch &&
            !identical(old.position, result.position);
      }
      return result;
    });
    if (changed) _changed(false);
    if (advanced) _remotePosition(received!);
    return received;
  }

  Future<void> clearDirty(ImportedBook sent) => db.customStatement(
    'UPDATE imported_books SET dirty=0 WHERE sha=? AND epoch=? AND state=?',
    [sent.hash, sent.epoch, jsonEncode(sent.state)],
  );

  Future<ImportedBook> importFile(
    File file,
    String name, {
    String? server,
  }) async {
    final dot = name.lastIndexOf('.');
    final format = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (!bookFormats.contains(format))
      throw const FormatException('仅支持 TXT、EPUB、MOBI');
    final size = await file.length();
    if (size <= 0 || size > maxBookBytes)
      throw const FormatException('文件为空或超过 200 MiB');
    final hash = (await sha256.bind(file.openRead()).first).toString();
    final already = await book(hash);
    if (already != null && already.ready && await original(already).exists())
      return already;
    final parsed = await parseBookFile(
      file.path,
      format,
      name.substring(0, dot),
    );
    final state = validate({
      'sha256': hash,
      'format': format,
      'size': size,
      'title': parsed.title,
      'parserVersion': 1,
      'catalogHash': parsed.catalogHash,
      'unitCount': parsed.units.length,
      'comic': parsed.comic,
    });
    final result = await db.transaction(() async {
      final current = await policy(server ?? '', hash);
      var epoch = current.epoch;
      final existing = await book(hash);
      if (existing != null) epoch = max(epoch, existing.epoch);
      final ops = (await operations(server ?? ''))
          .where((op) => op.hash == hash);
      for (final op in ops) {
        if (op.action == 'removeBoth') epoch = max(epoch, op.epoch + 1);
      }
      final needsResume =
          current.removed ||
          current.phoneExcluded ||
          await _muted(hash) ||
          ops.isNotEmpty;
      await db.customStatement('DELETE FROM imported_mutes WHERE sha=?', [
        hash,
      ]);
      if (needsResume && server != null)
        await _queue(server, hash, 'resume', epoch);
      if (server == null)
        await db.customStatement(
          "DELETE FROM imported_ops WHERE sha=? AND server=''",
          [hash],
        );
      final merged = existing == null ? state : merge(existing.state, state);
      return _install(
        file,
        parsed,
        ImportedBook(merged, epoch, true, null, true),
      );
    });
    _changed(true);
    return result;
  }

  Future<bool> installRemote(
    String server,
    ImportedBook expected,
    File file,
    ParsedBook parsed,
    List<String> titles,
  ) async {
    final installed = await db.transaction(() async {
      if (!await allowed(server, expected.hash, expected.epoch)) return false;
      final current = await book(expected.hash);
      if (current == null || current.epoch != expected.epoch) return false;
      if (current.ready) return true;
      if (parsed.catalogHash != current.catalogHash ||
          parsed.units.length != current.unitCount ||
          parsed.comic != current.comic ||
          titles.length != parsed.units.length) {
        throw const FormatException('原文件目录与同步目录不一致');
      }
      await _install(file, parsed, current, titles: titles);
      return true;
    });
    if (installed) _changed(false);
    return installed;
  }

  Future<ImportedBook> _install(
    File source,
    ParsedBook parsed,
    ImportedBook item, {
    List<String>? titles,
  }) async {
    await root.create(recursive: true);
    final dest = original(item);
    final staging = File('${dest.path}.${_id()}.tmp');
    try {
      await source.copy(staging.path);
      await staging.rename(dest.path);
      String? cover;
      if (parsed.cover != null) {
        cover = _cover(item.hash).path;
        await File(cover).writeAsBytes(parsed.cover!, flush: true);
      }
      await db.customStatement('DELETE FROM imported_units WHERE sha=?', [
        item.hash,
      ]);
      await db.batch((batch) {
        for (var i = 0; i < parsed.units.length; i++) {
          final unit = parsed.units[i];
          batch.customStatement(
            'INSERT INTO imported_units VALUES(?,?,?,?,?)',
            [
              item.hash,
              i,
              titles?[i] ?? unit.title,
              unit.address,
              jsonEncode(unit.blocks.map((block) => block.toJson()).toList()),
            ],
          );
        }
      });
      final result = ImportedBook(
        item.state,
        item.epoch,
        true,
        cover,
        item.dirty,
      );
      await _write(result);
      return result;
    } finally {
      await _delete(staging);
    }
  }

  static Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* Best-effort cleanup. */
    }
  }
}
