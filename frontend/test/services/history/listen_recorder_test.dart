import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/history/listen_recorder.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/server_binding.dart';

class _FlakyHistory extends HistoryRepository {
  _FlakyHistory(super.db);
  int failFinalizations = 0;
  @override
  Future<DraftFinalization> finalizeDraft(
      String bindingToken, HistoryEventPayload play) {
    if (failFinalizations > 0) {
      failFinalizations--;
      throw StateError('disk full');
    }
    return super.finalizeDraft(bindingToken, play);
  }

  int failFreezes = 0;
  @override
  Future<void> freezeDraft(
      String bindingToken, String listenUuid, HistoryEventPayload play) {
    if (failFreezes > 0) {
      failFreezes--;
      throw StateError('disk full');
    }
    return super.freezeDraft(bindingToken, listenUuid, play);
  }

  int failCheckpoints = 0;
  Completer<void>? checkpointGate;
  @override
  Future<void> checkpointDraft(String bindingToken, ListenDraft draft) async {
    final gate = checkpointGate;
    if (gate != null) await gate.future;
    if (failCheckpoints > 0) {
      failCheckpoints--;
      throw StateError('disk full');
    }
    return super.checkpointDraft(bindingToken, draft);
  }
}

void main() {
  late AppDatabase db;
  late _FlakyHistory history;
  late StreamController<PlaybackObservation> engine;
  late FakeClock clock;
  late ListenRecorder recorder;
  late String token;
  var sequence = 0;
  var uuids = 0;
  final errors = <Object>[];
  var elapsedSoFar = Duration.zero;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
    history = _FlakyHistory(db);
    engine = StreamController<PlaybackObservation>.broadcast();
    clock = FakeClock();
    sequence = 0;
    uuids = 0;
    errors.clear();
    elapsedSoFar = Duration.zero;
    recorder = ListenRecorder(
      observations: engine.stream,
      history: history,
      binding: ServerBindingRepository(db),
      clock: clock,
      newListenUuid: () =>
          '00000000-0000-4000-8000-${(++uuids).toString().padLeft(12, '0')}',
      onError: errors.add,
    );
  });

  tearDown(() async {
    await recorder.quiesce();
    await engine.close();
    await db.close();
  });

  /// Advances the clock to monotonic [t] s, then observes position [pos] s.
  Future<void> at(double t, double pos,
      {int item = 1,
      bool playing = true,
      EngineProcessingState state = EngineProcessingState.ready,
      PlaybackTransitionCause? cause,
      bool settle = true}) async {
    final target = Duration(microseconds: (t * 1000000).round());
    clock.advance(target - elapsedSoFar);
    elapsedSoFar = target;
    engine.add(PlaybackObservation(
      runtimeId: 1,
      sequence: ++sequence,
      playlistRevision: 1,
      source: EngineSourceIdentity(
          sourceId: item * 10, sessionId: 1, itemId: item, trackUuid: 't$item'),
      position: Duration(microseconds: (pos * 1000000).round()),
      duration: const Duration(seconds: 200),
      playing: playing,
      processingState: state,
      transitionCause: cause,
      rate: 1.0,
      uncertain: false,
    ));
    if (!settle) return;
    await pumpEventQueue();
    await recorder.idle;
  }

  Future<List<HistoryEvent>> plays() => (db.select(db.historyEvents)
        ..where((e) => e.kind.equals('play')))
      .get();

  test('first progress creates a draft; a pause checkpoints it', () async {
    await recorder.start();
    final startMs = clock.nowUtcMs();
    await at(0, 0);
    expect(await history.drafts(), isEmpty, reason: 'no progress yet');
    await at(2, 2);
    var draft = (await history.drafts()).single;
    expect(draft.trackUuid, 't1');
    expect(draft.startedAt, startMs);
    await at(3, 3, playing: false); // pause: checkpoint
    draft = (await history.drafts()).single;
    expect(draft.accumulatedMicros, 3000000);
  });

  test('accumulated progress is checkpointed every 5 s', () async {
    await recorder.start();
    for (var i = 0; i <= 6; i++) {
      await at(i.toDouble(), i.toDouble());
    }
    // Drafted at 1 s; the next checkpoint at 5 s more credit (6 s).
    expect((await history.drafts()).single.accumulatedMicros, 6000000);
  });

  test('a natural advance finalizes one play event and deletes its draft',
      () async {
    await recorder.start();
    final startMs = clock.nowUtcMs();
    await at(0, 0);
    await at(2, 2); // the draft holds 2 s
    await at(4, 4);
    await at(4, 0, item: 2, cause: PlaybackTransitionCause.naturalAdvance);
    final rows = await plays();
    expect(rows, hasLength(1));
    expect(rows.single.eventUuid, '00000000-0000-4000-8000-000000000001');
    expect(rows.single.entityRef, 't1');
    expect(rows.single.occurredAt, startMs);
    expect(rows.single.secondsPlayed, 4.0);
    expect(rows.single.trackLength, 200.0);
    expect(rows.single.pendingUpload, isTrue);
    expect((await history.drafts()).map((d) => d.trackUuid), isEmpty,
        reason: 't2 has no progress yet');
  });

  test('a zero-progress item records nothing', () async {
    await recorder.start();
    await at(0, 0);
    await at(0, 0, item: 2, cause: PlaybackTransitionCause.userSkip);
    expect(await plays(), isEmpty);
    expect(await history.drafts(), isEmpty);
  });

  test('a failed finalization freezes its payload; the next listen is '
      'separate; a retry lands the frozen payload', () async {
    await recorder.start();
    history.failFinalizations = 1;
    await at(0, 0);
    await at(4, 4);
    await at(4, 0, item: 2, cause: PlaybackTransitionCause.naturalAdvance);
    expect(await plays(), isEmpty);
    final frozen = (await history.drafts()).single;
    expect(frozen.finalizing, isTrue);
    expect(frozen.finalPayload?.secondsPlayed, 4.0);
    expect(errors, isNotEmpty, reason: 'the failure is reported');
    await at(7, 3, item: 2); // the next track progresses
    expect(await history.drafts(), hasLength(2),
        reason: 'the frozen one is not overwritten');
    await at(7, 0, item: 3, cause: PlaybackTransitionCause.naturalAdvance);
    final rows = await plays();
    expect(rows.map((r) => (r.entityRef, r.secondsPlayed)),
        unorderedEquals([('t1', 4.0), ('t2', 3.0)]));
  });

  test('startup settles previous drafts before new observations', () async {
    // A crash left one accumulating draft and one frozen finalization.
    // (At most one draft accumulates: the frozen one is seeded first.)
    await history.checkpointDraft(token, const ListenDraft(
      listenUuid: '22222222-2222-4222-8222-222222222222',
      queueSessionId: 1, queueItemId: 8, trackUuid: 'older',
      startedAt: 1600000000000, durationSeconds: null,
      accumulatedMicros: 1, lastCheckpointAt: 1600000000001,
    ));
    await history.freezeDraft(token, '22222222-2222-4222-8222-222222222222',
        const HistoryEventPayload(
          eventUuid: '22222222-2222-4222-8222-222222222222', kind: 'play',
          entityType: 'track', entityRef: 'older', occurredAt: 1600000000000,
          secondsPlayed: 30));
    await history.checkpointDraft(token, const ListenDraft(
      listenUuid: '11111111-1111-4111-8111-111111111111',
      queueSessionId: 1, queueItemId: 9, trackUuid: 'old',
      startedAt: 1700000000000, durationSeconds: null,
      accumulatedMicros: 12500000, lastCheckpointAt: 1700000012500,
    ));
    final arrivedMs = clock.nowUtcMs();
    await at(0, 0); // arrives before start(): buffered
    await at(2, 2);
    expect(await plays(), isEmpty, reason: 'nothing processed before start');
    clock.advance(const Duration(seconds: 10)); // recovery takes a while
    await recorder.start();
    await recorder.idle;
    final rows = await plays();
    expect(rows.map((r) => (r.entityRef, r.secondsPlayed)),
        unorderedEquals([('old', 12.5), ('older', 30.0)]),
        reason: 'persisted totals only, never extrapolated across downtime');
    final draft = (await history.drafts()).single;
    expect(draft.trackUuid, 't1',
        reason: 'the buffered observations then start a new listen');
    expect(draft.startedAt, arrivedMs, reason: 'stamped when it arrived');
    expect(draft.accumulatedMicros, 2000000,
        reason: 'credited by arrival times, not processing times');
  });

  test('startup deletes a draft that never earned credit', () async {
    await history.checkpointDraft(token, const ListenDraft(
      listenUuid: '44444444-4444-4444-8444-444444444444',
      queueSessionId: 1, queueItemId: 1, trackUuid: 'z',
      startedAt: 1700000000000, durationSeconds: null,
      accumulatedMicros: 0, lastCheckpointAt: 1700000000000,
    ));
    await recorder.start();
    expect(await history.drafts(), isEmpty);
    expect(await plays(), isEmpty);
  });

  test('after quiesce nothing more is recorded', () async {
    await recorder.start();
    await at(0, 0);
    await at(3, 3);
    await recorder.quiesce();
    await at(6, 6);
    await at(6, 0, item: 2, cause: PlaybackTransitionCause.naturalAdvance);
    expect(await plays(), isEmpty);
  });

  test('a background checkpoint persists credit below the 5 s cadence',
      () async {
    await recorder.start();
    await at(0, 0);
    await at(1, 1); // the draft is created at 1 s
    await at(3, 3);
    expect((await history.drafts()).single.accumulatedMicros, 1000000);
    await recorder.checkpoint();
    expect((await history.drafts()).single.accumulatedMicros, 3000000);
  });

  for (final (state, persists) in [
    (AppLifecycleState.resumed, false),
    (AppLifecycleState.inactive, false),
    (AppLifecycleState.hidden, true),
    (AppLifecycleState.paused, true),
    (AppLifecycleState.detached, true),
  ]) {
    test('app lifecycle ${state.name} '
        '${persists ? 'checkpoints' : 'leaves'} the listen, never finalizes',
        () async {
      await recorder.start();
      await at(0, 0);
      await at(1, 1);
      await at(3, 3);
      await recorder.appLifecycleChanged(state);
      expect((await history.drafts()).single.accumulatedMicros,
          persists ? 3000000 : 1000000);
      expect(await plays(), isEmpty);
    });
  }

  test('a replaced binding drops the listen without retrying', () async {
    await recorder.start();
    await at(0, 0);
    await at(3, 3);
    await ServerBindingRepository(db).fence();
    await seedTestBinding(db);
    await at(3, 0, item: 2, cause: PlaybackTransitionCause.naturalAdvance);
    expect(await plays(), isEmpty);
    expect(errors, isEmpty, reason: 'a fenced write is not a failure');
  });

  test('replaying a finalization that already landed is idempotent',
      () async {
    const play = HistoryEventPayload(
        eventUuid: '33333333-3333-4333-8333-333333333333', kind: 'play',
        entityType: 'track', entityRef: 'x', occurredAt: 1700000000000,
        secondsPlayed: 9);
    await history.checkpointDraft(token, const ListenDraft(
      listenUuid: '33333333-3333-4333-8333-333333333333',
      queueSessionId: 1, queueItemId: 1, trackUuid: 'x',
      startedAt: 1700000000000, durationSeconds: null,
      accumulatedMicros: 9000000, lastCheckpointAt: 1700000009000,
    ));
    await history.freezeDraft(token, play.eventUuid, play);
    // The crash hit after the event insert but before the draft delete
    // (simulated: the event is stored, the draft kept).
    await db.into(db.historyEvents).insert(HistoryEventsCompanion.insert(
          eventUuid: play.eventUuid, kind: 'play', entityType: 'track',
          entityRef: 'x', occurredAt: play.occurredAt,
          secondsPlayed: const Value(9.0), pendingUpload: true));
    await recorder.start();
    expect(await plays(), hasLength(1));
    expect(await history.drafts(), isEmpty);
    expect(errors, isEmpty);
  });

  group('branch audit M1: credit withdrawn to zero', () {
    test('the draft of a listen withdrawn to zero is deleted; the next listen '
        'checkpoints; no phantom play', () async {
      await recorder.start();
      await at(0, 0);
      await at(3, 3); // drafted with 3 s (extrapolated, as it turns out)
      expect((await history.drafts()).single.accumulatedMicros, 3000000);
      await at(3.5, 0, state: EngineProcessingState.buffering); // the real 0
      await at(4, 0, item: 2, cause: PlaybackTransitionCause.userSkip);
      expect(await history.drafts(), isEmpty, reason: 'nothing was heard of t1');
      for (var t = 5; t <= 12; t++) {
        await at(t.toDouble(), t - 4.0, item: 2);
      }
      expect((await history.drafts()).single.trackUuid, 't2');
      expect(errors, isEmpty, reason: 'no UNIQUE failure from a leftover draft');
      await recorder.quiesce();
      final again = await history.drafts();
      expect(again.map((d) => d.trackUuid), ['t2'], reason: 'no phantom t1 at the next start');
    });

    test('a decrease in credit is checkpointed at once', () async {
      await recorder.start();
      await at(0, 0);
      await at(4, 4);
      await at(4.5, 2, state: EngineProcessingState.buffering); // settles to 2 s
      expect((await history.drafts()).single.accumulatedMicros, 2000000);
    });
  });

  group('PR 5B audit (c)', () {
    test('credit and start time follow the monotonic clock across a wall '
        'clock correction', () async {
      await recorder.start();
      final startMs = clock.nowUtcMs();
      await at(0, 0);
      await at(2, 2);
      clock.jumpWallClock(const Duration(hours: -1));
      await at(3, 3);
      await at(3, 0, item: 2, cause: PlaybackTransitionCause.naturalAdvance);
      final play = (await plays()).single;
      expect(play.secondsPlayed, 3.0);
      expect(play.occurredAt, startMs);
    });

    test('quiesce waits out the write in flight', () async {
      await recorder.start();
      await at(0, 0);
      final gate = history.checkpointGate = Completer<void>();
      await at(2, 2, settle: false);
      await pumpEventQueue();
      var quiesced = false;
      final quiescing = recorder.quiesce().then((_) => quiesced = true);
      await pumpEventQueue();
      expect(quiesced, isFalse, reason: 'the draft write is still running');
      history.checkpointGate = null;
      gate.complete();
      await quiescing;
      expect(quiesced, isTrue);
    });
  });

  group('PR 5B audit (a)', () {
    test('a finalization that cannot even freeze is retried before the next '
        'draft; nothing floods', () async {
      await recorder.start();
      history.failFinalizations = 1;
      history.failFreezes = 1;
      await at(0, 0);
      await at(4, 4);
      await at(4, 0, item: 2, cause: PlaybackTransitionCause.naturalAdvance);
      for (var t = 1; t <= 12; t++) {
        await at(4.0 + t, t.toDouble(), item: 2);
      }
      expect((await plays()).map((r) => r.entityRef), ['t1'],
          reason: 'the in-memory intent landed once storage worked');
      expect((await history.drafts()).map((d) => d.trackUuid), ['t2']);
      expect(errors, hasLength(2), reason: 'one finalize + one freeze');
    });

    test('failing checkpoints are retried at the checkpoint cadence and '
        'reported once', () async {
      await recorder.start();
      history.failCheckpoints = 1000;
      for (var t = 0; t <= 12; t++) {
        await at(t.toDouble(), t.toDouble());
      }
      expect(errors, hasLength(1));
      expect(history.failCheckpoints, greaterThan(1000 - 5),
          reason: 'no write attempt per observation');
    });

    test('in-memory recovery intents are bounded', () async {
      await recorder.start();
      history.failFinalizations = 1000;
      history.failFreezes = 1000;
      for (var i = 1; i <= ListenRecorder.maxRecoveryIntents + 3; i++) {
        await at(i * 10.0, 0, item: i, cause: PlaybackTransitionCause.userSkip);
        await at(i * 10.0 + 2, 2, item: i);
      }
      await at(1000, 0, item: 999, cause: PlaybackTransitionCause.userSkip);
      history.failFinalizations = 0;
      history.failFreezes = 0;
      await at(1002, 2, item: 999);
      await at(1002, 0, item: 1000, cause: PlaybackTransitionCause.userSkip);
      final refs = (await plays()).map((r) => r.entityRef).toSet();
      expect(refs, hasLength(ListenRecorder.maxRecoveryIntents + 1));
      expect(refs, isNot(contains('t1')), reason: 'the oldest is dropped');
      expect(refs, containsAll(['t4', 't35', 't999']),
          reason: 'the newest are kept');
    });
  });
}
