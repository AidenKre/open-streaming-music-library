// Sign-off OPEN-M-11, Phase 9 adaptation (E9): the Last.fm calls ask the
// token client's own rule (verified, the server's address, online) before
// they send. Verified but offline, the status read fails fast as "not
// verified now" (needs a connection) and an action is refused at once
// instead of waiting for a verdict that is not coming; nothing is sent.
// The user-action wait is the one bound (ServerBindingGate.tokenWaitBound).
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/lastfm_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/lastfm/lastfm_service.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;

import '../helpers/fake_lastfm_api.dart' show liveIntegrations;
import '../helpers/server_binding.dart';
import '../helpers/stamped_server.dart';
import '../helpers/test_credentials.dart';

/// The real API, counting status reads.
class _Counting extends LastfmApi {
  _Counting({required super.api, required super.gate});
  int reads = 0;
  @override
  Future<LastfmStatus> status() {
    reads++;
    return super.status();
  }
}

class _Wire extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({
        'service': 'running',
        'state': 'not_connected',
        'needs_reconnect': false,
        'account_name': null,
        'connection_id': null,
        'approval_expires_at': null,
        'counts': {
          'pending': 0, 'sent': 0, 'ignored': 0, 'failed': 0, 'dropped': 0,
        },
        'recent_problems': [],
      }))),
      200,
      headers: {
        'content-type': 'application/json',
        'x-server-instance-id': boundInstance,
      },
    );
  }
}

void main() {
  late AppDatabase db;
  late ServerBindingGate gate;
  late _Wire wire;
  late LastfmApi api;
  late bool offline;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: boundInstance);
    offline = false;
    gate = ServerBindingGate(
      repository: ServerBindingRepository(db),
      signedInUserId: testUserId,
      probe: ({required String baseUrl, required bool reportOffline}) async =>
          const ServerIdentity(boundInstance),
      backoff: BackoffSchedule(jitter: 0),
      isOffline: () => offline,
    );
    unawaited(gate.startConnection('http://s'));
    await pumpEventQueue();
    expect(gate.state, isA<BindingVerified>());
    wire = _Wire();
    final client = testApiClient(
      'http://s',
      AuthenticatedClient(wire, testCredentials, permit: gate),
    );
    api = LastfmApi(
      api: client.withInstanceCheck(ServerBindingRepository(db).checkServedBy),
      gate: gate,
    );
  });

  tearDown(() async {
    gate.dispose();
    await db.close();
  });

  test('status, verified but offline: not verified now (not yet), nothing '
      'sent', () async {
    offline = true;
    await expectLater(
      api.status(),
      throwsA(isA<BindingNotVerified>()
          .having((e) => e.reason, 'reason', BindingRefusal.notYet)),
    );
    expect(wire.requests, isEmpty);
  });

  final actions = <String, Future<Object?> Function(LastfmApi)>{
    'connect': (a) => a.connect(),
    'complete': (a) => a.complete(),
    'enable': (a) => a.enable('c0ffee00-0000-4000-8000-000000000001'),
    'disconnect': (a) => a.disconnect(),
  };
  for (final MapEntry(key: name, value: act) in actions.entries) {
    test('$name, verified but offline: refused at once (no wait for a '
        'verdict that is not coming), nothing sent', () async {
      offline = true;
      Object? error;
      var done = false;
      unawaited(act(api).then((_) => done = true, onError: (Object e) {
        error = e;
        done = true;
      }));
      await pumpEventQueue();
      expect(done, isTrue, reason: 'no 10 s wait');
      expect(error, isA<BindingNotVerified>()
          .having((e) => e.reason, 'reason', BindingRefusal.notYet));
      expect(wire.requests, isEmpty);
    });
  }

  // Review s9 F1/F2: "verified now" as the Integrations model uses it follows
  // the token client's rule, so offline it waits for the next verified edge
  // (the reconnect) instead of re-reading at once in a loop.
  test('isVerifiedNow: verified but offline is not', () async {
    expect(api.isVerifiedNow, isTrue);
    offline = true;
    expect(api.isVerifiedNow, isFalse);
  });

  test('the Integrations model, verified but offline: one status read, no '
      're-read loop; it reads again on the reconnect', () async {
    final counting = _Counting(
      api: testApiClient(
        'http://s',
        AuthenticatedClient(wire, testCredentials, permit: gate),
      ).withInstanceCheck(ServerBindingRepository(db).checkServedBy),
      gate: gate,
    );
    offline = true;
    final c = ProviderContainer(overrides: [
      lastfmApiProvider.overrideWithValue(counting),
      integrationsFeatureProvider.overrideWith(
          (ref) async => liveIntegrations()),
    ]);
    addTearDown(c.dispose);
    c.listen(lastfmServiceProvider, (_, _) {});
    try {
      await c.read(lastfmServiceProvider.future);
    } catch (_) {}
    await pumpEventQueue(times: 50);
    expect(counting.reads, 1, reason: 'no loop');
    expect(wire.requests, isEmpty);

    offline = false;
    unawaited(gate.startConnection('http://s')); // the reconnect
    await pumpEventQueue(times: 50);
    expect(counting.reads, 2);
    expect(wire.requests, hasLength(1));
  });

  test('control: verified and online, status goes with the token', () async {
    await api.status();
    expect(wire.requests.single.headers['Authorization'],
        'Bearer ${testCredentials.token}');
  });
}
