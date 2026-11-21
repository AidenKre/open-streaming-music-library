// Phase 7B.1a (SC-01 rule 6, 7-U01 fence): the per-page instance check sits
// in the shared write fence. `runFenced(token, body, servedBy: stamp)`
// compares the response's stamp with the bound `instance_id` inside the
// same Drift transaction, before the body runs:
//  * a different instance throws ServerInstanceChangedException and writes
//    nothing (the body never runs, so no rows, no cursor, no flag);
//  * no stamp (a pre-Phase-7 server) or a binding without a known instance
//    (legacy-unbound) is not checked;
//  * the comparison ignores case and surrounding whitespace (UUIDs);
//  * the fence still wins: a fenced token is BindingFencedException.
//  * the exception's text never carries either instance id.
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';

import '../helpers/server_binding.dart';

const _bound = '3f1c2a9e-7b4d-4e2a-9c1f-0a1b2c3d4e5f';
const _other = '9d8e7f6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a';

void main() {
  late AppDatabase db;
  late ServerBindingRepository repo;
  late SyncCursorStore cursors;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ServerBindingRepository(db);
    cursors = SyncCursorStore(db);
  });
  tearDown(() => db.close());

  Future<void> writeCursor() => cursors.write(SyncStream.catalog, 7);

  test('a page from a different instance writes nothing', () async {
    final token = await seedTestBinding(db, instanceId: _bound);
    var ran = false;

    await expectLater(
      repo.runFenced(token, () async {
        ran = true;
        await writeCursor();
      }, servedBy: _other),
      throwsA(isA<ServerInstanceChangedException>()
          .having((e) => e.boundInstanceId, 'bound', _bound)
          .having((e) => e.servedBy, 'servedBy', _other)),
    );

    expect(ran, isFalse);
    expect(await cursors.read(SyncStream.catalog), 0);
  });

  test('the check runs inside the transaction: a mismatch rolls back writes '
      'the body would make', () async {
    // Proven through the public seam: the stamp is compared before the body,
    // and the binding row is untouched by the attempt.
    final token = await seedTestBinding(db, instanceId: _bound, reconciled: true);

    await expectLater(
      repo.runFenced(token, () async {
        await writeCursor();
        await db.customUpdate(
          'UPDATE server_binding SET catalog_reconciled_at_binding = 0',
          updates: {db.serverBinding},
          updateKind: UpdateKind.update,
        );
      }, servedBy: _other),
      throwsA(isA<ServerInstanceChangedException>()),
    );

    final row = await repo.current();
    expect(row!.catalogReconciled, isTrue);
    expect(row.instanceId, _bound);
    expect(row.localBindingId, token);
    expect(await cursors.read(SyncStream.catalog), 0);
  });

  test('the same instance commits', () async {
    final token = await seedTestBinding(db, instanceId: _bound);

    await repo.runFenced(token, writeCursor, servedBy: _bound);

    expect(await cursors.read(SyncStream.catalog), 7);
  });

  test('case and surrounding whitespace do not make a mismatch', () async {
    final token = await seedTestBinding(db, instanceId: _bound);

    await repo.runFenced(token, writeCursor,
        servedBy: '  ${_bound.toUpperCase()}\t');

    expect(await cursors.read(SyncStream.catalog), 7);
  });

  test('no stamp (a pre-Phase-7 server) is not checked', () async {
    final token = await seedTestBinding(db, instanceId: _bound);

    await repo.runFenced(token, writeCursor, servedBy: null);
    await repo.runFenced(token, writeCursor); // the default: no stamp

    expect(await cursors.read(SyncStream.catalog), 7);
  });

  test('a binding without a known instance (legacy-unbound) is not checked',
      () async {
    final token = await seedTestBinding(db, instanceId: null);

    await repo.runFenced(token, writeCursor, servedBy: _other);

    expect(await cursors.read(SyncStream.catalog), 7);
    expect((await repo.current())!.instanceId, isNull,
        reason: 'a stamp never fills or rebinds the instance id');
  });

  test('the fence wins over the stamp: a fenced token is BindingFenced',
      () async {
    final token = await seedTestBinding(db, instanceId: _bound);
    await repo.rotate();

    await expectLater(
      repo.runFenced(token, writeCursor, servedBy: _other),
      throwsA(isA<BindingFencedException>()),
    );
  });

  test("the exception's text names neither instance id", () {
    final e = ServerInstanceChangedException(
      boundInstanceId: _bound,
      servedBy: _other,
    );
    expect(e.toString(), isNot(contains(_bound)));
    expect(e.toString(), isNot(contains(_other)));
  });
}
