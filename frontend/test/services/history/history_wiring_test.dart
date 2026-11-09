// PR 5A wiring: the history runner reaches recovery, reset and the network.
//  * recovery member (after appInfo): requests a pass, recovery edges
//    bypass backoff, requiresBinding;
//  * reset: the history participant quiesces right after playback; its loss
//    line counts every unsent event;
//  * offline mode drives the poll; an end-to-end pass through the real
//    providers uploads a local event and clears it.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/history/history_sync_triggers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/server_binding.dart';

class _RecordingRunner extends SingleFlightRunner {
  _RecordingRunner()
    : super(
        name: 'recording',
        pass: (_) async => const PassDone(),
        backoff: BackoffSchedule(),
      );
  final requests = <(String, bool)>[];
  var quiesced = 0;
  @override
  void request(String reason, {bool bypassBackoff = false}) =>
      requests.add((reason, bypassBackoff));
  @override
  Future<void> quiesce() async => quiesced++;
}

class _Offline extends OfflineModeNotifier {
  _Offline(this.initial);
  final bool initial;
  @override
  bool build() => initial;
  void set(bool v) => state = v;
}

class _InsertTriggers extends HistorySyncTriggers {
  _InsertTriggers() : super(request: (_) {});
  var inserts = 0;
  @override
  void localInsert() => inserts++;
}

HistoryEventPayload _event(String uuid) => HistoryEventPayload(
  eventUuid: uuid,
  kind: 'clicked',
  entityType: 'track',
  entityRef: 't-1',
  occurredAt: 1000,
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

  ProviderContainer scope({SingleFlightRunner? runner, _Offline? offline}) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        autoVerifiedGateOverride(),
        if (runner != null) historyRunnerProvider.overrideWithValue(runner),
        if (offline != null) offlineModeProvider.overrideWith(() => offline),
        appInfoProvider.overrideWith((ref) async => const AppInfo(historyVersion: 1)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('the recovery member requests a pass; edges bypass the backoff', () async {
    final runner = _RecordingRunner();
    final c = scope(runner: runner);
    final member = c
        .read(recoverablesProvider)
        .singleWhere((m) => m.recoveryPriority == RecoveryPriority.history);
    expect(member.requiresBinding, isTrue);
    expect(member.triggers, RecoveryTrigger.values.toSet());
    expect(RecoveryPriority.history, lessThan(RecoveryPriority.appInfo),
        reason: 'runs after capabilities are refreshed');
    await member.recover(RecoveryTrigger.coldStart);
    await member.recover(RecoveryTrigger.networkRecovered);
    await member.recover(RecoveryTrigger.appResume);
    expect(runner.requests, [
      ('coldStart', false),
      ('networkRecovered', true),
      ('appResume', true),
    ]);
  });

  test('reset quiesces history after playback and listen recording',
      () async {
    final runner = _RecordingRunner();
    final c = scope(runner: runner);
    final participants = c.read(localQuiescablesProvider);
    expect(participants.map((p) => p.quiesceName),
        ['playback', 'listens', 'history']);
    final history = participants.singleWhere((p) => p.quiesceName == 'history');
    await history.quiesce();
    expect(runner.quiesced, 0, reason: 'nothing built: nothing to stop (branch audit 5A N1)');
    c.read(historyRunnerProvider); // the app builds it at startup
    await participants.singleWhere((p) => p.quiesceName == 'history')
        .quiesce();
    expect(runner.quiesced, 1);
  });

  test('the loss line counts every unsent history event', () async {
    final c = scope(runner: _RecordingRunner());
    final repo = c.read(historyRepositoryProvider);
    final reset = c.read(localResetServiceProvider);
    expect(await reset.pendingLossSummaries(), isEmpty);
    await repo.insertLocal(token, _event('a'));
    expect(await reset.pendingLossSummaries(), ['1 unsent history event']);
    await repo.insertLocal(token, _event('b'));
    await repo.recordFailure(token, 'b', reason: 'conflict');
    expect(await reset.pendingLossSummaries(), ['2 unsent history events'],
        reason: 'quarantined events are unsent too');
    // Branch audit (5A M5): listens not yet saved as events are unsent too.
    await repo.checkpointDraft(token, const ListenDraft(
      listenUuid: '66666666-6666-4666-8666-666666666666',
      queueSessionId: 1, queueItemId: 1, trackUuid: 't-1',
      startedAt: 1000, durationSeconds: null,
      accumulatedMicros: 3000000, lastCheckpointAt: 4000,
    ));
    expect(await reset.pendingLossSummaries(), ['3 unsent history events']);
  });

  test('offline mode suspends and resumes the foreground poll', () async {
    final offline = _Offline(false);
    final c = scope(runner: _RecordingRunner(), offline: offline);
    c.read(offlineModeProvider);
    final triggers = c.read(historySyncTriggersProvider);
    triggers.setForeground(true);
    expect(triggers.isPolling, isTrue);
    offline.set(true);
    expect(triggers.isPolling, isFalse);
    offline.set(false);
    expect(triggers.isPolling, isTrue);
  });

  test('end to end: a requested pass uploads a local event and clears it',
      () async {
    final posted = <List<String>>[];
    ApiClient.initForTest(
      'http://test',
      MockClient((req) async {
        if (req.method == 'POST' && req.url.path == '/history') {
          final events = (jsonDecode(req.body)['events'] as List)
              .map((e) => (e as Map)['event_uuid'] as String)
              .toList();
          posted.add(events);
          return http.Response(jsonEncode({'acknowledged': events}), 200,
              headers: {'content-type': 'application/json'});
        }
        if (req.url.path == '/history/changes') {
          return http.Response(
            jsonEncode({'events': [], 'nextCursor': null, 'latestRevision': 0}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      }),
    );
    final c = scope();
    // Audit 5A(a) #1: app info is NOT pre-loaded (as on a cold start); the
    // pass must load it rather than read "unsupported" from a loading value.
    await c.read(serverBindingGateProvider).awaitVerified();
    final repo = c.read(historyRepositoryProvider);
    await repo.insertLocal(token, _event('a'));
    final runner = c.read(historyRunnerProvider);
    runner.request('test', bypassBackoff: true);
    await pumpEventQueue();
    await runner.whenIdle();
    expect(posted, [
      ['a'],
    ]);
    final row = await db.customSelect('SELECT pending_upload FROM history_events').getSingle();
    expect(row.read<int>('pending_upload'), 0);
  });

  test('a committed local insert notifies the debounce; failed inserts do not', () async {
    final triggers = _InsertTriggers();
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      historySyncTriggersProvider.overrideWithValue(triggers),
    ]);
    addTearDown(c.dispose);
    final repo = c.read(historyRepositoryProvider);
    await repo.insertLocal(token, _event('debounced'));
    expect(triggers.inserts, 1);
    expect(await repo.localPayload('debounced'), _event('debounced'));
    await expectLater(repo.insertLocal(token, _event('debounced')), throwsA(anything));
    await expectLater(repo.insertLocal('stale-binding', _event('fenced')),
        throwsA(anything));
    expect(triggers.inserts, 1, reason: 'notify only durable successful inserts');
  });
}
