// Refactor A.3 slice 1, characterization: how long a user's own action
// waits for the server check (`BindingWait.forPendingVerdict`).
//
// It waits exactly `ServerBindingGate.tokenWaitBound` and no longer, as ONE
// wait: a failed check that is being retried neither ends the wait nor
// starts the bound again. A verdict inside the bound ends it at once: a
// verified one sends, a different server refuses. Fake time; the gate's own
// retry timers never fire here (only its wait bound passes through).
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/server_binding_gate.dart';

import '../helpers/server_binding.dart';
import '../helpers/stamped_server.dart';

const _bound = ServerBindingGate.tokenWaitBound;
const _tick = Duration(milliseconds: 1);
final _url = Uri.parse('http://s');

void main() {
  late AppDatabase db;
  late ServerBindingGate gate;
  late List<Completer<ServerIdentity>> probes;
  late int sent;
  late bool done;
  late Object? error;

  /// Real async (the database): call inside `tester.runAsync`.
  Future<void> openRig() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: boundInstance);
    probes = [];
    gate = ServerBindingGate(
      repository: ServerBindingRepository(db),
      signedInUserId: testUserId,
      probe: ({required String baseUrl, required bool reportOffline}) {
        final c = Completer<ServerIdentity>();
        probes.add(c);
        return c.future;
      },
      backoff: BackoffSchedule(jitter: 0),
      // The wait bound runs on the test's (fake) time; a retry never fires.
      timer: boundOnlyGateTimer,
    );
    sent = 0;
    done = false;
    error = null;
  }

  Future<void> closeRig() async {
    gate.dispose();
    await db.close();
  }

  /// A user's own action, started now; how it ends is recorded.
  void act() {
    unawaited(
      sendWhenVerified<void>(
        gate,
        () async => sent++,
        wait: BindingWait.forPendingVerdict,
        url: _url,
      ).then<void>(
        (_) => done = true,
        onError: (Object e) {
          error = e;
          done = true;
        },
      ),
    );
  }

  Matcher refused(BindingRefusal why) =>
      isA<BindingNotVerified>().having((e) => e.reason, 'reason', why);

  testWidgets('a pending check: the action waits exactly the gate\'s bound, '
      'then is refused; nothing is sent, not even when the check passes later',
      (tester) async {
    await tester.runAsync(() async {
      await openRig();
      unawaited(gate.startConnection('http://s'));
      await pumpEventQueue();
      expect(gate.state, isA<BindingVerifying>());
    });
    act();
    await tester.pump(_bound - _tick);
    expect(done, isFalse, reason: 'one millisecond before the bound');

    await tester.pump(_tick);
    expect(done, isTrue, reason: 'at the bound');
    expect(error, refused(BindingRefusal.notYet));
    expect(sent, 0);

    await tester.runAsync(() async {
      probes.single.complete(const ServerIdentity(boundInstance));
      await pumpEventQueue();
      expect(gate.state, isA<BindingVerified>());
    });
    await tester.pump();
    expect(sent, 0, reason: 'a refused action stays refused');
    await tester.runAsync(closeRig);
  });

  testWidgets('no check started yet: the same bound, no longer',
      (tester) async {
    await tester.runAsync(openRig);
    expect(gate.state, isA<BindingIdle>());
    act();
    await tester.pump(_bound - _tick);
    expect(done, isFalse);

    await tester.pump(_tick);
    expect(error, refused(BindingRefusal.notYet));
    expect(sent, 0);
    await tester.runAsync(closeRig);
  });

  testWidgets('a failed check that is retried keeps the action waiting, and '
      'the bound is not started again: one wait, the bound in total',
      (tester) async {
    await tester.runAsync(() async {
      await openRig();
      unawaited(gate.startConnection('http://s'));
      await pumpEventQueue();
    });
    act();
    await tester.pump(const Duration(seconds: 4));
    await tester.runAsync(() async {
      probes.single.completeError(StateError('probe failed'));
      await pumpEventQueue();
      expect(gate.state, isA<BindingUnverified>());
    });
    await tester.pump();
    expect(done, isFalse, reason: 'a failed check does not end the wait');

    await tester.pump(_bound - const Duration(seconds: 4) - _tick);
    expect(done, isFalse, reason: 'one millisecond before the bound');
    await tester.pump(_tick);
    expect(done, isTrue, reason: 'the bound counts from the start of the wait');
    expect(error, refused(BindingRefusal.notYet));
    expect(sent, 0);
    await tester.runAsync(closeRig);
  });

  testWidgets('the check passing inside the bound sends at once, once',
      (tester) async {
    await tester.runAsync(() async {
      await openRig();
      unawaited(gate.startConnection('http://s'));
      await pumpEventQueue();
    });
    act();
    await tester.pump(const Duration(seconds: 4));
    expect(sent, 0);
    await tester.runAsync(() async {
      probes.single.complete(const ServerIdentity(boundInstance));
      await pumpEventQueue();
    });
    await tester.pump();
    expect(done, isTrue);
    expect(error, isNull);
    expect(sent, 1);

    // Nothing is left running: the bound passing later changes nothing.
    await tester.pump(_bound);
    expect(sent, 1);
    await tester.runAsync(closeRig);
  });

  testWidgets('a different server answering inside the bound refuses at once',
      (tester) async {
    await tester.runAsync(() async {
      await openRig();
      unawaited(gate.startConnection('http://s'));
      await pumpEventQueue();
    });
    act();
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(() async {
      probes.single.complete(const ServerIdentity(otherInstance));
      await pumpEventQueue();
      expect(gate.state, isA<BindingDifferentServer>());
    });
    await tester.pump();
    expect(done, isTrue, reason: 'not at the bound: at the verdict');
    expect(error, refused(BindingRefusal.differentServer));
    expect(sent, 0);
    await tester.runAsync(closeRig);
  });
}
