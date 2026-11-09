// PR 5A (SC-21 model side, 5-T15 model): history diagnostics.
//  * historyDiagnosticsProvider: live pending/quarantined counts plus the
//    sync status (last error, waiting for server support, restored server)
//    and blocked conflicts paired with this device's payload.
//  * Retry clears rejected/oversized quarantine (never conflicts) and asks
//    for a pass now; "Keep server version" resolves through the repository
//    with the verified token, then asks for a pass.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/history_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/history/history_diagnostics.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/history/history_sync_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/server_binding.dart';

class _RecordingRunner extends SingleFlightRunner {
  _RecordingRunner()
    : super(name: 'r', pass: (_) async => const PassDone(), backoff: BackoffSchedule());
  final requests = <(String, bool)>[];
  @override
  void request(String reason, {bool bypassBackoff = false}) =>
      requests.add((reason, bypassBackoff));
}

class _GatedPayloadRepository extends HistoryRepository {
  _GatedPayloadRepository(super.db);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<HistoryEventPayload?> localPayload(String uuid) async {
    final payload = await super.localPayload(uuid);
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return payload;
  }
}

class _StatusService extends HistorySyncService {
  _StatusService(AppDatabase db) : super(
    repository: HistoryRepository(db), api: HistoryApi(),
    cursors: SyncCursorStore(db), verifiedToken: () => null,
    isOffline: () => true, supportsHistory: () async => false,
  );
  final current = ValueNotifier(const HistorySyncStatus());
  @override
  ValueListenable<HistorySyncStatus> get status => current;
}

HistoryEventPayload _event(String uuid, {double seconds = 30.5}) =>
    HistoryEventPayload(
      eventUuid: uuid,
      kind: 'play',
      entityType: 'track',
      entityRef: 't-1',
      occurredAt: 1000,
      secondsPlayed: seconds,
    );

void main() {
  late AppDatabase db;
  late String token;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
  });
  tearDown(() => db.close());

  ProviderContainer scope({
    SingleFlightRunner? runner,
    bool supported = true,
  }) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        autoVerifiedGateOverride(),
        if (runner != null) historyRunnerProvider.overrideWithValue(runner),
        appInfoProvider.overrideWith(
          (ref) async => AppInfo(historyVersion: supported ? 1 : null),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<HistoryDiagnostics> next(
    ProviderContainer c,
    bool Function(HistoryDiagnostics) until,
  ) async {
    for (var i = 0; i < 50; i++) {
      final v = c.read(historyDiagnosticsProvider).value;
      if (v != null && until(v)) return v;
      await pumpEventQueue();
    }
    fail('diagnostics never matched; last ${c.read(historyDiagnosticsProvider)}');
  }

  test('counts are live', () async {
    final c = scope(runner: _RecordingRunner());
    c.listen(historyDiagnosticsProvider, (_, _) {});
    await next(c, (d) => d.pending == 0 && d.quarantined == 0);
    final repo = c.read(historyRepositoryProvider);
    await repo.insertLocal(token, _event('a'));
    await repo.insertLocal(token, _event('b'));
    await next(c, (d) => d.pending == 2);
    await repo.recordFailure(token, 'b', reason: 'rejected');
    final d = await next(c, (d) => d.quarantined == 1);
    expect(d.pending, 1);
  });

  for (final disposeWhilePending in [false, true]) {
    test('late conflict lookup cannot publish after ${disposeWhilePending ? 'dispose' : 'resolution'}', () async {
      final repository = _GatedPayloadRepository(db);
      await repository.insertLocal(token, _event('mine'));
      final service = _StatusService(db);
      final c = ProviderContainer(overrides: [
        historyRepositoryProvider.overrideWithValue(repository),
        historySyncServiceProvider.overrideWithValue(service),
      ]);
      addTearDown(c.dispose);
      addTearDown(service.current.dispose);
      final seen = <HistoryDiagnostics>[];
      c.listen(historyDiagnosticsProvider, (_, value) {
        if (value.value != null) seen.add(value.value!);
      });
      await next(c, (d) => d.pending == 1);
      service.current.value = HistorySyncStatus(blockedConflicts: [
        HistoryServerEvent(payload: _event('mine', seconds: 99), revision: 5, receivedAt: 7),
      ]);
      await repository.entered.future;
      if (disposeWhilePending) {
        c.dispose();
      } else {
        service.current.value = const HistorySyncStatus(lastError: 'resolved');
        await next(c, (d) => d.lastError == 'resolved');
      }
      final beforeRelease = seen.length;
      repository.release.complete();
      await pumpEventQueue();
      expect(seen.length, beforeRelease, reason: 'stale lookup must not publish');
      expect(seen.every((d) => d.conflicts.isEmpty), isTrue);
    });
  }

  test('the sync status flows through (waiting for server support)', () async {
    final c = scope(supported: false);
    c.listen(historyDiagnosticsProvider, (_, _) {});
    await c.read(appInfoProvider.future);
    await c.read(serverBindingGateProvider).awaitVerified();
    await c.read(historySyncServiceProvider).runPass({'test'});
    final d = await next(c, (d) => d.waitingForServerSupport);
    expect(d.serverRegressed, isFalse);
  });

  test('a blocked conflict pairs the local and server payloads', () async {
    ApiClient.initForTest(
      'http://test',
      MockClient((req) async {
        if (req.method == 'POST') {
          return http.Response(jsonEncode({'acknowledged': []}), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response(
          jsonEncode({
            'events': [
              {
                'event_uuid': 'mine', 'revision': 5, 'kind': 'play',
                'entity_type': 'track', 'entity_ref': 't-1',
                'occurred_at': 1000, 'seconds_played': 99.0,
                'track_length': null, 'received_at': 7,
              },
            ],
            'nextCursor': null,
            'latestRevision': 5,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final c = scope();
    c.listen(historyDiagnosticsProvider, (_, _) {});
    await c.read(appInfoProvider.future);
    await c.read(serverBindingGateProvider).awaitVerified();
    await c.read(historyRepositoryProvider).insertLocal(token, _event('mine'));
    await c.read(historySyncServiceProvider).runPass({'test'});
    final d = await next(c, (d) => d.conflicts.isNotEmpty);
    final pair = d.conflicts.single;
    expect(pair.local.secondsPlayed, 30.5);
    expect(pair.server.payload.secondsPlayed, 99.0);
    expect(pair.server.revision, 5);
  });

  test('Retry clears rejected/oversized quarantine, keeps conflicts, runs now',
      () async {
    final runner = _RecordingRunner();
    final c = scope(runner: runner);
    final repo = c.read(historyRepositoryProvider);
    for (final (id, reason) in [('r', 'rejected'), ('o', 'oversized'), ('c', 'conflict')]) {
      await repo.insertLocal(token, _event(id));
      await repo.recordFailure(token, id, reason: reason);
    }
    await c.read(historyDiagnosticsActionsProvider).retry();
    final left = await db.customSelect('SELECT event_uuid FROM history_sync_failures').get();
    expect(left.map((r) => r.read<String>('event_uuid')), ['c']);
    expect(runner.requests, [('retry', true)]);
  });

  test('Keep server version resolves the conflict, then runs a pass', () async {
    final runner = _RecordingRunner();
    final c = scope(runner: runner);
    await c.read(serverBindingGateProvider).awaitVerified();
    await c.read(historyRepositoryProvider).insertLocal(token, _event('mine'));
    final server = HistoryServerEvent(
      payload: _event('mine', seconds: 99),
      revision: 5,
      receivedAt: 7,
    );
    await c.read(historyDiagnosticsActionsProvider).keepServerVersion(server);
    final row = await db.customSelect(
      "SELECT seconds_played, pending_upload FROM history_events WHERE event_uuid='mine'",
    ).getSingle();
    expect(row.data, {'seconds_played': 99.0, 'pending_upload': 0});
    expect(runner.requests, [('keepServerVersion', true)]);
  });
}
