// Phase 5 §5: "After local insert schedule a bounded debounce flush (1
// second); while foreground/online poll history every 30 seconds for other
// devices. … while offline suspend network timers without deleting data."
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/history/history_sync_triggers.dart';

class _Timers {
  final all = <({Duration delay, void Function() fire, _T timer})>[];
  Timer call(Duration delay, void Function() fire) {
    final t = _T();
    all.add((delay: delay, fire: fire, timer: t));
    return t;
  }

  List<({Duration delay, void Function() fire, _T timer})> get active =>
      [for (final t in all) if (t.timer.isActive) t];
}

class _T implements Timer {
  bool _active = true;
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

void main() {
  late _Timers timers;
  late List<String> requests;
  late HistorySyncTriggers triggers;

  setUp(() {
    timers = _Timers();
    requests = [];
    triggers = HistorySyncTriggers(request: requests.add, timer: timers.call);
  });

  test('local inserts are debounced into one request after 1 s', () {
    triggers.localInsert();
    triggers.localInsert();
    triggers.localInsert();
    expect(timers.active, hasLength(1));
    expect(timers.active.single.delay, const Duration(seconds: 1));
    timers.active.single.fire();
    expect(requests, ['localInsert']);
  });

  test('polls every 30 s only while foreground and online', () {
    triggers.setForeground(true);
    expect(triggers.isPolling, isFalse, reason: 'not online yet');
    triggers.setOnline(true);
    expect(triggers.isPolling, isTrue);
    final poll = timers.active.single;
    expect(poll.delay, const Duration(seconds: 30));
    poll.timer.cancel(); // a one-shot that fired
    poll.fire();
    expect(requests, ['poll']);
    expect(triggers.isPolling, isTrue, reason: 're-armed');

    triggers.setOnline(false);
    expect(triggers.isPolling, isFalse, reason: 'offline suspends the poll');
    expect(timers.active, isEmpty);
    triggers.setOnline(true);
    expect(triggers.isPolling, isTrue);
    triggers.setForeground(false);
    expect(triggers.isPolling, isFalse, reason: 'backgrounded');
  });

  test('a poll that fires after the app went offline requests nothing', () {
    triggers.setForeground(true);
    triggers.setOnline(true);
    final poll = timers.active.single;
    triggers.setOnline(false);
    poll.fire(); // a stale callback racing the cancel
    expect(requests, isEmpty);
  });

  test('dispose cancels every timer; later calls do nothing', () {
    triggers.setForeground(true);
    triggers.setOnline(true);
    triggers.localInsert();
    triggers.dispose();
    expect(timers.active, isEmpty);
    triggers.localInsert();
    triggers.setOnline(true);
    expect(timers.active, isEmpty);
    expect(triggers.isPolling, isFalse);
  });
}
