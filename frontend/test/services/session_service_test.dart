import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';

class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

class _FakeReset extends LocalResetService {
  _FakeReset(super.ref, {this.failure});
  final LocalResetException? failure;
  int resets = 0;
  @override
  Future<void> reset() async {
    resets++;
    if (failure != null) throw failure!;
  }
}

http.Client _server(int status) =>
    MockClient((_) async => http.Response(status == 200 ? '{"message":"Healthy"}' : '{"message":"nope"}', status));
http.Client _unreachable() =>
    MockClient((_) async => throw const SocketException('down'));

/// The session rules that used to live inside StartupGate (SC-26: model).
void main() {
  late ProviderContainer c;
  _FakeReset? reset;

  ProviderContainer make({bool offline = false, LocalResetException? failure}) {
    // SC-01: a session writes its binding row and verifies the connection
    // through the binding gate (identity probe answered immediately).
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        autoVerifiedGateOverride(startOnRead: false),
        offlineModeProvider.overrideWith(() => _StubOffline(offline)),
        localResetServiceProvider.overrideWith(
          (ref) => reset = _FakeReset(ref, failure: failure),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.read(offlineModeProvider);
    return c;
  }

  SessionService service() => c.read(sessionServiceProvider);

  group('resumeSavedSession', () {
    test('no saved URL: signed out', () async {
      SharedPreferences.setMockInitialValues({});
      make();
      expect((await service().resumeSavedSession()).kind,
          SessionStartKind.signedOut);
    });

    test('healthy saved server: online', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      make();
      ApiClient.initForTest('http://s', _server(200));
      final start = await service().resumeSavedSession();
      expect(start.kind, SessionStartKind.online);
      expect(c.read(offlineModeProvider), isFalse);
    });

    test('unreachable saved server: offline session, URL kept', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      make();
      ApiClient.initForTest('http://s', _unreachable());
      final start = await service().resumeSavedSession();
      expect(start.kind, SessionStartKind.offline);
      expect(c.read(offlineModeProvider), isTrue);
      expect((await SharedPreferences.getInstance()).getString('serverUrl'),
          'http://s');
    });

    test('server rejects us: URL forgotten, error kept for the login screen',
        () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      make();
      ApiClient.initForTest('http://s', _server(500));
      final start = await service().resumeSavedSession();
      expect(start.kind, SessionStartKind.signedOut);
      expect(start.error, isNotNull);
      expect((await SharedPreferences.getInstance()).getString('serverUrl'),
          isNull);
    });
  });

  group('connect', () {
    test('a healthy server is saved and clears offline mode', () async {
      SharedPreferences.setMockInitialValues({});
      make(offline: true);
      ApiClient.initForTest('http://new', _server(200));
      expect(await service().connect('http://new'), isA<ConnectSucceeded>());
      expect((await SharedPreferences.getInstance()).getString('serverUrl'),
          'http://new');
      expect(c.read(offlineModeProvider), isFalse);
    });

    test('an unproven URL is not saved and does not enter offline', () async {
      SharedPreferences.setMockInitialValues({});
      make();
      ApiClient.initForTest('http://typo', _unreachable());
      expect(await service().connect('http://typo'), isA<ConnectFailed>());
      expect((await SharedPreferences.getInstance()).getString('serverUrl'),
          isNull);
      expect(c.read(offlineModeProvider), isFalse);
    });
  });

  group('resetLocalData', () {
    test('a clean reset reports no failure', () async {
      make();
      expect(await service().resetLocalData(), isNull);
      expect(reset!.resets, 1);
    });

    test('a partial reset is reported, never hidden', () async {
      final failure = LocalResetException([
        LocalResetFailure(String, StateError('disk'), StackTrace.empty),
      ]);
      make(failure: failure);
      expect(await service().resetLocalData(), same(failure));
    });

    test('an unexpected error is reported as a reset failure', () async {
      make();
      c.dispose();
      final c2 = ProviderContainer(
        overrides: [
          localResetServiceProvider.overrideWith((ref) => _Throwing(ref)),
        ],
      );
      addTearDown(c2.dispose);
      expect(await c2.read(sessionServiceProvider).resetLocalData(),
          isA<LocalResetException>());
    });
  });

  group('session readiness is the model\'s (playback restore waits for it)',
      () {
    test('online and offline resumes are ready; a rejected one is not',
        () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      make();
      ApiClient.initForTest('http://s', _server(200));
      await service().resumeSavedSession();
      await pumpEventQueue(); // online: ready on the binding gate's verdict
      expect(c.read(sessionReadinessProvider).isReady, isTrue,
          reason: 'online cold start must be ready');

      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      make();
      ApiClient.initForTest('http://s', _unreachable());
      await service().resumeSavedSession();
      expect(c.read(sessionReadinessProvider).isReady, isTrue);

      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      make();
      ApiClient.initForTest('http://s', _server(500));
      await service().resumeSavedSession();
      expect(c.read(sessionReadinessProvider).isReady, isFalse);
    });

    test('a successful connect is ready; a failed one is not', () async {
      SharedPreferences.setMockInitialValues({});
      make();
      ApiClient.initForTest('http://typo', _unreachable());
      await service().connect('http://typo');
      expect(c.read(sessionReadinessProvider).isReady, isFalse);
      ApiClient.initForTest('http://ok', _server(200));
      await service().connect('http://ok');
      expect(c.read(sessionReadinessProvider).isReady, isTrue);
    });
  });

  test('session activation runs one catalog sync (not per call)', () async {
    SharedPreferences.setMockInitialValues({});
    final sync = _CountingSync();
    c = ProviderContainer(overrides: [trackSyncProvider.overrideWith(() => sync)]);
    addTearDown(c.dispose);
    await c.read(trackSyncProvider.future);
    await service().onSessionActivated();
    await service().onSessionActivated();
    expect(sync.syncs, 1);
  });

  // Audit 4A(a) M2: a failed initial sync can be retried by the user.
  test('syncLibrary runs a catalog sync each time (Retry after activation)',
      () async {
    SharedPreferences.setMockInitialValues({});
    final sync = _CountingSync();
    c = ProviderContainer(overrides: [trackSyncProvider.overrideWith(() => sync)]);
    addTearDown(c.dispose);
    await c.read(trackSyncProvider.future);
    await service().onSessionActivated();
    await service().syncLibrary();
    await service().syncLibrary();
    expect(sync.syncs, 3);
  });
}

class _Throwing extends LocalResetService {
  _Throwing(super.ref);
  @override
  Future<void> reset() async => throw StateError('boom');
}

class _CountingSync extends TrackSyncNotifier {
  int syncs = 0;
  @override
  Future<TrackSyncState> build() async => const TrackSyncState();
  @override
  Future<void> sync() async => syncs++;
}
