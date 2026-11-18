// 7B.1d S2: the local upload intents (spec §7 para 2): every write asserts
// the SC-01 binding in-transaction (a late write after a reset or logout is
// a no-op), and every read is for one binding, so rows left by an earlier
// sign-in are never picked up for sending. Rows are asserted through raw
// SQL, independently of the store's read path.

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_uploads_api.dart' show itemJson;
import '../../helpers/server_binding.dart';

Future<List<Map<String, Object?>>> _rows(AppDatabase db) async => [
  for (final r in await db
      .customSelect(
        'SELECT item_uuid, batch_uuid, selection_index, display_name, '
        'source_descriptor_json, expected_sha256, expected_length, last_state, '
        'last_error_code, last_error_message, transfer_operation_uuid, '
        'local_binding_id, created_at, updated_at '
        'FROM upload_intents ORDER BY item_uuid',
      )
      .get())
    r.data,
];

NewUploadIntent _intent(String item, int index, {String batch = 'b-1'}) =>
    NewUploadIntent(
      itemUuid: item,
      batchUuid: batch,
      selectionIndex: index,
      displayName: '$item.flac',
      descriptor: UploadSourceDescriptor(
        path: '/music/$item.flac',
        length: 100 + index,
        sha256: 'ab' * 32,
      ),
    );

void main() {
  late AppDatabase db;
  late ServerBindingRepository binding;
  late FakeClock clock;
  late UploadIntentStore store;
  late String token;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    binding = ServerBindingRepository(db);
    clock = FakeClock(startUtcMs: 7000);
    token = await seedTestBinding(db, reconciled: true);
    store = UploadIntentStore(db: db, binding: binding, clock: clock);
  });
  tearDown(() => db.close());

  test('inserts a batch of intents under the binding, with the source '
      'descriptor in its three columns and the path never elsewhere',
      () async {
    await store.insertAll(token, [_intent('i-1', 0), _intent('i-2', 1)],
        state: UploadIntentState.allocating);

    final rows = await _rows(db);
    expect(rows, [
      {
        'item_uuid': 'i-1',
        'batch_uuid': 'b-1',
        'selection_index': 0,
        'display_name': 'i-1.flac',
        'source_descriptor_json': '{"v":1,"path":"/music/i-1.flac"}',
        'expected_sha256': 'ab' * 32,
        'expected_length': 100,
        'last_state': 'allocating',
        'last_error_code': null,
        'last_error_message': null,
        'transfer_operation_uuid': null,
        'local_binding_id': token,
        'created_at': 7000,
        'updated_at': 7000,
      },
      {
        'item_uuid': 'i-2',
        'batch_uuid': 'b-1',
        'selection_index': 1,
        'display_name': 'i-2.flac',
        'source_descriptor_json': '{"v":1,"path":"/music/i-2.flac"}',
        'expected_sha256': 'ab' * 32,
        'expected_length': 101,
        'last_state': 'allocating',
        'last_error_code': null,
        'last_error_message': null,
        'transfer_operation_uuid': null,
        'local_binding_id': token,
        'created_at': 7000,
        'updated_at': 7000,
      },
    ]);
  });

  test('a token from before a reset or a logout writes nothing', () async {
    await store.insertAll(token, [_intent('i-1', 0)],
        state: UploadIntentState.allocating);
    final before = await _rows(db);

    await binding.rotate(); // logout
    await expectLater(
      store.insertAll(token, [_intent('i-2', 0, batch: 'b-2')],
          state: UploadIntentState.allocating),
      throwsA(isA<BindingFencedException>()),
    );
    await expectLater(
      store.update(token, ['i-1'], lastState: const Value('allocated')),
      throwsA(isA<BindingFencedException>()),
    );
    expect(await _rows(db), before);
  });

  test('update writes only the given columns, under the binding, and moves '
      'updated_at', () async {
    await store.insertAll(token, [_intent('i-1', 0), _intent('i-2', 1)],
        state: UploadIntentState.allocating);
    clock.advance(const Duration(seconds: 2));

    await store.update(
      token,
      ['i-1'],
      lastState: const Value('allocated'),
      lastErrorCode: const Value('upload_slots_busy'),
      transferOperationUuid: const Value('t-1'),
    );

    final rows = await _rows(db);
    expect(rows[0]['last_state'], 'allocated');
    expect(rows[0]['last_error_code'], 'upload_slots_busy');
    expect(rows[0]['transfer_operation_uuid'], 't-1');
    expect(rows[0]['source_descriptor_json'],
        '{"v":1,"path":"/music/i-1.flac"}');
    expect(rows[0]['updated_at'], 9000);
    expect(rows[0]['created_at'], 7000);
    // The other row is untouched.
    expect(rows[1]['last_state'], 'allocating');
    expect(rows[1]['updated_at'], 7000);

    // Explicit null clears; absent keeps.
    await store.update(token, ['i-1'], lastErrorCode: const Value(null));
    final cleared = (await _rows(db))[0];
    expect(cleared['last_error_code'], isNull);
    expect(cleared['transfer_operation_uuid'], 't-1');
  });

  test('update of several items is one change', () async {
    await store.insertAll(token, [_intent('i-1', 0), _intent('i-2', 1)],
        state: UploadIntentState.allocating);
    await store.update(token, ['i-1', 'i-2'],
        lastState: const Value(UploadIntentState.rejected),
        lastErrorCode: const Value('upload_limit_exceeded'));
    expect([for (final r in await _rows(db)) r['last_state']],
        ['rejected', 'rejected']);
  });

  test('reads list only the binding\'s intents, in batch then selection '
      'order, with the descriptor read back', () async {
    await store.insertAll(token, [_intent('i-b', 1), _intent('i-a', 0)],
        state: UploadIntentState.allocating);
    clock.advance(const Duration(seconds: 1));
    await store.insertAll(token, [_intent('i-c', 0, batch: 'b-2')],
        state: UploadIntentState.allocating);
    // A row left by an earlier sign-in (raw insert under another token).
    await db.customStatement(
      "INSERT INTO upload_intents (item_uuid, batch_uuid, selection_index, "
      "display_name, last_state, local_binding_id, created_at, updated_at) "
      "VALUES ('old', 'b-0', 0, 'old.flac', 'allocated', 'old-token', 1, 1)",
    );

    final intents = await store.forBinding(token);
    expect([for (final i in intents) i.itemUuid], ['i-a', 'i-b', 'i-c']);
    final first = intents.first;
    expect(first.batchUuid, 'b-1');
    expect(first.displayName, 'i-a.flac');
    expect(first.lastState, 'allocating');
    expect(first.descriptor?.path, '/music/i-a.flac');
    expect(first.descriptor?.length, 100);
    expect(first.descriptor?.sha256, 'ab' * 32);

    expect(await store.countOtherBindings(token), 1);
  });

  test('a row whose descriptor is missing reads back with a null '
      'descriptor (the source must be reselected)', () async {
    await store.insertAll(token, [_intent('i-1', 0)],
        state: UploadIntentState.allocated);
    await store.update(token, ['i-1'],
        sourceDescriptorJson: const Value(null));
    expect((await store.forBinding(token)).single.descriptor, isNull);
  });

  test('watch emits the binding\'s intents on every write', () async {
    final seen = <List<String>>[];
    final sub = store.watch(token).listen(
          (intents) => seen.add([for (final i in intents) i.lastState]),
        );
    addTearDown(sub.cancel);
    await pumpEventQueue();
    await store.insertAll(token, [_intent('i-1', 0)],
        state: UploadIntentState.allocating);
    await pumpEventQueue();
    await store.update(token, ['i-1'],
        lastState: const Value(UploadIntentState.allocated));
    await pumpEventQueue();

    expect(seen, [
      <String>[],
      ['allocating'],
      ['allocated'],
    ]);
  });

  // 7-R2-02: a row of an earlier sign-in (a rotated binding) is dead. When
  // the current binding's server listing names its item, the item is adopted
  // for the current binding afresh, never re-bound: nothing the dead row held
  // is kept.
  group('7-R2-02 a listed item with a row of an earlier sign-in', () {
    UploadItem listed(String uuid,
            {String state = 'review_ready', String? parent, String batch = 'b-1'}) =>
        UploadItem.fromJson({
          ...itemJson(uuid,
              batchUuid: batch, state: state, filename: '$uuid.flac'),
          'parent_item_uuid': parent,
        });

    Future<Map<String, Object?>> rowOf(String uuid) async => (await db
            .customSelect(
              'SELECT * FROM upload_intents WHERE item_uuid = ?',
              variables: [Variable.withString(uuid)],
            )
            .getSingle())
        .data;

    Future<String> signOutAndIn() async =>
        (await binding.rotate())!.localBindingId;

    test('top-level: adopted under the current binding, sourceless, with no '
        'digest, operations or draft', () async {
      await store.insertAll(token, [_intent('i-1', 0)],
          state: UploadIntentState.transferring);
      await store.update(token, ['i-1'],
          lastState: const Value('review_ready'),
          operationUuid: const Value('op-1'),
          transferOperationUuid: const Value('t-1'),
          reviewGeneration: const Value(1),
          draftJson: const Value('{"title":"Mine"}'));
      final current = await signOutAndIn();

      await store.adoptListedItems(current, [listed('i-1')]);

      final r = await rowOf('i-1');
      expect(r['local_binding_id'], current);
      expect(r['last_state'], 'review_ready');
      expect(r['source_descriptor_json'], isNull);
      expect(r['expected_sha256'], isNull);
      expect(r['operation_uuid'], isNull);
      expect(r['transfer_operation_uuid'], isNull);
      expect(r['review_generation'], isNull);
      expect(r['draft_json'], isNull);
      expect([for (final i in await store.forBinding(current)) i.itemUuid],
          ['i-1']);
    });

    test('a ZIP child of an adopted archive, through either adoption path',
        () async {
      await store.insertAll(token, [_intent('zip', 0)],
          state: UploadIntentState.allocated);
      await store.adoptChildren(token, [
        listed('c-1', parent: 'zip'),
        listed('c-2', parent: 'zip'),
      ]);
      final current = await signOutAndIn();

      await store.adoptListedItems(current, [
        listed('zip', state: 'expanded'),
        listed('c-1', parent: 'zip'),
      ]);
      await store.adoptListedChildren(current, [listed('c-2', parent: 'zip')]);

      for (final uuid in ['zip', 'c-1', 'c-2']) {
        final r = await rowOf(uuid);
        expect(r['local_binding_id'], current, reason: uuid);
        expect(r['source_descriptor_json'], isNull, reason: uuid);
        expect(r['expected_sha256'], isNull, reason: uuid);
      }
      expect((await rowOf('c-2'))['parent_item_uuid'], 'zip');
    });

    test('a row of the current binding is never replaced', () async {
      await store.insertAll(token, [_intent('i-1', 0)],
          state: 'review_ready');
      final before = await rowOf('i-1');

      await store.adoptListedItems(token, [listed('i-1', state: 'failed')]);

      expect(await rowOf('i-1'), before);
    });

    test('a dead row the listing does not name stays dead: never shown',
        () async {
      await store.insertAll(token, [_intent('i-1', 0), _intent('i-2', 1)],
          state: 'review_ready');
      final current = await signOutAndIn();

      await store.adoptListedItems(current, [listed('i-1')]);

      expect([for (final i in await store.forBinding(current)) i.itemUuid],
          ['i-1']);
      expect((await rowOf('i-2'))['local_binding_id'], token);
    });
  });
}
