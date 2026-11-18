// SC-01 rule 1 at the sync entry points: TrackSyncNotifier's runs await the
// binding gate before their first request and write with the gate's
// verified token (the session's onSessionActivated sync and the conversion
// settle's syncFresh go through these same entry points).
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';
import '../helpers/test_offline.dart';

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late ProviderContainer c;
  late int changeRequests;
  late ApiClient api;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: 'http://s');
    controlled = ControlledGate(db);
    changeRequests = 0;
    api = testApiClient(
      'http://s',
      MockClient((req) async {
        changeRequests++;
        return http.Response(
          jsonEncode({'changes': [], 'latestRevision': 0, 'nextCursor': null}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(api),
        tracksApiProvider.overrideWithValue(TracksApi(api: api)),
        offlineModeProvider.overrideWith(() => TestOffline(false)),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
      ],
    );
    await c.read(trackSyncProvider.future);
  });

  tearDown(() async {
    controlled.dispose();
    c.dispose();
    await db.close();
  });

  // Audit 5A.0(a) #2: syncFresh is user-facing (Convert) and documented as
  // bounded: with no verified connection it reports failure now instead of
  // waiting on the gate (or on a run that waits on it).
  test('syncFresh fails fast while the connection is not verified', () async {
    final background = c.read(trackSyncProvider.notifier).sync(); // waits
    await pumpEventQueue();
    var done = false;
    final fresh = c
        .read(trackSyncProvider.notifier)
        .syncFresh()
        .whenComplete(() => done = true);
    await pumpEventQueue();
    expect(done, isTrue);
    expect(await fresh, isFalse);
    expect(changeRequests, 0);

    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond('inst-1');
    await background;
  });

  test('a sync waits for verification before its first request', () async {
    final sync = c.read(trackSyncProvider.notifier).sync();
    await pumpEventQueue();
    expect(changeRequests, 0);

    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond('inst-1');
    await sync;
    expect(changeRequests, 1);
    expect(c.read(trackSyncProvider).value!.libraryError, isNull);
  });

  test('a different server never receives a sync request', () async {
    final sync = c.read(trackSyncProvider.notifier).sync();
    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    // Bound to inst-1 first, then a different server answers.
    controlled.respond('inst-1');
    await sync;
    expect(changeRequests, 1);

    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond('inst-2');
    await pumpEventQueue();
    expect(controlled.gate.state, isA<BindingDifferentServer>());
    unawaited(c.read(trackSyncProvider.notifier).sync());
    await pumpEventQueue();
    expect(changeRequests, 1);
  });

  // U22-FE-LIFECYCLE-B-08: every app resume (each window refocus on the
  // desktop) re-probes the gate. A user's own fresh sync (Convert) waits out
  // that pending verdict instead of failing "not connected" at once; the
  // background syncFresh keeps failing fast.
  group('a re-probe in flight (app resume)', () {
    Future<void> verifyThenReprobe() async {
      unawaited(controlled.gate.startConnection('http://s'));
      await pumpEventQueue();
      controlled.respond('inst-1');
      await controlled.gate.awaitVerified();
      unawaited(controlled.gate.startConnection('http://s'));
      await pumpEventQueue();
      expect(controlled.gate.state, isA<BindingVerifying>());
    }

    test("a user's fresh sync waits for the verdict, then runs", () async {
      await verifyThenReprobe();
      var done = false;
      final fresh = c
          .read(trackSyncProvider.notifier)
          .syncFreshForUserAction()
          .whenComplete(() => done = true);
      await pumpEventQueue();
      expect(done, isFalse, reason: 'waits for the pending verdict');
      controlled.respond('inst-1');
      expect(await fresh, isTrue);
      expect(changeRequests, 1);
    });

    test("a user's fresh sync fails when the verdict is a different server",
        () async {
      await verifyThenReprobe();
      final fresh =
          c.read(trackSyncProvider.notifier).syncFreshForUserAction();
      await pumpEventQueue();
      controlled.respond('inst-2');
      expect(await fresh, isFalse);
      expect(changeRequests, 0);
    });

    test('the background fresh sync still fails at once', () async {
      await verifyThenReprobe();
      expect(await c.read(trackSyncProvider.notifier).syncFresh(), isFalse);
      expect(changeRequests, 0);
      controlled.respond('inst-1');
      await pumpEventQueue();
    });
  });

  test('syncFresh runs once the connection is verified', () async {
    // Before verification it fails fast with no request (see above).
    expect(await c.read(trackSyncProvider.notifier).syncFresh(), isFalse);
    expect(changeRequests, 0);
    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond('inst-1');
    await controlled.gate.awaitVerified();
    expect(await c.read(trackSyncProvider.notifier).syncFresh(), isTrue);
    expect(changeRequests, 1);
  });
}
