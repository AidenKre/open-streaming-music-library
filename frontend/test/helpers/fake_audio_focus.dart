import 'dart:async';

import 'package:frontend/playback/audio_focus.dart';

class FakeAudioSessionPort implements AudioSessionPort {
  final controller = StreamController<AudioSessionEvent>.broadcast();
  int listens = 0;

  @override
  Stream<AudioSessionEvent> get events {
    listens++;
    return controller.stream;
  }

  void emit(AudioSessionEvent event) => controller.add(event);
}

/// A focus owner whose relinquish the test acknowledges.
class RelinquishingOwner
    implements AudioFocusOwner, FocusRelinquisher, FocusReturnListener {
  RelinquishingOwner(this.name);
  final String name;
  final calls = <String>[];
  int relinquishes = 0;

  /// How often the output came back unused ([AudioFocus.handBack]).
  int returns = 0;

  @override
  void onFocusReturned() => returns++;
  Completer<void>? _ack;

  @override
  Future<void> relinquishFocus() {
    relinquishes++;
    return (_ack ??= Completer<void>()).future;
  }

  void acknowledge() {
    _ack?.complete();
    _ack = null;
  }

  void fail(Object error) {
    _ack?.completeError(error);
    _ack = null;
  }

  @override
  void onInterruptionBegan() => calls.add('began');

  @override
  void onInterruptionEnded({required bool shouldResume}) =>
      calls.add('ended(resume: $shouldResume)');

  @override
  void onBecameNoisy() => calls.add('noisy');
}

/// Timers the test fires by hand (no wall clock).
class FakeTimers {
  final _timers = <_FakeTimer>[];

  Timer create(Duration duration, void Function() callback) {
    final timer = _FakeTimer(duration, callback);
    _timers.add(timer);
    return timer;
  }

  List<(Duration, Timer)> get pending =>
      [for (final t in _timers) if (t.isActive) (t.duration, t)];

  List<Timer> get active => [for (final t in _timers) if (t.isActive) t];

  void fireAll() {
    for (final t in List.of(_timers)) {
      t.fire();
    }
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this._callback);
  final Duration duration;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
