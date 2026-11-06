import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/sync_repository.dart';

Future<SyncRepository> openSyncRepository() async {
  final directory = await getApplicationSupportDirectory();
  final repo = SyncRepository(
    SyncDatabase(
      NativeDatabase.createInBackground(File('${directory.path}/reader.db')),
    ),
    bookDirectory: Directory('${directory.path}/local-books'),
  );
  await repo.initialize();
  return repo;
}

final syncRepositoryProvider = FutureProvider<SyncRepository>((ref) async {
  final repo = await openSyncRepository();
  ref.onDispose(repo.close);
  return repo;
});

final shelfBooksProvider = StreamProvider<List<ShelfBook>>((ref) async* {
  final repo = await ref.watch(syncRepositoryProvider.future);
  yield* repo.watchBooks();
});
