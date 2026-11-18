// Phase 7B.1a-f1 (SC-01 rule 6 for writes; 7B.1a review #1, exit proof b):
// a history upload whose response (the acknowledgement) is stamped by
// another server instance treats the batch as not delivered:
//  * no listen is marked uploaded, quarantined or failed, whatever the
//    status (200 ACK, 409, 413, 422, 503): every history row stays exactly
//    as before the send;
//  * no further batch is sent and the pull of the same pass does not run;
//  * rule 1's different-server flow runs through the scope's gate;
//  * nothing is re-sent while the binding is blocked;
//  * the bound instance and a legacy server (no stamp) upload as today.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/server_binding.dart';
import '../../helpers/stamped_server.dart';

class _Online extends OfflineModeNotifier {
  @override
  bool build() {
    super.build();
    return false;
  }
}

HistoryEventPayload _event(int i) => HistoryEventPayload(
  eventUuid: 'e${i.toString().padLeft(4, '0')}',
  kind: 'play',
  entityType: 'track',
  entityRef: 't-1',
  occurredAt: 1000 + i,
  secondsPlayed: 30.5,
);

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late StampedServer server;
  late ProviderContainer c;

  // More than one batch (maxBatchEvents per batch).
  const events = HistoryRepository.maxBatchEvents + 1;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    final token = await seedTestBinding(
      db,
      baseUrl: 'http://s',
      instanceId: boundInstance,
      reconciled: true,
    );
    controlled = ControlledGate(db);
    server = StampedServer();
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(server.client),
        appInfoProvider.overrideWith(
          (ref) async => AppInfo.fromJson({'history': {'version': 1}}),
        ),
        offlineModeProvider.overrideWith(_Online.new),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
      ],
    );
    final repo = HistoryRepository(db);
    for (var i = 0; i < events; i++) {
      await repo.insertLocal(token, _event(i));
    }
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

  Future<List<Object>> historySnapshot() async => [
    ...await db.select(db.historyEvents).get(),
    ...await db.select(db.historySyncFailures).get(),
    ...await db.select(db.syncCursors).get(),
  ];

  Future<int> pendingCount() async => (await (db.select(db.historyEvents)
        ..where((t) => t.pendingUpload.equals(true)))
      .get())
      .length;

  Future<PassOutcome> runPass() =>
      c.read(historySyncServiceProvider).runPass({'poll'});

  final statuses = <int, Object? Function(List<String> uuids)>{
    200: (uuids) => {'acknowledged': uuids},
    409: (uuids) => {
      'detail': {
        'error': 'history_event_conflict',
        'conflicting_event_uuids': [uuids.first],
      },
    },
    413: (_) => {'detail': 'too large'},
    422: (_) => {
      'detail': [
        {'loc': ['body', 'events', 0], 'msg': 'bad'},
      ],
    },
    503: (_) => {'detail': 'busy'},
  };

  for (final MapEntry(key: status, value: body) in statuses.entries) {
    test('a $status stamped by another instance marks nothing and stops the '
        'pass', () async {
      server.stamp = otherInstance;
      server.onPostHistory = (uuids) => (status, body(uuids));
      final before = await historySnapshot();

      final out = await runPass();
      await pumpEventQueue();

      expect(out, isA<PassFailed>());
      expect(server.requests, ['POST /history'],
          reason: 'one batch, no retry, no further batch, no pull');
      expect(await historySnapshot(), before);
      expect(await pendingCount(), events);
      expect(
        controlled.gate.state,
        isA<BindingDifferentServer>()
            .having((s) => s.serverInstanceId, 'server', otherInstance),
      );
      final diag = c.read(historySyncServiceProvider).status.value;
      expect(diag.lastError ?? '', isNot(contains(otherInstance)));
      expect(diag.lastError ?? '', isNot(contains(boundInstance)));
    });
  }

  test('a batch acknowledged before the server changed stays uploaded',
      () async {
    var posts = 0;
    server.onPostHistory = (uuids) {
      if (++posts == 2) server.stamp = otherInstance;
      return (200, {'acknowledged': uuids});
    };

    await runPass();
    await pumpEventQueue();

    expect(server.requests, ['POST /history', 'POST /history']);
    expect(await pendingCount(), events - HistoryRepository.maxBatchEvents);
    expect(controlled.gate.state, isA<BindingDifferentServer>());
  });

  test('nothing is re-sent while the binding is blocked', () async {
    server.stamp = otherInstance;
    await runPass();
    expect(server.requests, hasLength(1));

    final again = await runPass();

    expect(again, isA<PassFailed>());
    expect(server.requests, hasLength(1));
    expect(await pendingCount(), events);
  });

  test('the bound instance uploads every batch and pulls', () async {
    server.stamp = boundInstance.toUpperCase();

    await runPass();

    expect(server.requestsMatching('POST /history'), hasLength(2));
    expect(server.requestsMatching('GET /history/changes'), hasLength(1));
    expect(await pendingCount(), 0);
    expect(controlled.gate.state, isA<BindingVerified>());
  });

  test('a legacy server (no stamp) uploads every batch and pulls', () async {
    server.stamp = null;

    await runPass();

    expect(server.requestsMatching('POST /history'), hasLength(2));
    expect(server.requestsMatching('GET /history/changes'), hasLength(1));
    expect(await pendingCount(), 0);
    expect(controlled.gate.state, isA<BindingVerified>());
  });
}
