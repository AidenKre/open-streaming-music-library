import 'dart:ui' show AppLifecycleState;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/services/app_lifecycle_service.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/history/history_sync_triggers.dart';
import 'package:frontend/services/history/listen_recorder.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';

class _Triggers extends HistorySyncTriggers {
  _Triggers() : super(request: (_) {});
  final foreground = <bool>[];
  @override
  void setForeground(bool value) => foreground.add(value);
}

class _Recovery extends RecoveryService {
  _Recovery(super.ref);
  final runs = <RecoveryTrigger>[];
  @override
  Future<void> runFor(RecoveryTrigger trigger) async => runs.add(trigger);
}

class _Recorder implements ListenRecorder {
  final states = <AppLifecycleState>[];
  @override
  Future<void> appLifecycleChanged(AppLifecycleState state) async =>
      states.add(state);
  @override
  Future<void> start() async {}
  @override
  Future<void> checkpoint() async {}
  @override
  Future<void> quiesce() async {}
  @override
  Future<void> get idle async {}
}

void main() {
  late _Triggers triggers;
  late _Recovery recovery;
  late _Recorder recorder;
  var recorderBuilds = 0;

  ProviderContainer scope() {
    triggers = _Triggers();
    recorder = _Recorder();
    recorderBuilds = 0;
    final c = ProviderContainer(overrides: [
      historySyncTriggersProvider.overrideWithValue(triggers),
      recoveryServiceProvider.overrideWith((ref) => recovery = _Recovery(ref)),
      listenRecorderProvider.overrideWith((ref) {
        recorderBuilds++;
        return recorder;
      }),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('resume: foreground, app-resume recovery, and the recorder hears it',
      () {
    final c = scope();
    c.listen(listenRecorderProvider, (_, _) {}); // started by the wiring
    c.read(appLifecycleServiceProvider).changed(AppLifecycleState.resumed);
    expect(triggers.foreground, [true]);
    expect(recovery.runs, [RecoveryTrigger.appResume]);
    expect(recorder.states, [AppLifecycleState.resumed]);
  });

  test('background: not foreground, no recovery; the recorder checkpoints',
      () {
    final c = scope();
    c.read(recoveryServiceProvider);
    c.listen(listenRecorderProvider, (_, _) {});
    c.read(appLifecycleServiceProvider).changed(AppLifecycleState.paused);
    expect(triggers.foreground, [false]);
    expect(recovery.runs, isEmpty);
    expect(recorder.states, [AppLifecycleState.paused]);
  });

  test('a recorder is never built by a lifecycle change', () {
    final c = scope();
    c.read(appLifecycleServiceProvider).changed(AppLifecycleState.hidden);
    expect(recorderBuilds, 0);
  });

  for (final state in AppLifecycleState.values) {
    test('${state.name}: history polls only when resumed; the recorder hears '
        'every state', () {
      final c = scope();
      c.read(recoveryServiceProvider);
      c.listen(listenRecorderProvider, (_, _) {});
      c.read(appLifecycleServiceProvider).changed(state);
      expect(triggers.foreground, [state == AppLifecycleState.resumed]);
      expect(recovery.runs,
          state == AppLifecycleState.resumed ? [RecoveryTrigger.appResume] : []);
      expect(recorder.states, [state]);
    });
  }
}
