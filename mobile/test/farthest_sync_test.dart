
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/sync_engine/sync_model.dart';

import 'support/test_runtime.dart';

void main() {
  test('offline 40 beats later 31; reread, dominated history and replacement snapshot retain 40', () async {
    final phone = await testRepository(books: 1);
    final replacement = await testRepository();
    addTearDown(phone.close);
    addTearDown(replacement.close);
    final book = (await phone.books()).single;
    await phone.localChange(book.id, 'position', {
      ...book.metadata,
      'progress': .4,
    });
    final phoneSeq = await phone.meta('seq');
    final advances = <SyncChange>[];
    final sub = phone.remotePositionAdvances.stream.listen(advances.add);
    addTearDown(sub.cancel);
    const desktop = '22222222222222222222222222222222';
    SyncChange update(String seq, double progress, Map<String, String> clock) =>
        SyncChange(
          entityId: book.id,
          group: 'position',
          origin: desktop,
          seq: seq,
          clock: clock,
          payload: {
            ...book.metadata,
            'progress': progress,
            'updatedUtc': '2030-01-01T00:00:00Z',
          },
        );
    await phone.applyRemote(desktop, [
      update('1', .31, {desktop: '1'}),
    ]);
    expect(
      (await phone.record(book.id, 'position'))!.effective.payload['progress'],
      .4,
    );
    await phone.applyRemote(desktop, [
      update('2', .32, {
        desktop: '2',
        phone.deviceId: phoneSeq!,
        '11111111111111111111111111111111': '2',
      }),
    ]);
    await phone.localChange(book.id, 'position', {
      ...book.metadata,
      'progress': .1,
    });
    expect(await phone.meta('seq'), phoneSeq);
    final (_, state) = await phone.exportSnapshot();
    await replacement.applySnapshot(phone.deviceId, int.parse(phoneSeq), state);
    await replacement.applySnapshot(phone.deviceId, int.parse(phoneSeq), state);
    final restored = (await replacement.record(book.id, 'position'))!;
    expect(restored.effective.payload['progress'], .4);
    expect(restored.hasPositionConflict, false);
    expect(await replacement.meta('seq'), '0');
    await Future<void>.delayed(Duration.zero);
    expect(advances, isEmpty);
    await phone.applyRemote(desktop, [
      update('3', .6, {desktop: '3'}),
    ]);
    await phone.applyRemote(desktop, [
      update('3', .6, {desktop: '3'}),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(advances.map((v) => v.payload['progress']), [.6]);
    expect(await phone.meta('seq'), phoneSeq);
  });
}
