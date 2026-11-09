// SC-13 (5-U05): SingleFlightRunner — one pass at a time across triggers,
// coalesced reruns, budgeted passes that yield, backoff-paced retries that
// recovery edges may bypass, failures that never escape, and quiesce.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';

class _Timers {
  final scheduled = <({Duration delay, void Function() fire, bool Function() active})>[];
  Timer call(Duration delay, void Function() fire) {
    final t = _FakeTimer();
    scheduled.add((delay: delay, fire: fire, active: () => t.isActive));
    return t;
  }

  void fireLast() {
    final last = scheduled.last;
    expect(last.active(), isTrue, reason: 'the retry timer is still pending');
    last.fire();
  }
}

class _FakeTimer implements Timer {
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
  late List<Set<String>> passes;
  late List<Completer<PassOutcome>> pending;
  late int running;
  late int maxRunning;
  late SingleFlightRunner runner;

  SingleFlightRunner make() => SingleFlightRunner(
    name: 'test',
    backoff: BackoffSchedule(jitter: 0),
    timer: timers.call,
    pass: (reasons) async {
      passes.add({...reasons});
      running++;
      if (running > maxRunning) maxRunning = running;
      final c = Completer<PassOutcome>();
      pending.add(c);
      try {
        return await c.future;
      } finally {
        running--;
      }
    },
  );

  setUp(() {
    timers = _Timers();
    passes = [];
    pending = [];
    running = 0;
    maxRunning = 0;
    runner = make();
  });

  Future<void> settle() => pumpEventQueue();

  test('a request runs one pass with its reason', () async {
    runner.request('coldStart');
    await settle();
    expect(passes, [
      {'coldStart'},
    ]);
    expect(runner.isRunning, isTrue);
    pending.single.complete(const PassDone());
    await settle();
    expect(runner.isRunning, isFalse);
  });

  test('requests during a pass coalesce into exactly one rerun', () async {
    runner.request('timer');
    await settle();
    runner.request('localInsert');
    runner.request('networkRecovered');
    runner.request('localInsert');
    await settle();
    expect(passes, hasLength(1));
    pending[0].complete(const PassDone());
    await settle();
    expect(passes, hasLength(2));
    expect(passes[1], {'localInsert', 'networkRecovered'});
    pending[1].complete(const PassDone());
    await settle();
    expect(passes, hasLength(2));
    expect(maxRunning, 1, reason: 'never two passes at once');
  });

  test('a pass that used its budget runs again without a timer', () async {
    runner.request('timer');
    await settle();
    pending[0].complete(const PassMoreWork());
    await settle();
    expect(passes, hasLength(2));
    expect(timers.scheduled, isEmpty);
    pending[1].complete(const PassDone());
    await settle();
    expect(passes, hasLength(2));
  });

  test('failures back off on the ladder; success resets it', () async {
    runner.request('timer');
    await settle();
    pending[0].complete(const PassFailed(BackoffReason.transient));
    await settle();
    expect(timers.scheduled.single.delay, const Duration(seconds: 1));
    expect(passes, hasLength(1));
    timers.fireLast();
    await settle();
    expect(passes, hasLength(2));
    pending[1].complete(const PassFailed(BackoffReason.transient));
    await settle();
    expect(timers.scheduled.last.delay, const Duration(seconds: 2));
    timers.fireLast();
    await settle();
    pending[2].complete(const PassDone());
    await settle();
    runner.request('timer');
    await settle();
    pending[3].complete(const PassFailed(BackoffReason.transient));
    await settle();
    expect(timers.scheduled.last.delay, const Duration(seconds: 1), reason: 'reset');
  });

  test('a Retry-After floor and the non-ladder waits are used', () async {
    runner.request('timer');
    await settle();
    pending[0].complete(const PassFailed(
      BackoffReason.transient,
      retryAfter: Duration(seconds: 20),
    ));
    await settle();
    expect(timers.scheduled.last.delay, const Duration(seconds: 20));
    timers.fireLast();
    await settle();
    pending[1].complete(const PassFailed(BackoffReason.capabilityMissing));
    await settle();
    expect(timers.scheduled.last.delay, BackoffSchedule.defaultCapabilityWait);
  });

  test('a request during backoff waits for the retry; a recovery edge does not',
      () async {
    runner.request('timer');
    await settle();
    pending[0].complete(const PassFailed(BackoffReason.transient));
    await settle();
    runner.request('localInsert');
    await settle();
    expect(passes, hasLength(1), reason: 'no busy loop on local writes');
    runner.request('networkRecovered', bypassBackoff: true);
    await settle();
    expect(passes, hasLength(2));
    expect(passes[1], {'localInsert', 'networkRecovered'});
    expect(timers.scheduled.single.active(), isFalse, reason: 'retry cancelled');
  });

  // Audit 5A(a) #3: a "sync now" made while a pass runs must survive that
  // pass failing.
  test('a bypass request during a pass that then fails reruns at once',
      () async {
    runner.request('poll');
    await settle();
    runner.request('keepServerVersion', bypassBackoff: true);
    pending[0].complete(const PassFailed(BackoffReason.permanent));
    await settle();
    expect(passes, hasLength(2), reason: 'not parked behind the backoff');
    expect(passes[1], {'keepServerVersion'});
  });

  test('a throwing pass is a transient failure, never an escaped error',
      () async {
    final throwing = SingleFlightRunner(
      name: 'boom',
      backoff: BackoffSchedule(jitter: 0),
      timer: timers.call,
      pass: (_) async => throw StateError('pass bug'),
    );
    throwing.request('timer');
    await settle();
    expect(timers.scheduled.single.delay, const Duration(seconds: 1));
    expect(throwing.isRunning, isFalse);
  });

  test('whenIdle completes once nothing runs or is queued', () async {
    runner.request('timer');
    await settle();
    runner.request('again');
    var idle = false;
    unawaited(runner.whenIdle().then((_) => idle = true));
    pending[0].complete(const PassDone());
    await settle();
    expect(idle, isFalse, reason: 'the coalesced rerun is still due');
    pending[1].complete(const PassDone());
    await settle();
    expect(idle, isTrue);
  });

  test('quiesce waits for the pass in flight, then nothing runs', () async {
    runner.request('timer');
    await settle();
    runner.request('queued');
    var quiesced = false;
    unawaited(runner.quiesce().then((_) => quiesced = true));
    await settle();
    expect(quiesced, isFalse);
    pending[0].complete(const PassDone());
    await settle();
    expect(quiesced, isTrue);
    expect(passes, hasLength(1), reason: 'the queued rerun is dropped');
    runner.request('late', bypassBackoff: true);
    await settle();
    expect(passes, hasLength(1));
    await runner.quiesce(); // idempotent
  });

  test('quiesce cancels a pending backoff retry', () async {
    runner.request('timer');
    await settle();
    pending[0].complete(const PassFailed(BackoffReason.transient));
    await settle();
    await runner.quiesce();
    expect(timers.scheduled.single.active(), isFalse);
  });
}
