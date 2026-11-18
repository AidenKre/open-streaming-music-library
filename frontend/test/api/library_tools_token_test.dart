// Sign-off OPEN-M-11, Phase 8 adaptation (E8): the token client withholds a
// request while this connection is not verified or the app is offline
// (TokenWithheldException; nothing sent). The page reads that must not wait
// (Deletion history, Possible duplicates) then read as "not connected", the
// state that already says so and reloads by itself once connected. The
// waiting calls (submissions, polls, pair actions) keep the raw error, which
// their callers treat as "not sent".
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/api/token_permit.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;

import '../helpers/server_binding.dart';
import '../helpers/stamped_server.dart';
import '../helpers/test_credentials.dart';

/// Records what reaches the wire; answers an empty page.
class _Wire extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'jobs': [], 'pairs': [], 'next_after': null}))),
      200,
      headers: {
        'content-type': 'application/json',
        'x-server-instance-id': boundInstance,
      },
    );
  }
}

/// The gate's answer, refused on demand after the gate's own check (a
/// verification lost between the check and the send).
class _Permit implements TokenPermit {
  _Permit(this.gate);
  final ServerBindingGate gate;
  bool refuse = false;
  @override
  bool allowsTokenTo(Uri url) => !refuse && gate.allowsTokenTo(url);
  @override
  Future<void> verdictSettled() => gate.verdictSettled();
}

void main() {
  late AppDatabase db;
  late ServerBindingGate gate;
  late _Permit permit;
  late _Wire wire;
  late LibraryToolsApi api;
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
    permit = _Permit(gate);
    wire = _Wire();
    final client = testApiClient(
      'http://s',
      AuthenticatedClient(wire, testCredentials, permit: permit),
    );
    api = LibraryToolsApi(
      api: client.withInstanceCheck(ServerBindingRepository(db).checkServedBy),
      gate: gate,
    );
  });

  tearDown(() async {
    gate.dispose();
    await db.close();
  });

  final pageReads = <String, Future<Object?> Function(LibraryToolsApi)>{
    'listJobs': (a) => a.listJobs(waitForBinding: false),
    'listDuplicates': (a) => a.listDuplicates(waitForBinding: false),
    'duplicateSummary': (a) => a.duplicateSummary(waitForBinding: false),
  };

  for (final MapEntry(key: name, value: read) in pageReads.entries) {
    test('$name: verified but offline reads as not connected, nothing sent',
        () async {
      offline = true;
      await expectLater(read(api), throwsA(isA<LibraryToolsNotConnected>()));
      expect(wire.requests, isEmpty);
    });

    test('$name: the token withheld at the send reads as not connected',
        () async {
      permit.refuse = true;
      await expectLater(read(api), throwsA(isA<LibraryToolsNotConnected>()));
      expect(wire.requests, isEmpty);
    });

    test('$name: control, verified and online it is sent with the token',
        () async {
      await read(api);
      expect(wire.requests.single.headers['Authorization'],
          'Bearer ${testCredentials.token}');
    });
  }

  final waiting = <String, Future<Object?> Function(LibraryToolsApi)>{
    'createJob': (a) => a.createJob(DeletionJobRequestDto(
          operationUuid: '33333333-3333-4333-8333-333333333333',
          targets: const [
            DeletionTargetDto(
                uuidId: '11111111-1111-4111-8111-111111111111', baseRevision: 4),
          ],
          confirmedCount: 1,
        ).toFrozenJson()),
    'getJob': (a) => a.getJob('33333333-3333-4333-8333-333333333333'),
    'dismissPair': (a) => a.dismissPair('a', 'b'),
  };
  for (final MapEntry(key: name, value: call) in waiting.entries) {
    test('$name (waits at the gate): the withheld token stays its own error '
        '(its caller treats it as not sent)', () async {
      offline = true;
      await expectLater(call(api), throwsA(isA<TokenWithheldException>()));
      expect(wire.requests, isEmpty);
    });
  }
}
