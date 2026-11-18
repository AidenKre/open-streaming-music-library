// Phase 7B.1a-f1 (SC-01 rule 6; 7B.1a review #1, wiring): the scope's
// tracks API goes through the bound client, so the single-track refetch
// (conflict "take server") that 7B.1a left unchecked is covered too:
//  * a refetch answered by another instance changes no local row (not even
//    on a 404, which would otherwise delete the track) and runs rule 1's
//    different-server flow through the gate;
//  * a legacy server (no stamp) and the bound instance refetch as today.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
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
    await seedTrackRow(db, 'u1');
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
  });

  tearDown(() async {
    controlled.dispose();
    c.dispose();
    await db.close();
  });

  test('a refetch answered by another instance changes nothing locally',
      () async {
    server.stamp = otherInstance;
    server.onGetTrack = (uuid) => (200, trackJson(uuid, title: 'Foreign'));
    final before = await catalogAndOutboxSnapshot(db);

    final refreshed =
        await c.read(trackSyncProvider.notifier).refreshTrack('u1');
    await pumpEventQueue();

    expect(refreshed, isFalse);
    expect(await catalogAndOutboxSnapshot(db), before);
    expect(
      controlled.gate.state,
      isA<BindingDifferentServer>()
          .having((s) => s.serverInstanceId, 'server', otherInstance),
    );
    final state = c.read(trackSyncProvider).value!;
    expect(state.error ?? '', isNot(contains(otherInstance)));
    expect(state.error ?? '', isNot(contains(boundInstance)));
  });

  test('a 404 from another instance does not delete the local track',
      () async {
    server.stamp = otherInstance;
    server.onGetTrack = (_) => (404, {'detail': 'gone'});
    final before = await catalogAndOutboxSnapshot(db);

    await c.read(trackSyncProvider.notifier).refreshTrack('u1');
    await pumpEventQueue();

    expect(await catalogAndOutboxSnapshot(db), before);
    expect(controlled.gate.state, isA<BindingDifferentServer>());
  });

  test('a refetch from the bound instance applies as today', () async {
    server.stamp = boundInstance.toUpperCase();
    server.onGetTrack = (uuid) => (200, trackJson(uuid, title: 'Server'));

    final refreshed =
        await c.read(trackSyncProvider.notifier).refreshTrack('u1');

    expect(refreshed, isTrue);
    final meta = await db.select(db.trackmetadata).getSingle();
    expect(meta.title, 'Server');
    expect(controlled.gate.state, isA<BindingVerified>());
  });

  test('a refetch from a legacy server (no stamp) applies as today', () async {
    server.stamp = null;
    server.onGetTrack = (_) => (404, {'detail': 'gone'});

    final refreshed =
        await c.read(trackSyncProvider.notifier).refreshTrack('u1');

    expect(refreshed, isTrue);
    expect(await db.select(db.tracks).get(), isEmpty);
    expect(controlled.gate.state, isA<BindingVerified>());
  });
}
