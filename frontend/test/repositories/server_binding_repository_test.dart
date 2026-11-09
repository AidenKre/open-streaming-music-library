// SC-01: the local server binding row and the durable write fence.
//
// One row whenever a session URL exists: instance_id NULL until verified
// (provisional/legacy), a local_binding_id minted when the row is created,
// last_base_url, bound_at, catalog_reconciled_at_binding. Writers capture
// local_binding_id when their task starts; their transaction asserts the row
// still carries it, so a write that outlives a reset (row deleted) or a
// re-bind (new row, new id) is a no-op.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

void main() {
  late AppDatabase db;
  late ServerBindingRepository repo;
  var ids = 0;
  var now = 1000;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ids = 0;
    now = 1000;
    repo = ServerBindingRepository(
      db,
      newBindingId: () => 'binding-${++ids}',
      nowMs: () => now,
    );
  });

  tearDown(() => db.close());

  Future<List<Map<String, Object?>>> rows() async => [
    for (final r in await db.customSelect('SELECT * FROM server_binding').get())
      r.data,
  ];

  group('ensureProvisional', () {
    test('creates the single provisional row', () async {
      final b = await repo.ensureProvisional('http://a:8000');
      expect(b.instanceId, isNull);
      expect(b.localBindingId, 'binding-1');
      expect(b.lastBaseUrl, 'http://a:8000');
      expect(b.boundAtMs, 1000);
      expect(b.catalogReconciled, isFalse);
      expect(await rows(), hasLength(1));
    });

    test('returns an existing row unchanged (no new token, URL kept)', () async {
      await repo.ensureProvisional('http://a:8000');
      now = 2000;
      final again = await repo.ensureProvisional('http://other:9');
      expect(again.localBindingId, 'binding-1');
      expect(again.lastBaseUrl, 'http://a:8000');
      expect(again.boundAtMs, 1000);
      expect(await rows(), hasLength(1));
    });

    test('the default token is a random UUID v4', () async {
      final real = ServerBindingRepository(db);
      final b = await real.ensureProvisional('http://a');
      expect(
        b.localBindingId,
        matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        )),
      );
    });
  });

  test('the table can never hold a second row', () async {
    await repo.ensureProvisional('http://a');
    await expectLater(
      db.customStatement(
        'INSERT INTO server_binding (id, local_binding_id, last_base_url, bound_at) '
        "VALUES (2, 'x', 'u', 1)",
      ),
      throwsA(anything),
    );
  });

  group('recordVerified', () {
    test('fills a NULL instance id in place, keeping the token', () async {
      final b = await repo.ensureProvisional('http://a');
      await repo.recordVerified(
        b.localBindingId,
        instanceId: 'inst-1',
        baseUrl: 'http://a',
      );
      final after = (await repo.current())!;
      expect(after.instanceId, 'inst-1');
      expect(after.localBindingId, b.localBindingId);
    });

    test('same instance at a new URL only updates last_base_url', () async {
      final b = await repo.ensureProvisional('http://a');
      await repo.recordVerified(b.localBindingId, instanceId: 'inst-1', baseUrl: 'http://a');
      await repo.recordVerified(b.localBindingId, instanceId: 'inst-1', baseUrl: 'http://alias:1');
      final after = (await repo.current())!;
      expect(after.instanceId, 'inst-1');
      expect(after.lastBaseUrl, 'http://alias:1');
      expect(after.localBindingId, b.localBindingId);
    });

    test('a legacy server (no instance id) keeps the row NULL', () async {
      final b = await repo.ensureProvisional('http://a');
      await repo.recordVerified(b.localBindingId, instanceId: null, baseUrl: 'http://a');
      expect((await repo.current())!.instanceId, isNull);
    });

    test('refuses to overwrite a different known instance id', () async {
      final b = await repo.ensureProvisional('http://a');
      await repo.recordVerified(b.localBindingId, instanceId: 'inst-1', baseUrl: 'http://a');
      await expectLater(
        repo.recordVerified(b.localBindingId, instanceId: 'inst-2', baseUrl: 'http://a'),
        throwsStateError,
      );
      expect((await repo.current())!.instanceId, 'inst-1');
    });

    test('a stale token is fenced', () async {
      await repo.ensureProvisional('http://a');
      await expectLater(
        repo.recordVerified('stale', instanceId: 'inst-1', baseUrl: 'http://a'),
        throwsA(isA<BindingFencedException>()),
      );
      expect((await repo.current())!.instanceId, isNull);
    });
  });

  group('fence', () {
    test('fence() deletes the row', () async {
      await repo.ensureProvisional('http://a');
      await repo.fence();
      expect(await repo.current(), isNull);
      expect(await rows(), isEmpty);
    });

    test('runFenced commits the body while the binding holds', () async {
      final b = await repo.ensureProvisional('http://a');
      await repo.runFenced(b.localBindingId, () async {
        await db.customStatement(
          "INSERT INTO sync_cursors (stream, value) VALUES ('catalog', 5)",
        );
      });
      final c = await db.customSelect('SELECT value FROM sync_cursors').getSingle();
      expect(c.data['value'], 5);
    });

    test('after a reset the captured token makes the write a no-op', () async {
      final b = await repo.ensureProvisional('http://a');
      await repo.fence();
      var ran = false;
      await expectLater(
        repo.runFenced(b.localBindingId, () async {
          ran = true;
          await db.customStatement(
            "INSERT INTO sync_cursors (stream, value) VALUES ('catalog', 5)",
          );
        }),
        throwsA(isA<BindingFencedException>()),
      );
      expect(ran, isFalse);
      expect(await db.customSelect('SELECT * FROM sync_cursors').get(), isEmpty);
    });

    test('a re-bind (new row, new token) still fences the old token', () async {
      final old = await repo.ensureProvisional('http://a');
      await repo.fence();
      final fresh = await repo.ensureProvisional('http://b');
      expect(fresh.localBindingId, isNot(old.localBindingId));
      await expectLater(
        repo.runFenced(old.localBindingId, () async {}),
        throwsA(isA<BindingFencedException>()),
      );
      await repo.runFenced(fresh.localBindingId, () async {});
    });

    test('a fence failure inside the body rolls the body back', () async {
      final b = await repo.ensureProvisional('http://a');
      await expectLater(
        repo.runFenced(b.localBindingId, () async {
          await db.customStatement(
            "INSERT INTO sync_cursors (stream, value) VALUES ('catalog', 5)",
          );
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(await db.customSelect('SELECT * FROM sync_cursors').get(), isEmpty);
    });

    test('the fence check and the write share one transaction', () async {
      // A reset's fence (the row delete) that arrives while a fenced write is
      // in flight is ordered AFTER it: it cannot slip between the check and
      // the write.
      final b = await repo.ensureProvisional('http://a');
      final entered = Completer<void>();
      final release = Completer<void>();
      final write = repo.runFenced(b.localBindingId, () async {
        entered.complete();
        await release.future;
        await db.customStatement(
          "INSERT INTO sync_cursors (stream, value) VALUES ('catalog', 5)",
        );
      });
      await entered.future;
      var fenced = false;
      final fencing = repo.fence().then((_) => fenced = true);
      await pumpEventQueue();
      expect(fenced, isFalse, reason: 'the fence waits for the in-flight write');
      release.complete();
      await write;
      await fencing;
      expect(await repo.current(), isNull);
      final c = await db.customSelect('SELECT value FROM sync_cursors').getSingle();
      expect(c.data['value'], 5);
    });
  });

  // The flag is set by the catalog sync's final page, inside its fenced
  // transaction (sync_service_cursor_fence_test covers that end to end).
  group('catalog reconciliation flag', () {
    test('set inside a fenced transaction for the current binding', () async {
      final b = await repo.ensureProvisional('http://a');
      await repo.runFenced(
        b.localBindingId,
        repo.markCatalogReconciledInTransaction,
      );
      expect((await repo.current())!.catalogReconciled, isTrue);
    });

    test('a stale token cannot set it', () async {
      await repo.ensureProvisional('http://a');
      await expectLater(
        repo.runFenced('stale', repo.markCatalogReconciledInTransaction),
        throwsA(isA<BindingFencedException>()),
      );
      expect((await repo.current())!.catalogReconciled, isFalse);
    });
  });
}
