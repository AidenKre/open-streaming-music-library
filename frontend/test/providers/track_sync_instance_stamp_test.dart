// Phase 7B.1a (SC-01 rule 6, wiring): a catalog or history page stamped by
// another server instance runs rule 1's different-server flow through the
// scope's binding gate, exactly as the gate's own probe would:
//  * catalog: TrackSyncNotifier's run aborts the page, the gate blocks as
//    BindingDifferentServer, and no library error is published (the
//    blocked banner says it; an error text must not carry instance ids);
//  * history: the scope's history pass reports to the same gate;
//  * a legacy server (no stamp) syncs and stays verified.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/history_api.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';

const _bound = '3f1c2a9e-7b4d-4e2a-9c1f-0a1b2c3d4e5f';
const _other = '9d8e7f6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a';

class _Online extends OfflineModeNotifier {
  @override
  bool build() {
    super.build();
    return false;
  }
}

class _History extends HistoryApi {
  _History(ApiClient client, this.stamp) : super(api: client);
  final String? stamp;

  @override
  Future<Object?> post(batch) async => batch.eventUuids;

  @override
  Future<HistoryPage> changes({required int after, int limit = 200}) async =>
      HistoryPage(
        events: const [],
        nextCursor: null,
        latestRevision: 0,
        servedBy: stamp,
      );
}

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late ProviderContainer c;
  String? catalogStamp;
  String? historyStamp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: _bound);
    controlled = ControlledGate(db);
    catalogStamp = null;
    historyStamp = null;
    final api = testApiClient(
      'http://s',
      MockClient((req) async => http.Response(
        jsonEncode({'changes': [], 'latestRevision': 0, 'nextCursor': null}),
        200,
        headers: {
          'content-type': 'application/json',
          'x-server-instance-id': ?catalogStamp,
        },
      )),
    );
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(api),
        tracksApiProvider.overrideWithValue(TracksApi(api: api)),
        historyApiProvider.overrideWith((ref) => _History(api, historyStamp)),
        appInfoProvider.overrideWith(
          (ref) async => AppInfo.fromJson({'history': {'version': 1}}),
        ),
        offlineModeProvider.overrideWith(_Online.new),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
      ],
    );
    await c.read(trackSyncProvider.future);
    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond(_bound);
    await pumpEventQueue();
    expect(controlled.gate.state, isA<BindingVerified>());
  });

  tearDown(() async {
    controlled.dispose();
    c.dispose();
    await db.close();
  });

  test('a catalog page from another instance blocks as a different server',
      () async {
    catalogStamp = _other;

    final ran = await c.read(trackSyncProvider.notifier).sync().then((_) => true);
    await pumpEventQueue();

    expect(ran, isTrue);
    expect(
      controlled.gate.state,
      isA<BindingDifferentServer>()
          .having((s) => s.serverInstanceId, 'server', _other),
    );
    final state = c.read(trackSyncProvider).value!;
    expect(state.isSyncing, isFalse);
    expect(state.libraryError, isNull);
    expect(state.error ?? '', isNot(contains(_other)));
    expect(state.error ?? '', isNot(contains(_bound)));
  });

  test('a legacy catalog page (no stamp) syncs and stays verified', () async {
    await c.read(trackSyncProvider.notifier).sync();

    expect(controlled.gate.state, isA<BindingVerified>());
    expect(c.read(trackSyncProvider).value!.libraryError, isNull);
  });

  test('a history page from another instance blocks as a different server',
      () async {
    historyStamp = _other;

    final out = await c.read(historySyncServiceProvider).runPass({'poll'});

    expect(out, isA<PassFailed>());
    expect(
      controlled.gate.state,
      isA<BindingDifferentServer>()
          .having((s) => s.serverInstanceId, 'server', _other),
    );
  });
}
