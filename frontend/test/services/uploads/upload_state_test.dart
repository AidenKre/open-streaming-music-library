// 7B.1d S15: the state the Uploads page (7B.2b) observes (SC-26: views
// observe model state). The scope's upload intents as a stream for the
// current binding (rows of an earlier sign-in are not shown as pending
// work), and a file held back by a busy server reads as "waiting for the
// server", never as an error (O13 / DEV-7-02).
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/uploads/upload_manager.dart';

import '../../helpers/server_binding.dart';

Future<void> _insert(AppDatabase db, String item, String state,
        {required String token, String? error}) =>
    db.into(db.uploadIntents).insert(
      UploadIntentsCompanion.insert(
        itemUuid: item,
        batchUuid: 'b',
        selectionIndex: 0,
        displayName: '$item.flac',
        lastState: state,
        lastErrorCode: Value(error),
        localBindingId: token,
        createdAt: 1,
        updatedAt: 1,
      ),
    );

void main() {
  late AppDatabase db;
  late ProviderContainer c;
  late String token;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db, reconciled: true);
    c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
  });
  tearDown(() async {
    c.dispose();
    await db.close();
  });

  test('the intents of this binding, following writes', () async {
    await _insert(db, 'a', 'allocated', token: token);
    await _insert(db, 'old', 'allocated', token: 'earlier-token');
    final seen = <List<String>>[];
    final sub = c.listen(uploadIntentsProvider, (_, next) {
      final v = next.value;
      if (v != null) seen.add([for (final i in v) i.itemUuid]);
    }, fireImmediately: true);
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(seen.last, ['a']);

    await _insert(db, 'b', 'allocating', token: token);
    await pumpEventQueue();
    expect(seen.last, ['a', 'b']);
  });

  test('a busy server reads as waiting for the server, not as an error',
      () async {
    await _insert(db, 'busy', 'allocated',
        token: token, error: 'upload_slots_busy');
    await _insert(db, 'full', 'allocated',
        token: token, error: 'insufficient_storage');
    await _insert(db, 'plain', 'allocated', token: token);
    final store = c.read(uploadIntentStoreProvider);
    final byItem = {
      for (final i in await store.forBinding(token)) i.itemUuid: i,
    };
    expect(byItem['busy']!.waitingForServer, isTrue);
    expect(byItem['full']!.waitingForServer, isFalse);
    expect(byItem['plain']!.waitingForServer, isFalse);
  });
}
