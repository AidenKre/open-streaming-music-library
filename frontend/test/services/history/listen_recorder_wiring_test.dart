import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/history/listen_recorder.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/server_binding.dart';

class _FakeRecorder implements ListenRecorder {
  int quiesces = 0;
  @override
  Future<void> start() async {}
  @override
  Future<void> checkpoint() async {}
  @override
  Future<void> appLifecycleChanged(AppLifecycleState state) async {}
  @override
  Future<void> quiesce() async => quiesces++;
  @override
  Future<void> get idle async {}
}

void main() {
  test('a reset quiesces the listen recorder right after playback (SC-15)',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(localQuiescablesProvider).map((q) => q.quiesceName),
        ['playback', 'listens', 'history']);
  });

  test('the listens participant quiesces a built recorder and never builds '
      'one', () async {
    final recorder = _FakeRecorder();
    var builds = 0;
    final c = ProviderContainer(overrides: [
      listenRecorderProvider.overrideWith((ref) {
        builds++;
        return recorder;
      }),
    ]);
    addTearDown(c.dispose);
    Quiescable listens() => c
        .read(localQuiescablesProvider)
        .singleWhere((q) => q.quiesceName == 'listens');
    await listens().quiesce();
    expect(builds, 0, reason: 'nothing to stop: no recorder was built');
    c.listen(listenRecorderProvider, (_, _) {});
    await listens().quiesce();
    expect((builds, recorder.quiesces), (1, 1));
  });

  test('recording failures surface in the history diagnostics', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await seedTestBinding(db);
    final observations = StreamController<PlaybackObservation>.broadcast();
    addTearDown(observations.close);
    final clock = FakeClock();
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(clock),
      listenObservationsProvider.overrideWithValue(observations.stream),
      historyRepositoryProvider.overrideWith((ref) => _FailingHistory(db)),
    ]);
    addTearDown(c.dispose);
    final recorder = c.read(listenRecorderProvider);
    await recorder.start();
    for (var t = 0; t <= 2; t++) {
      clock.advance(Duration(seconds: t == 0 ? 0 : 1));
      observations.add(PlaybackObservation(
        runtimeId: 1, sequence: t + 1, playlistRevision: 1,
        source: const EngineSourceIdentity(
            sourceId: 1, sessionId: 1, itemId: 1, trackUuid: 't1'),
        position: Duration(seconds: t), duration: null, playing: true,
        processingState: EngineProcessingState.ready, transitionCause: null,
        rate: 1.0,
        uncertain: false));
      await pumpEventQueue();
      await recorder.idle;
    }
    expect(c.read(listenRecordingErrorProvider).value, contains('disk full'));
  });

  test('the playback issue bus is not a listen recording sink (SC-27: '
      'appliers only)', () {
    final source = File('lib/services/history/listen_recorder.dart')
        .readAsStringSync();
    expect(source, isNot(contains('playbackIssueBusProvider')));
  });
}

class _FailingHistory extends HistoryRepository {
  _FailingHistory(super.db);
  @override
  Future<void> checkpointDraft(String bindingToken, ListenDraft draft) async =>
      throw StateError('disk full');
}
