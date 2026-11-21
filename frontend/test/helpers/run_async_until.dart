import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Real event-loop turns, each followed by a frame, until [condition] holds:
/// a wait on a condition, not on a count of turns. Drift on an in-memory
/// database needs real turns, which `testWidgets`' fake time does not give.
/// [condition] runs in real async, so it may read the database; a finder in
/// it sees the last frame. Fails with [reason] if the condition never holds
/// within [maxTurns].
Future<void> runAsyncUntil(
  WidgetTester tester,
  FutureOr<bool> Function() condition, {
  required String reason,
  int maxTurns = 500,
}) async {
  for (var i = 0; i < maxTurns; i++) {
    final done = await tester.runAsync(() async {
      await pumpEventQueue(times: 1);
      return condition();
    });
    await tester.pump();
    if (done == true) return;
  }
  fail('Waited $maxTurns event-loop turns for: $reason');
}

/// For a plain test: event-loop turns until [done] holds, at most
/// [maxTurns]; fails with [reason] if it never does, instead of hanging
/// until the test's timeout.
Future<void> turnsUntil(
  bool Function() done, {
  required String reason,
  int maxTurns = 1000,
}) async {
  for (var i = 0; i < maxTurns && !done(); i++) {
    await pumpEventQueue(times: 1);
  }
  expect(done(), isTrue,
      reason: 'Waited $maxTurns event-loop turns for: $reason');
}

/// [future]'s result, waited for at most [maxTurns] event-loop turns; fails
/// with [reason] if it has not completed by then. An error it completes
/// with is rethrown.
Future<T> withinTurns<T>(
  Future<T> future, {
  required String reason,
  int maxTurns = 1000,
}) async {
  var done = false;
  T? value;
  Object? error;
  StackTrace? stack;
  future.then((v) {
    value = v;
    done = true;
  }, onError: (Object e, StackTrace s) {
    error = e;
    stack = s;
    done = true;
  });
  await turnsUntil(() => done, reason: reason, maxTurns: maxTurns);
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value as T;
}
