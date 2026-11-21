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

  // The answer that carried the 401 says who sent it (the server stamps
  // `X-Server-Instance-Id` on every answer, its 401s included).
  group('a 401 with its sender\'s stamp decides at once', () {
    test("the bound server's stamp: signed out at once, no identity read",
        () async {
      await verify();
      gate().checkAfterUnauthorized('http://s', servedBy: 'inst-1');
      expect(gate().state, isA<BindingSignedOut>());
      expect(gate().allowsTokenTo(Uri.parse('http://s/tracks')), isFalse);
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
    });

    test("another server's stamp: the different-server block at once, no "
        'identity read; the bound server answering later verifies again',
        () async {
      await verify();
      gate().checkAfterUnauthorized('http://s', servedBy: 'inst-2');
      expect(gate().state, isA<BindingDifferentServer>().having(
          (s) => s.serverInstanceId, 'serverInstanceId', 'inst-2'));
      expect(gate().allowsTokenTo(Uri.parse('http://s/tracks')), isFalse);
      expect(gate().maySendTokenTo('http://s'), isFalse);
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);

      unawaited(gate().startConnection('http://s'));
      await pumpEventQueue();
      controlled.respond('inst-1');
      await pumpEventQueue();
      expect(gate().state, isA<BindingVerified>());
    });

    test("a stamped 401 decides even while an unstamped one's read is out",
        () async {
      await verify();
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      gate().checkAfterUnauthorized('http://s', servedBy: 'inst-2');
      expect(gate().state, isA<BindingDifferentServer>());
      controlled.respond('inst-1'); // the dropped read
      await pumpEventQueue();
      expect(gate().state, isA<BindingDifferentServer>());
    });
  });

  group('a 401: the identity read decides', () {
    test('the token is withheld at once and the identity is read again',
        () async {
      await verify();
      gate().checkAfterUnauthorized('http://s');
      expect(gate().state, isA<BindingUnverified>().having(
          (s) => s.error, 'error', isA<TokenRefusedByServer>()),
          reason: 'a failed check at once: playback releases the sources '
              'ahead, streams count as unavailable');
      expect(gate().isVerifiedNow, isFalse);
      expect(gate().allowsTokenTo(Uri.parse('http://s/tracks')), isFalse);
      expect(gate().maySendTokenTo('http://s'), isFalse);
      await pumpEventQueue();
      expect(controlled.pendingProbes, 1);
      expect(controlled.probedUrls.last, 'http://s');
      expect(gate().state, isA<BindingVerifying>());
      expect(gate().lastVerdictFailed, isTrue,
          reason: 'streams stay unavailable while the identity is read');
      controlled.respond('inst-1');
      await pumpEventQueue();
    });

    test('the bound server answering: signed out, never verified on the way',
        () async {
      await verify();
      final states = <BindingGateState>[];
      final sub = gate().states.listen(states.add);
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      controlled.respond('inst-1');
      await pumpEventQueue();
      expect(gate().state, isA<BindingSignedOut>());
      expect(states.whereType<BindingVerified>(), isEmpty);
      await sub.cancel();
    });

    test('another server answering: a different server, not signed out; the '
        'bound server answering later verifies again', () async {
      await verify();
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      controlled.respond('inst-2');
      await pumpEventQueue();
      expect(gate().state, isA<BindingDifferentServer>());

      unawaited(gate().startConnection('http://s'));
      await pumpEventQueue();
      controlled.respond('inst-1');
      await pumpEventQueue();
      expect(gate().state, isA<BindingVerified>());
      expect(gate().isVerifiedNow, isTrue);
    });

    test('no stamp, and the identity read fails: the 401 is dropped, the '
        'token stays withheld, and the bound server answering next is '
        'verified, not signed out', () async {
      final retries = <void Function()>[];
      final timers = <Timer>[];
      addTearDown(() {
        for (final t in timers) {
          t.cancel();
        }
      });
      controlled.dispose();
      controlled = ControlledGate(db, timer: (d, f) {
        retries.add(f);
        final t = Timer(const Duration(days: 1), () {});
        timers.add(t);
        return t;
      });
      await verify();
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      controlled.fail(StateError('unreachable'));
      await pumpEventQueue();
      expect(gate().state, isA<BindingUnverified>());
      expect(gate().isVerifiedNow, isFalse);

      retries.single();
      await pumpEventQueue();
      controlled.respond('inst-1');
      await pumpEventQueue();
      expect(gate().state, isA<BindingVerified>(),
          reason: 'who sent the 401 is unknown: the next verified contact '
              'decides, and a revoked token gets a fresh 401 there');
    });

    test('no stamp: a recovery edge while the identity read is out; the '
        'bound server answering it is signed out, never verified', () async {
      await verify();
      final states = <BindingGateState>[];
      final sub = gate().states.listen(states.add);
      addTearDown(sub.cancel);
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      unawaited(gate().startConnection('http://s')); // the app to the front
      await pumpEventQueue();
      controlled.respond('inst-1'); // the dropped first read
      await pumpEventQueue();
      controlled.respond('inst-1'); // the edge's read
      await pumpEventQueue();
      expect(gate().state, isA<BindingSignedOut>());
      expect(states.whereType<BindingVerified>(), isEmpty);
      expect(gate().allowsTokenTo(Uri.parse('http://s/tracks')), isFalse);
    });

    test('a second 401 while the read is out reads once', () async {
      await verify();
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      expect(controlled.pendingProbes, 1);
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      expect(controlled.pendingProbes, 1);
      controlled.respond('inst-1');
      await pumpEventQueue();
    });

    test('a late 401 after a different-server verdict, while a recovery '
        'edge checks again, is ignored: the bound server then verifies',
        () async {
      await verify();
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      controlled.respond('inst-2');
      await pumpEventQueue();
      expect(gate().state, isA<BindingDifferentServer>());

      unawaited(gate().startConnection('http://s')); // the recovery edge
      await pumpEventQueue();
      expect(gate().state, isA<BindingVerifying>());
      gate().checkAfterUnauthorized('http://s'); // a request from before
      await pumpEventQueue();
      expect(controlled.pendingProbes, 1, reason: "only the edge's read");
      controlled.respond('inst-1');
      await pumpEventQueue();
      expect(gate().state, isA<BindingVerified>());
    });

    test('a late 401 after a different-server verdict is ignored even when '
        'a later check failed: no token has gone out since', () async {
      await verify();
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      controlled.respond('inst-2');
      await pumpEventQueue();
      unawaited(gate().startConnection('http://s')); // a recovery edge
      await pumpEventQueue();
      controlled.fail(StateError('unreachable'));
      await pumpEventQueue();
      expect(gate().state, isA<BindingUnverified>());

      gate().checkAfterUnauthorized('http://s'); // a request from before
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
      expect(gate().state, isA<BindingUnverified>());
    });

    test('ignored during a different-server block and once signed out',
        () async {
      unawaited(gate().startConnection('http://s'));
      await pumpEventQueue();
      controlled.respond('inst-2');
      await pumpEventQueue();
      expect(gate().state, isA<BindingDifferentServer>());
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
      expect(gate().state, isA<BindingDifferentServer>());

      gate().closeSignedOut();
      gate().checkAfterUnauthorized('http://s');
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
      expect(gate().state, isA<BindingSignedOut>());
    });
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
