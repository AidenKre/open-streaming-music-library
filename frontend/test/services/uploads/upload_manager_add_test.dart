// 7B.1d S3: adding files (spec §7 para 2; 7B.1c handover). Every selected
// file is hashed by streaming; a zero-byte file is left out before the
// allocation (the server refuses the whole batch for one), as is a file
// over a known `max_file_bytes`; selections are split into batches by the
// known count and byte limits. Each batch's intents are written
// `allocating` and its allocation request is frozen in a durable
// submission (operation id = batch UUID) before anything is sent. The gate
// here never verifies, so nothing is sent: the persisted state is what is
// asserted.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_uploads_api.dart';
import '../../helpers/server_binding.dart';

// Independent fixtures: SHA-256 of "abc" and "abcd".
const _shaAbc =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _shaAbcd =
    '88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589';

Future<List<Map<String, Object?>>> _intents(AppDatabase db) async => [
  for (final r in await db
      .customSelect(
        'SELECT item_uuid, batch_uuid, selection_index, display_name, '
        'expected_sha256, expected_length, last_state, local_binding_id '
        'FROM upload_intents ORDER BY batch_uuid, selection_index',
      )
      .get())
    r.data,
];

Future<List<Map<String, Object?>>> _submissions(AppDatabase db) async => [
  for (final r in await db
      .customSelect(
        'SELECT operation_uuid, kind, frozen_body_json, state, '
        'local_binding_id FROM durable_submissions ORDER BY operation_uuid',
      )
      .get())
    r.data,
];

void main() {
  late Directory dir;
  late AppDatabase db;
  late ServerBindingRepository binding;
  late FakeClock clock;
  late ControlledGate gate;
  late FakeUploadsApi api;
  late String token;
  late UploadManager manager;
  AdvertisedFeature<UploadsFeature>? feature;

  Future<FileUploadSource> file(String name, List<int> bytes) async {
    final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return FileUploadSource.open(f.path);
  }

  UploadManager build() {
    var n = 0;
    return UploadManager(
      api: api,
      submissions: DurableSubmission(db: db, binding: binding, clock: clock),
      intents: UploadIntentStore(db: db, binding: binding, clock: clock),
      binding: binding,
      gate: gate.gate,
      clock: clock,
      feature: () async => feature,
      isOffline: () => false,
      newUuid: () => 'u-${++n}',
    );
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('osml_7b1d_add');
    db = AppDatabase(NativeDatabase.memory());
    binding = ServerBindingRepository(db);
    clock = FakeClock(startUtcMs: 9000);
    token = await seedTestBinding(db, reconciled: true);
    gate = ControlledGate(db); // never verified: nothing is sent
    api = FakeUploadsApi(gate: gate.gate);
    feature = const AdvertisedFeature(
      UploadsFeature(version: 1),
      fromCache: false,
    );
    manager = build();
  });

  tearDown(() async {
    await manager.quiesce();
    gate.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  test('two files make one batch: intents allocating with their digests, '
      'and the allocation frozen under the batch id before any send',
      () async {
    final a = await file('a.flac', 'abc'.codeUnits);
    final b = await file('b.mp3', 'abcd'.codeUnits);

    final result = await manager.addFiles([a, b]);

    expect(result.batchUuids, ['u-1']);
    expect(result.leftOut, isEmpty);
    expect(await _intents(db), [
      {
        'item_uuid': 'u-2',
        'batch_uuid': 'u-1',
        'selection_index': 0,
        'display_name': 'a.flac',
        'expected_sha256': _shaAbc,
        'expected_length': 3,
        'last_state': 'allocating',
        'local_binding_id': token,
      },
      {
        'item_uuid': 'u-3',
        'batch_uuid': 'u-1',
        'selection_index': 1,
        'display_name': 'b.mp3',
        'expected_sha256': _shaAbcd,
        'expected_length': 4,
        'last_state': 'allocating',
        'local_binding_id': token,
      },
    ]);
    expect(await _submissions(db), [
      {
        'operation_uuid': 'u-1',
        'kind': 'upload_allocation',
        'frozen_body_json':
            '{"batch_uuid":"u-1","items":['
            '{"item_uuid":"u-2","filename":"a.flac","byte_length":3,'
            '"sha256":"$_shaAbc"},'
            '{"item_uuid":"u-3","filename":"b.mp3","byte_length":4,'
            '"sha256":"$_shaAbcd"}]}',
        'state': 'prepared',
        'local_binding_id': token,
      },
    ]);
    expect(api.calls, isEmpty);
  });

  test('a zero-byte file is left out with its reason; the rest is '
      'allocated', () async {
    final empty = await file('empty.flac', const []);
    final a = await file('a.flac', 'abc'.codeUnits);

    final result = await manager.addFiles([empty, a]);

    expect([for (final l in result.leftOut) (l.displayName, l.reason)], [
      ('empty.flac', LeftOutReason.empty),
    ]);
    expect([for (final r in await _intents(db)) r['display_name']],
        ['a.flac']);
  });

  test('only zero-byte files: nothing is written', () async {
    final empty = await file('empty.flac', const []);
    final result = await manager.addFiles([empty]);
    expect(result.batchUuids, isEmpty);
    expect(result.leftOut.single.reason, LeftOutReason.empty);
    expect(await _intents(db), isEmpty);
    expect(await _submissions(db), isEmpty);
  });

  test('a file over a known max_file_bytes is left out as too large; an '
      'unknown limit leaves the decision to the server', () async {
    feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(maxFileBytes: 3)),
      fromCache: false,
    );
    final a = await file('a.flac', 'abc'.codeUnits);
    final big = await file('big.flac', 'abcd'.codeUnits);

    final result = await manager.addFiles([a, big]);
    expect([for (final l in result.leftOut) (l.displayName, l.reason)], [
      ('big.flac', LeftOutReason.tooLarge),
    ]);
    expect([for (final r in await _intents(db)) r['display_name']],
        ['a.flac']);

    feature = const AdvertisedFeature(
      UploadsFeature(version: 1),
      fromCache: false,
    );
    final again = await manager.addFiles([big]);
    expect(again.leftOut, isEmpty);
    expect(again.batchUuids, hasLength(1));
  });

  test('a known max_files_per_batch splits the selection in order',
      () async {
    feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(maxFilesPerBatch: 2)),
      fromCache: false,
    );
    final files = [
      for (final n in ['a', 'b', 'c']) await file('$n.flac', 'abc'.codeUnits),
    ];

    final result = await manager.addFiles(files);

    expect(result.batchUuids, hasLength(2));
    final rows = await _intents(db);
    final byBatch = <Object?, List<Object?>>{};
    for (final r in rows) {
      byBatch.putIfAbsent(r['batch_uuid'], () => []).add(r['display_name']);
    }
    expect(byBatch[result.batchUuids[0]], ['a.flac', 'b.flac']);
    expect(byBatch[result.batchUuids[1]], ['c.flac']);
    expect([for (final s in await _submissions(db)) s['operation_uuid']]
      ..sort(), [...result.batchUuids]..sort());
  });

  test('a known max_batch_bytes splits the selection so no batch exceeds '
      'it', () async {
    feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(maxBatchBytes: 7)),
      fromCache: false,
    );
    final a = await file('a.flac', 'abc'.codeUnits); // 3
    final b = await file('b.flac', 'abcd'.codeUnits); // 4
    final c = await file('c.flac', 'abc'.codeUnits); // 3

    final result = await manager.addFiles([a, b, c]);

    expect(result.batchUuids, hasLength(2));
    final rows = await _intents(db);
    expect(
      [for (final r in rows) if (r['batch_uuid'] == result.batchUuids[0])
        r['display_name']],
      ['a.flac', 'b.flac'],
    );
    expect(
      [for (final r in rows) if (r['batch_uuid'] == result.batchUuids[1])
        r['display_name']],
      ['c.flac'],
    );
  });

  test('a file that can no longer be read is left out as unreadable',
      () async {
    final gone = await file('gone.flac', 'abc'.codeUnits);
    File(gone.path).deleteSync();
    final a = await file('a.flac', 'abcd'.codeUnits);

    final result = await manager.addFiles([gone, a]);

    expect([for (final l in result.leftOut) (l.displayName, l.reason)], [
      ('gone.flac', LeftOutReason.unreadable),
    ]);
    expect([for (final r in await _intents(db)) r['display_name']],
        ['a.flac']);
  });

  test('without the uploads block nothing is hashed or written', () async {
    feature = null;
    final a = await file('a.flac', 'abc'.codeUnits);
    await expectLater(
      manager.addFiles([a]),
      throwsA(isA<UploadsUnavailable>()),
    );
    expect(await _intents(db), isEmpty);
    expect(await _submissions(db), isEmpty);
  });

  test('a block read from the cache may record the selection (nothing is '
      'sent from it)', () async {
    feature = const AdvertisedFeature(
      UploadsFeature(version: 1),
      fromCache: true,
    );
    final a = await file('a.flac', 'abc'.codeUnits);
    final result = await manager.addFiles([a]);
    expect(result.batchUuids, hasLength(1));
    expect(api.calls, isEmpty);
  });

  test('after a reset (no binding row) nothing is written', () async {
    await binding.fence();
    final a = await file('a.flac', 'abc'.codeUnits);
    await expectLater(
      manager.addFiles([a]),
      throwsA(isA<UploadsUnavailable>()),
    );
    expect(await _intents(db), isEmpty);
  });
}
