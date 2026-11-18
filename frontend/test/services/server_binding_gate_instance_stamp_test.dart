// Phase 7B.1a (SC-01 rule 6 → rule 1's different-server flow): a page
// stamped by another instance is reported to the binding gate, which then
// blocks exactly as when its own probe finds a different server:
//  * while the current connection is verified with the reporting run's
//    connection (`verifiedConnection`, captured when the run started) →
//    BindingDifferentServer, the token may no longer be sent,
//    awaitVerified waits again;
//  * a report from an older connection (even one of the same binding, whose
//    token is the same local_binding_id), during a new connection's
//    verification, after sign-out or disposal is dropped: whatever already
//    took over decides;
//  * the next connection whose probe finds the bound instance verifies
//    again (D14: the bound server answering clears the block).
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';

import '../helpers/server_binding.dart';

const _bound = '3f1c2a9e-7b4d-4e2a-9c1f-0a1b2c3d4e5f';
const _other = '9d8e7f6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a';
const _url = 'http://test';

ServerInstanceChangedException _changed() =>
    ServerInstanceChangedException(boundInstanceId: _bound, servedBy: _other);

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late ServerBindingGate gate;
  late List<BindingGateState> states;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: _url, instanceId: _bound);
    controlled = ControlledGate(db);
    gate = controlled.gate;
    states = [];
    gate.states.listen(states.add);
  });
  tearDown(() async {
    controlled.dispose();
    await db.close();
  });

  late int connection;

  Future<void> verify() async {
    final done = gate.startConnection(_url);
    await pumpEventQueue();
    controlled.respond(_bound);
    await done;
    expect(gate.state, isA<BindingVerified>());
    connection = gate.verifiedConnection!;
  }

  test('a verified connection blocks as a different server', () async {
    await verify();

    gate.reportDifferentInstance(connection, _changed());
    await pumpEventQueue();

    expect(
      gate.state,
      isA<BindingDifferentServer>()
          .having((s) => s.boundInstanceId, 'bound', _bound)
          .having((s) => s.serverInstanceId, 'server', _other),
    );
    expect(states.last, isA<BindingDifferentServer>());
    expect(gate.maySendTokenTo(_url), isFalse);
    var released = false;
    unawaited(gate
        .awaitVerified()
        .then((_) => released = true)
        .catchError((Object _) => false)); // the tearDown disposal
    await pumpEventQueue();
    expect(released, isFalse, reason: 'runners wait for a new verdict');
  });

  test('the bound server answering on the next connection clears it',
      () async {
    await verify();
    gate.reportDifferentInstance(connection, _changed());
    await pumpEventQueue();

    await verify();
    expect(gate.maySendTokenTo(_url), isTrue);
  });

  test('a report from an earlier connection is dropped once a newer one '
      'verified (review 7B.1a #2)', () async {
    await verify();
    final first = connection;
    await verify(); // an appResume edge re-verified the bound server
    expect(connection, isNot(first));

    gate.reportDifferentInstance(first, _changed());
    await pumpEventQueue();

    expect(gate.state, isA<BindingVerified>());
    expect(gate.maySendTokenTo(_url), isTrue);
  });

  test('there is no verified connection to capture unless verified', () async {
    expect(gate.verifiedConnection, isNull);
    await verify();
    expect(gate.verifiedConnection, isNotNull);
    gate.reportDifferentInstance(connection, _changed());
    expect(gate.verifiedConnection, isNull);
  });

  test('a report while a new connection is verifying is dropped; that '
      "connection's verdict decides", () async {
    await verify();
    final done = gate.startConnection(_url);
    await pumpEventQueue();
    expect(gate.state, isA<BindingVerifying>());

    gate.reportDifferentInstance(connection, _changed());
    await pumpEventQueue();
    expect(gate.state, isA<BindingVerifying>());

    controlled.respond(_bound);
    await done;
    expect(gate.state, isA<BindingVerified>());
  });

  test('after sign-out or disposal a report changes nothing', () async {
    await verify();
    gate.closeSignedOut();
    gate.reportDifferentInstance(connection, _changed());
    await pumpEventQueue();
    expect(gate.state, isA<BindingSignedOut>());

    gate.dispose();
    gate.reportDifferentInstance(connection, _changed()); // must not throw
  });
}
