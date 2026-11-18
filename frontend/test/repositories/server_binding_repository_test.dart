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

  // Phase M §7.4 / SC-01 Phase M amendment (M-U21): the library identity is
  // (instance_id, user_id). Login (M.3c) creates the row with both IDs; a
  // row without a user (NULL) is an unknown user, never user 0.
  group('Phase M: the binding carries the user', () {
    test('ensureProvisional with both ids stores them in the row', () async {
      final b = await repo.ensureProvisional(
        'http://a:8000',
        userId: 7,
        instanceId: 'inst-1',
      );
      expect(b.userId, 7);
      expect(b.instanceId, 'inst-1');
      expect(b.localBindingId, 'binding-1');
      final row = (await rows()).single;
      expect(row['user_id'], 7);
      expect(row['instance_id'], 'inst-1');
    });

    test('without a user the row holds NULL (unknown), not 0', () async {
      final b = await repo.ensureProvisional('http://a:8000');
      expect(b.userId, isNull);
      expect((await rows()).single['user_id'], isNull);
    });

    test('an existing row is returned unchanged: its user is never '
        'overwritten', () async {
      await repo.ensureProvisional('http://a', userId: 7, instanceId: 'i1');
      final again = await repo.ensureProvisional(
        'http://b',
        userId: 8,
        instanceId: 'i2',
      );
      expect(again.userId, 7);
      expect(again.instanceId, 'i1');
      expect(again.localBindingId, 'binding-1');
      expect((await rows()).single['user_id'], 7);
    });

    test('current() reads the user back', () async {
      await repo.ensureProvisional('http://a', userId: 7, instanceId: 'i1');
      expect((await repo.current())!.userId, 7);
    });

    test('recordVerified keeps the user', () async {
      final b = await repo.ensureProvisional('http://a', userId: 7);
      await repo.recordVerified(
        b.localBindingId,
        instanceId: 'i1',
        baseUrl: 'http://a2',
      );
      final after = (await repo.current())!;
      expect(after.userId, 7);
      expect(after.instanceId, 'i1');
    });
  });

  // Phase M §7.6 / SC-15 amendment: logout is not a reset. rotate() mints a
  // new local_binding_id and keeps the identity and the reconciled flag, so
  // a late durable write from the old scope is a no-op while every local
  // store stays.
  group('rotate (logout fence)', () {
    test('mints a new token and keeps instance, user, URL and reconciled',
        () async {
      final b = await repo.ensureProvisional('http://a',
          userId: 7, instanceId: 'i1');
      await repo.runFenced(
          b.localBindingId, repo.markCatalogReconciledInTransaction);
      final rotated = await repo.rotate();
      expect(rotated, isNotNull);
      expect(rotated!.localBindingId, isNot(b.localBindingId));
      final row = (await repo.current())!;
      expect(row.localBindingId, rotated.localBindingId);
      expect(row.instanceId, 'i1');
      expect(row.userId, 7);
      expect(row.lastBaseUrl, 'http://a');
      expect(row.catalogReconciled, isTrue);
      expect(await rows(), hasLength(1));
    });

    test("a fenced write with the old scope's token is dropped", () async {
      final b = await repo.ensureProvisional('http://a',
          userId: 7, instanceId: 'i1');
      await repo.rotate();
      var ran = false;
      await expectLater(
        repo.runFenced(b.localBindingId, () async => ran = true),
        throwsA(isA<BindingFencedException>()),
      );
      expect(ran, isFalse);
    });

    test('the new token is accepted by fenced writes', () async {
      await repo.ensureProvisional('http://a', userId: 7, instanceId: 'i1');
      final rotated = (await repo.rotate())!;
      expect(await repo.runFenced(rotated.localBindingId, () async => 42), 42);
    });

    test('without a row it creates none', () async {
      expect(await repo.rotate(), isNull);
      expect(await rows(), isEmpty);
    });
  });
}
