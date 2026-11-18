// Phase 7B.1a-f1 (SC-01 rule 6 for writes; 7B.1a review #1, exit proof a):
// an edit-outbox flush whose PATCH response is stamped by another server
// instance treats that edit as not delivered:
//  * the flush stops at the first mismatching response: that edit's row,
//    and every local catalog row, stay exactly as before the send (not
//    sent, acknowledged, conflicted or rejected), whatever the status
//    (200, 409, 404, 422, 503);
//  * no later pending edit is sent, and the catalog pull of the same sync
//    does not run;
//  * rule 1's different-server flow runs (the gate blocks), from the sync
//    path and from a standalone flush;
//  * nothing is re-sent while the binding is blocked (no retry storm);
//  * the bound instance (any case) and a legacy server (no stamp) flush as
//    today.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:http/http.dart' as http;
import 'package:frontend/database/database.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';
import '../helpers/stamped_server.dart';
import '../helpers/test_offline.dart';

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late StampedServer server;
  late ProviderContainer c;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(
      db,
      baseUrl: 'http://s',
      instanceId: boundInstance,
      reconciled: true,
    );
    for (final uuid in ['u1', 'u2', 'u3']) {
      await seedTrackRow(db, uuid);
    }
    controlled = ControlledGate(db);
    server = StampedServer();
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(server.client),
        offlineModeProvider.overrideWith(() => TestOffline(false)),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
      ],
    );
    c.listen(trackSyncProvider, (_, _) {});
    await c.read(trackSyncProvider.future);
    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond(boundInstance);
    await pumpEventQueue();
    expect(controlled.gate.state, isA<BindingVerified>());

    final outbox = c.read(editOutboxProvider);
    for (final uuid in ['u1', 'u2', 'u3']) {
      await outbox.enqueue(
        uuidId: uuid,
        edit: const MetadataEdit.empty().set('title', 'Mine $uuid'),
        writeMode: EditWriteMode.dbOnly,
        baseRevision: 5,
      );
    }
  });

  tearDown(() async {
    controlled.dispose();
    c.dispose();
    await db.close();
  });

  Future<void> syncNow() => c.read(trackSyncProvider.notifier).sync();

  void expectDifferentServer() => expect(
    controlled.gate.state,
    isA<BindingDifferentServer>()
        .having((s) => s.serverInstanceId, 'server', otherInstance),
  );

  final statuses = <int, Object?>{
    200: {'uuid_id': 'x', 'revision': 6, 'master_written': false},
    409: {
      'detail': {'error': 'revision_conflict', 'current_revision': 8},
    },
    404: {'detail': 'gone'},
    422: {'detail': 'locked field'},
    503: {'detail': 'busy'},
  };

  for (final MapEntry(key: status, value: body) in statuses.entries) {
    test('sync: a $status stamped by another instance stops the flush and '
        'leaves every row as it was', () async {
      server.stamp = otherInstance;
      server.onPatchTrack = (_, _) => (status, body);
      server.onGetTrack = (uuid) => (200, trackJson(uuid, title: 'Mine $uuid'));
      final before = await catalogAndOutboxSnapshot(db);

      await syncNow();
      await pumpEventQueue();

      expect(server.requestsMatching('PATCH'), hasLength(1));
      expect(server.requestsMatching('GET'), isEmpty,
          reason: 'no conflict refetch, no catalog pull');
      expect(await catalogAndOutboxSnapshot(db), before);
      expectDifferentServer();
      final state = c.read(trackSyncProvider).value!;
      expect(state.error ?? '', isNot(contains(otherInstance)));
      expect(state.libraryError, isNull);
    });
  }

  test('a standalone flush stops at the first mismatch and runs the flow',
      () async {
    server.stamp = otherInstance;
    final before = await catalogAndOutboxSnapshot(db);

    await c.read(editOutboxProvider).flush();
    await pumpEventQueue();

    expect(server.requestsMatching('PATCH'), hasLength(1));
    expect(await catalogAndOutboxSnapshot(db), before);
    expectDifferentServer();
  });

  test('edits applied before the mismatch stay applied; later ones wait',
      () async {
    var patches = 0;
    server.onPatchTrack = (uuid, _) {
      // The server is replaced after the first edit was answered.
      if (++patches == 2) server.stamp = otherInstance;
      return (200, {'uuid_id': uuid, 'revision': 6, 'master_written': false});
    };

    await syncNow();
    await pumpEventQueue();

    final sent = server.requestsMatching('PATCH');
    expect(sent, hasLength(2));
    final first = sent[0].split('/').last;
    final second = sent[1].split('/').last;
    final pending = {
      for (final r in await db.select(db.pendingEdits).get()) r.uuidId: r,
    };
    expect(pending.containsKey(first), isFalse, reason: 'delivered');
    expect(pending.keys.toSet(), {'u1', 'u2', 'u3'}..remove(first));
    expect(pending[second]!.status, 'pending');
    expect(server.requestsMatching('GET /changes'), isEmpty);
    expectDifferentServer();
  });

  test('nothing is re-sent while the binding is blocked', () async {
    server.stamp = otherInstance;
    await syncNow();
    await pumpEventQueue();
    expect(server.requests, hasLength(1));

    // Every later trigger waits on the gate instead of sending.
    unawaited(c.read(editOutboxProvider).flush());
    unawaited(syncNow());
    await c.read(editOutboxProvider).submit(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'Again'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await pumpEventQueue();

    expect(server.requests, hasLength(1));
    expectDifferentServer();
  });

  test('a flush queued behind the mismatching one sends nothing', () async {
    // Review F1: both flushes hold the verified token before the first one's
    // response is checked; the second gets the mutex after the report.
    server.stamp = otherInstance;
    final outbox = c.read(editOutboxProvider);

    await Future.wait([outbox.flush(), outbox.flush()]);
    await pumpEventQueue();

    expect(server.requestsMatching('PATCH'), hasLength(1));
    expectDifferentServer();
  });

  test('a sync queued behind a mismatching flush sends nothing', () async {
    server.stamp = otherInstance;

    await Future.wait([c.read(editOutboxProvider).flush(), syncNow()]);
    await pumpEventQueue();

    expect(server.requests, hasLength(1));
    expectDifferentServer();
  });

  test('an unreachable server stops the flush after the first edit', () async {
    // Review F2: the sequential flush must not walk every pending edit
    // through its own retries (and hold the edit mutex) when the transport
    // is down.
    server.onPatchTrack = (_, _) => throw http.ClientException('down');
    final before = await catalogAndOutboxSnapshot(db);

    await c.read(editOutboxProvider).flush();

    final sent = server.requestsMatching('PATCH');
    expect(sent.toSet(), hasLength(1), reason: 'only the first edit tried');
    expect(await catalogAndOutboxSnapshot(db), before);
  });

  test('the bound instance (any case) flushes every edit and pulls', () async {
    server.stamp = '  ${boundInstance.toUpperCase()} ';

    await syncNow();

    expect(server.requestsMatching('PATCH'), hasLength(3));
    expect(server.requestsMatching('GET /changes'), hasLength(1));
    expect(await db.select(db.pendingEdits).get(), isEmpty);
    expect(controlled.gate.state, isA<BindingVerified>());
  });

  test('a legacy server (no stamp) flushes every edit and pulls', () async {
    server.stamp = null;

    await syncNow();

    expect(server.requestsMatching('PATCH'), hasLength(3));
    expect(server.requestsMatching('GET /changes'), hasLength(1));
    expect(await db.select(db.pendingEdits).get(), isEmpty);
    expect(controlled.gate.state, isA<BindingVerified>());
  });
}
