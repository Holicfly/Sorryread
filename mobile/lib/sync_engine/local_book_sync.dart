import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show MissingPluginException;

import '../data/imported_books.dart';
import '../data/sync_repository.dart';
import '../features/local_books/local_book_parser.dart';
import 'sync_model.dart';
import 'sync_transport.dart';

const _chunkSize = 1024 * 1024;
String localBookCursorKey(String server) => 'imported:revision:$server';

class LocalBookSync {
  LocalBookSync(
    this.repo,
    this.store,
    this.transport,
    this.peer,
    this.cancel,
    this.alive,
  );
  final SyncRepository repo;
  final ImportedBooks store;
  final SyncTransport transport;
  final LinkedPeer peer;
  final CancelToken cancel;
  final Future<void> Function() alive;
  String get server => peer.serverId;

  Future<(int, int)> run() async {
    for (final op in await store.operations(server)) {
      await alive();
      final path = '/v1/local-books/${op.hash}/policy';
      var answer = await transport.post(path, op.toJson(), cancel);
      if (answer['applied'] != true && op.action == 'removeHere') {
        final current = BookPolicy.fromJson(answer['policy'] as Json);
        answer = await transport.post(path, {
          ...op.toJson(),
          'epoch': current.epoch,
        }, cancel);
      }
      await alive();
      await store.applyPolicy(
        server,
        BookPolicy.fromJson(answer['policy'] as Json),
      );
      if (answer['applied'] != true && op.action == 'removeHere') continue;
      await store.acknowledge(op);
    }

    final key = localBookCursorKey(server);
    var after = await repo.meta(key) ?? '0';
    while (true) {
      await alive();
      final page = await transport.get(
        '/v1/local-books?after=$after&lifecycle=true',
        cancel,
      );
      final policies = page['policies'] as List, books = page['books'] as List;
      final next = page['nextRevision'] as String;
      if (policies.length + books.length > 128 ||
          sequence(next) < sequence(after) ||
          page['more'] == true && next == after) {
        throw const FormatException('本地书同步分页无效');
      }
      await alive();
      await repo.db.transaction(() async {
        for (final row in policies) {
          await store.applyPolicy(server, BookPolicy.fromJson(row as Json));
        }
        for (final row in books.cast<Json>()) {
          final state = ImportedBooks.validate(row['state'] as Json);
          final policy = await store.policy(server, state['sha256'] as String);
          try {
            await store.receive(server, policy.epoch, state);
          } on FormatException catch (error) {
            await repo.log(
              false,
              '《${state['title']}》目录校验失败 · ${error.message}',
            );
          }
        }
        await repo.setMeta(key, next);
      });
      after = next;
      if (page['more'] != true) break;
    }

    var uploaded = 0, downloaded = 0;
    for (final book in await store.books()) {
      await alive();
      if (!await store.allowed(server, book.hash, book.epoch)) continue;
      try {
        if (book.ready) {
          if (book.dirty && await _upload(book)) uploaded++;
        } else if (await _download(book)) {
          downloaded++;
        }
      } on DioException catch (error) {
        if (error.response?.statusCode == 404) continue;
        final response = error.response?.data;
        if (error.response?.statusCode == 409 &&
            response is Map &&
            response['code'] == 'book_excluded') {
          await alive();
          await store.applyPolicy(
            server,
            BookPolicy.fromJson(response['policy'] as Json),
          );
          continue;
        }
        if (error.response?.statusCode == 422 ||
            error.response?.statusCode == 409) {
          await repo.log(false, '《${book.title}》原文件或目录校验失败');
          continue;
        }
        rethrow;
      } on FormatException catch (error) {
        await repo.log(false, '《${book.title}》同步失败 · ${error.message}');
      } on MissingPluginException {
        // The background engine has no activity codec. Keep the completed part for foreground import.
      }
    }
    return (uploaded, downloaded);
  }

  String _route(ImportedBook book, String action, [String query = '']) =>
      '/v1/local-books/${book.hash}/$action?epoch=${book.epoch}$query';

  Future<Json> _put(String path, List<int> bytes, String type) async {
    final result = await transport.dio.put<dynamic>(
      path,
      data: Stream<List<int>>.value(bytes),
      cancelToken: cancel,
      options: Options(
        contentType: type,
        headers: {Headers.contentLengthHeader: bytes.length},
      ),
    );
    return result.data as Json;
  }

  Future<bool> _upload(ImportedBook book) async {
    final file = store.original(book);
    if (!await file.exists() || await file.length() != book.size) return false;
    final answer = await _put(
      _route(book, 'state'),
      utf8.encode(jsonEncode(book.state)),
      Headers.jsonContentType,
    );
    await alive();
    await store.receive(server, book.epoch, answer['state'] as Json);
    if (answer['hasFile'] == true) {
      await store.clearDirty(book);
      return true;
    }
    final status = await transport.get(_route(book, 'upload'), cancel);
    var offset = status['offset'] as int;
    if (offset < 0 || offset > book.size)
      throw const FormatException('电脑返回的上传偏移无效');
    final reader = await file.open();
    try {
      while (offset < book.size) {
        await alive();
        if (!await store.allowed(server, book.hash, book.epoch)) return false;
        await reader.setPosition(offset);
        final chunk = await reader.read(_chunkSize);
        if (chunk.isEmpty) throw const FormatException('原文件长度已改变');
        try {
          final next = await _put(
            _route(book, 'upload', '&offset=$offset'),
            chunk,
            'application/octet-stream',
          );
          if (next['offset'] != offset + chunk.length &&
              next['hasFile'] != true) {
            throw const FormatException('电脑确认的上传偏移无效');
          }
          offset = next['offset'] as int;
        } on DioException catch (error) {
          final body = error.response?.data;
          final actual = body is Map ? body['offset'] : null;
          if (error.response?.statusCode != 409 ||
              actual is! int ||
              actual <= offset ||
              actual > book.size) {
            rethrow;
          }
          offset = actual;
        }
      }
      await alive();
      if (!await store.allowed(server, book.hash, book.epoch)) return false;
      final finished = await transport.post(_route(book, 'finish'), {}, cancel);
      if (finished['hasFile'] != true) throw const FormatException('电脑尚未确认原文件');
      await alive();
      await store.receive(server, book.epoch, finished['state'] as Json);
      await store.clearDirty(book);
      return true;
    } finally {
      await reader.close();
    }
  }

  Future<bool> _download(ImportedBook book) async {
    final status = await transport.get(_route(book, 'state'), cancel);
    if (status['hasFile'] != true) return false;
    await store.root.create(recursive: true);
    final part = store.partial(server, book.hash, book.epoch);
    var offset = await part.exists() ? await part.length() : 0;
    if (offset > book.size) {
      await part.delete();
      offset = 0;
    }
    if (offset < book.size) {
      final response = await transport.dio.get<ResponseBody>(
        _route(book, 'file'),
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          headers: {if (offset > 0) 'Range': 'bytes=$offset-'},
        ),
      );
      final expectedRange = 'bytes $offset-${book.size - 1}/${book.size}';
      if (response.statusCode == 206 &&
              response.headers.value('content-range') != expectedRange ||
          response.statusCode != 206 && response.statusCode != 200) {
        await response.data!.stream.listen((_) {}).cancel();
        throw const FormatException('电脑返回的下载范围无效');
      }
      final output = await part.open(
        mode: response.statusCode == 206 ? FileMode.append : FileMode.write,
      );
      var written = response.statusCode == 206 ? offset : 0,
          nextCheck = written;
      try {
        await for (final bytes in response.data!.stream) {
          if (written >= nextCheck) {
            await alive();
            if (!await store.allowed(server, book.hash, book.epoch))
              return false;
            nextCheck = written + _chunkSize;
          }
          written += bytes.length;
          if (written > book.size) throw const FormatException('同步原文件超过声明大小');
          await output.writeFrom(bytes);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (written != book.size) return false;
    }
    if (!await store.allowed(server, book.hash, book.epoch)) return false;
    if ((await sha256.bind(part.openRead()).first).toString() != book.hash) {
      await part.delete();
      throw const FormatException('原文件 SHA-256 校验失败');
    }
    final parsed = await parseBookFile(part.path, book.format, book.title);
    final titles = <String>[];
    while (titles.length < book.unitCount) {
      await alive();
      final page = await transport.get(
        _route(book, 'catalog', '&after=${titles.length - 1}'),
        cancel,
      );
      final units = page['units'] as List;
      if (units.isEmpty ||
          units.length > 128 ||
          titles.length + units.length > parsed.units.length) {
        throw const FormatException('同步目录分页无效');
      }
      for (final row in units.cast<Json>()) {
        final index = titles.length;
        if (row['index'] != index ||
            row['address'] != parsed.units[index].address) {
          throw const FormatException('两端章节或页码目录不一致');
        }
        titles.add(
          bookTitle(row['title'] as String, parsed.units[index].title),
        );
      }
    }
    final saved = await store.installRemote(server, book, part, parsed, titles);
    if (await part.exists()) await part.delete();
    return saved;
  }
}
