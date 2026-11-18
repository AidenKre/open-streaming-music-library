// Other-issues row 72 as decided on 2026-11-18: the two page reads of the
// upload item pages ("Files in this archive"; the review page's read of a
// batch) wait for a server check like a person's own action: within the
// gate's one bound (`ServerBindingGate.tokenWaitBound`), never longer.
//
// Fake time: one millisecond before the bound the read still waits; at the
// bound it fails as "not verified" and nothing was sent, not even when the
// check passes later. The gate's own retry timers never fire here.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/uploads/upload_zip_children.dart';
import 'package:http/http.dart' as http;

import '../../helpers/server_binding.dart';
import '../../helpers/stamped_server.dart';

const _bound = ServerBindingGate.tokenWaitBound;
const _tick = Duration(milliseconds: 1);
const _batch = '22222222-2222-4222-8222-222222222222';

/// Counts what reaches the wire; never answers (nothing may reach it here).
class _Wire extends http.BaseClient {
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    return Completer<http.StreamedResponse>().future;
  }
}

void main() {
  late AppDatabase db;
  late ServerBindingGate gate;
  late List<Completer<ServerIdentity>> probes;
  late _Wire wire;
  late UploadsApi api;
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
      timer: boundOnlyGateTimer,
    );
    wire = _Wire();
    api = UploadsApi(api: testApiClient('http://s', wire), gate: gate);
    done = false;
    error = null;
  }

  Future<void> closeRig() async {
    gate.dispose();
    await db.close();
  }

  void watch(Future<Object?> read) {
    unawaited(read.then<void>(
      (_) => done = true,
      onError: (Object e) {
        error = e;
        done = true;
      },
    ));
  }

  final notYet = isA<BindingNotVerified>()
      .having((e) => e.reason, 'reason', BindingRefusal.notYet);

  final reads = <String, Future<Object?> Function()>{
    'Files in this archive': () =>
        UploadZipChildren(api).load(_batch, 'zip'),
    "the review page's read (listItems as a person's own action)": () =>
        api.listItems(_batch, wait: BindingWait.forPendingVerdict),
  };

  for (final MapEntry(key: name, value: read) in reads.entries) {
    testWidgets('$name: a check that does not pass within the bound fails '
        'at the bound, not later; nothing sent', (tester) async {
      await tester.runAsync(() async {
        await openRig();
        unawaited(gate.startConnection('http://s'));
        await pumpEventQueue();
        expect(gate.state, isA<BindingVerifying>());
      });
      watch(read());
      await tester.pump(_bound - _tick);
      expect(done, isFalse, reason: 'one millisecond before the bound');

      await tester.pump(_tick);
      expect(done, isTrue, reason: 'at the bound');
      expect(error, notYet);
      expect(wire.requests, 0);

      await tester.runAsync(() async {
        probes.single.complete(const ServerIdentity(boundInstance));
        await pumpEventQueue();
        expect(gate.state, isA<BindingVerified>());
      });
      await tester.pump();
      expect(wire.requests, 0, reason: 'a failed read stays failed');
      await tester.runAsync(closeRig);
    });

    testWidgets('$name: a failed check that is being retried does not start '
        'the bound again', (tester) async {
      await tester.runAsync(() async {
        await openRig();
        unawaited(gate.startConnection('http://s'));
        await pumpEventQueue();
      });
      watch(read());
      await tester.pump(const Duration(seconds: 4));
      await tester.runAsync(() async {
        probes.single.completeError(StateError('probe failed'));
        await pumpEventQueue();
        expect(gate.state, isA<BindingUnverified>());
      });
      await tester.pump();
      expect(done, isFalse);

      await tester.pump(_bound - const Duration(seconds: 4) - _tick);
      expect(done, isFalse, reason: 'one millisecond before the bound');
      await tester.pump(_tick);
      expect(error, notYet);
      expect(wire.requests, 0);
      await tester.runAsync(closeRig);
    });

    testWidgets('$name: no check started yet: the same bound, no longer',
        (tester) async {
      await tester.runAsync(openRig);
      expect(gate.state, isA<BindingIdle>());
      watch(read());
      await tester.pump(_bound - _tick);
      expect(done, isFalse);

      await tester.pump(_tick);
      expect(error, notYet);
      expect(wire.requests, 0);
      await tester.runAsync(closeRig);
    });
  }
}
