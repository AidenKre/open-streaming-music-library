// Phase M §7.7 / SC-13 Phase M (M-U24): the signed-out reason CLOSES the
// binding gate, so every runner stops at `awaitVerified` without per-runner
// 401 logic. Closed for signed-out:
//  * the verified token is dropped: awaiters (old and new) wait, never error
//    (a wait, not a failure), until the scope's gate is disposed;
//  * no later connection verifies again (recovery edges call
//    startConnection), and a probe in flight when it closed is dropped;
//  * only the scope rebuild (a new gate) clears it.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/server_binding_gate.dart';

import '../helpers/server_binding.dart';

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  ServerBindingGate gate() => controlled.gate;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
    controlled = ControlledGate(db);
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
  });

  Future<void> verify() async {
    unawaited(gate().startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond('inst-1');
    await pumpEventQueue();
    expect(gate().state, isA<BindingVerified>());
  }

  test('closing for signed-out drops the verified token: awaiters wait',
      () async {
    await verify();
    gate().closeSignedOut();
    expect(gate().state, isA<BindingSignedOut>());

    var completed = false;
    Object? error;
    unawaited(gate().awaitVerified().then(
      (_) => completed = true,
      onError: (Object e) => error = e,
    ));
    await pumpEventQueue();
    expect(completed, isFalse, reason: 'a closed gate never hands out a token');
    expect(error, isNull, reason: 'a 401 is a wait, never a failure');
  });

  test('publishes the signed-out state on the stream', () async {
    await verify();
    final states = <BindingGateState>[];
    final sub = gate().states.listen(states.add);
    gate().closeSignedOut();
    await pumpEventQueue();
    expect(states.single, isA<BindingSignedOut>());
    await sub.cancel();
  });

  test('a later connection never verifies again: no probe, still closed',
      () async {
    await verify();
    gate().closeSignedOut();
    final probesBefore = controlled.probedUrls.length;

    unawaited(gate().startConnection('http://s'));
    await pumpEventQueue();
    expect(controlled.probedUrls.length, probesBefore,
        reason: 'a recovery edge must not send another request');
    expect(gate().state, isA<BindingSignedOut>());
  });

  test('a probe in flight when it closed is dropped', () async {
    unawaited(gate().startConnection('http://s'));
    await pumpEventQueue();
    expect(controlled.pendingProbes, 1);
    gate().closeSignedOut();

    controlled.respond('inst-1');
    await pumpEventQueue();
    expect(gate().state, isA<BindingSignedOut>(),
        reason: 'a late verdict cannot reopen the gate');
    var completed = false;
    unawaited(gate().awaitVerified().then(
      (_) => completed = true,
      onError: (Object _) {}, // the tearDown dispose ends the wait
    ));
    await pumpEventQueue();
    expect(completed, isFalse);
  });

  test('a waiter from before the close keeps waiting', () async {
    var completed = false;
    Object? error;
    unawaited(gate().awaitVerified().then(
      (_) => completed = true,
      onError: (Object e) => error = e,
    ));
    gate().closeSignedOut();
    unawaited(gate().startConnection('http://s'));
    await pumpEventQueue();
    expect(controlled.pendingProbes, 0);
    expect(completed, isFalse);
    expect(error, isNull);
  });

  test('disposing the scope still ends the wait (the rebuild)', () async {
    await verify();
    gate().closeSignedOut();
    Object? error;
    unawaited(gate().awaitVerified().then((_) {}, onError: (Object e) {
      error = e;
    }));
    gate().dispose();
    await pumpEventQueue();
    expect(error, isA<BindingGateClosedException>());
  });

  test('closing is idempotent and a no-op after dispose', () async {
    await verify();
    gate().closeSignedOut();
    gate().closeSignedOut();
    expect(gate().state, isA<BindingSignedOut>());
    gate().dispose();
    expect(() => gate().closeSignedOut(), returnsNormally);
  });
}
