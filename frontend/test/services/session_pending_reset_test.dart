// A reset that never finished its wipe leaves a marker in the device's
// preferences; launch, connect and sign-in finish it before anything binds
// (review major 2). Two different faults can happen there (owner, 2026-11-17):
//  * asking whether a reset is pending fails (the preferences store cannot
//    be read): that is not a reset that could not finish. Launch lands on
//    the launch-fault screen; connect and sign-in refuse with their own
//    sentence. Nothing proceeds, so a pending reset is never skipped: the
//    marker is untouched and the next attempt asks again;
//  * finishing a pending reset fails: today's sentence, without the raw
//    error; the reason goes to the session event log as a fixed name. The
//    marker is kept, so the next launch, connect or sign-in finishes it.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

/// The raw text of every fault below: it must never reach a screen or the
/// session event log.
const _raw = 'disk I/O error at /Users/someone/Library/prefs.plist';

/// The real preferences, except that reading the reset marker throws (the
/// platform store cannot be read).
class _MarkerUnreadablePrefs implements SharedPreferences {
  _MarkerUnreadablePrefs(this._real);
  final SharedPreferences _real;
  @override
  bool? getBool(String key) => key == LocalResetService.resetPendingKey
      ? throw StateError(_raw)
      : _real.getBool(key);
  @override
  Future<bool> setBool(String key, bool value) => _real.setBool(key, value);
  @override
  String? getString(String key) => _real.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      _real.setString(key, value);
  @override
  Set<String> getKeys() => _real.getKeys();
  @override
  bool containsKey(String key) => _real.containsKey(key);
  @override
  Future<bool> remove(String key) => _real.remove(key);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The real preferences, except that the reset marker cannot be removed
/// (the platform answers false): the wipe ran, the marker stays.
class _MarkerKeepingPrefs extends _MarkerUnreadablePrefs {
  _MarkerKeepingPrefs(super.real);
  @override
  bool? getBool(String key) => _real.getBool(key);
  @override
  Future<bool> remove(String key) async =>
      key == LocalResetService.resetPendingKey ? false : _real.remove(key);
}

/// The prefs wipe band: everything but the reset marker, like the real one.
class _ClearPrefs implements LocalResettable {
  @override
  int get resetPriority => ResetPriority.clearPreferences;
  @override
  Future<void> resetLocalState() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().toList()) {
      if (k != LocalResetService.resetPendingKey) await prefs.remove(k);
    }
  }
}

class _FailingDbWipe extends AppDatabase {
  _FailingDbWipe() : super(NativeDatabase.memory());
  @override
  Future<void> resetLocalState() async => throw StateError(_raw);
}

class _FailingWipe implements LocalResettable {
  @override
  int get resetPriority => ResetPriority.deleteFiles;
  @override
  Future<void> resetLocalState() async => throw StateError(_raw);
}

class _FailingFence extends ServerBindingRepository {
  _FailingFence(super.db);
  @override
  Future<void> fence() async => throw StateError(_raw);
}

const _notFinished = 'An earlier reset could not finish clearing local data, '
    'so no server can be connected yet. Connecting tries again.';

/// Proposed for the owner (not yet approved): connect or sign-in could not
/// read whether an earlier reset is still pending.
const _settingsUnreadable = "This device's saved settings could not be read.";

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late List<String> requests;
  late List<String> events;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    controlled = ControlledGate(db);
    requests = [];
    events = [];
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
  });

  http.Client transport() => MockClient((req) async {
        requests.add('${req.method} ${req.url.path}');
        if (req.url.path == '/auth/login') {
          return http.Response(
            jsonEncode({
              'token': 'tok',
              'media_token': 'med',
              'server_instance_id': 'inst-1',
              'user': {
                'id': testUserId,
                'username': 'tester',
                'is_admin': false,
                'is_master_admin': false,
              },
            }),
            200,
          );
        }
        if (req.url.path.endsWith('/app/info')) {
          return http.Response(
              '{"server":{"instance_id":"inst-1"},'
              '"auth":{"version":1,"signup_enabled":true}}',
              200);
        }
        return http.Response('{"message":"Healthy"}', 200);
      });

  Future<ProviderContainer> scope({
    bool markerUnreadable = false,
    bool markerKept = false,
    List<LocalResettable>? wipe,
    ServerBindingRepository? repository,
    bool signedIn = false,
  }) async {
    final t = transport();
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      apiClientProvider.overrideWithValue(testApiClient('http://s', t)),
      unauthenticatedApiClientProvider
          .overrideWithValue((url) => testApiClient(url, t)),
      if (signedIn) credentialsProvider.overrideWithValue(testCredentials),
      credentialStoreTestOverride(),
      serverBindingGateProvider.overrideWithValue(controlled.gate),
      if (markerUnreadable)
        sharedPreferencesProvider
            .overrideWith((_) async => _MarkerUnreadablePrefs(prefs)),
      if (markerKept)
        sharedPreferencesProvider
            .overrideWith((_) async => _MarkerKeepingPrefs(prefs)),
      if (repository != null)
        serverBindingRepositoryProvider.overrideWithValue(repository),
      localQuiescablesProvider.overrideWithValue(const []),
      localResettablesProvider.overrideWithValue(wipe ?? [_ClearPrefs()]),
      sessionEventLogProvider.overrideWithValue(events.add),
      onSessionChangedProvider.overrideWithValue(() async {}),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<bool?> marker() async => (await SharedPreferences.getInstance())
      .getBool(LocalResetService.resetPendingKey);

  void expectNoRawText() {
    for (final e in events) {
      expect(e, isNot(contains('disk I/O')));
      expect(e, isNot(contains('/Users/')));
    }
  }

  group('asking whether a reset is pending fails', () {
    setUp(() => SharedPreferences.setMockInitialValues(
        {'serverUrl': 'http://s', LocalResetService.resetPendingKey: true}));

    test('at launch: the launch-fault screen, not a failed reset', () async {
      final c = await scope(markerUnreadable: true, signedIn: true);
      final controls = c.read(sessionControlsProvider);
      await controls.start();
      expect(controls.phase, SessionPhase.credentialsUnavailable);
      expect(controls.launchFailed, isTrue);
      expect(controls.connectError, isNull);
      expect(requests, isEmpty, reason: 'nothing is sent');
      expect(await ServerBindingRepository(db).current(), isNull,
          reason: 'nothing binds');
      expect(events, ['Pending reset not checked: reason=marker_unreadable']);
      expect(await marker(), isTrue, reason: 'untouched: asked again next time');
    });

    test('at connect: refused with its own sentence; nothing sent or saved',
        () async {
      SharedPreferences.setMockInitialValues(
          {LocalResetService.resetPendingKey: true});
      final c = await scope(markerUnreadable: true);
      final outcome = await c.read(sessionServiceProvider).connect('http://b');
      expect(outcome,
          isA<ConnectFailed>().having((o) => o.message, 'message',
              _settingsUnreadable));
      expect(requests, isEmpty);
      expect((await SharedPreferences.getInstance()).getString('serverUrl'),
          isNull);
      expect(events, ['Pending reset not checked: reason=marker_unreadable']);
      expect(await marker(), isTrue);
    });

    test('at sign-in: refused with the same sentence; nothing sent or stored',
        () async {
      final c = await scope(markerUnreadable: true);
      final outcome =
          await c.read(sessionServiceProvider).login('tester', 'pw-tester-1');
      expect(outcome,
          isA<SignInFailed>().having((o) => o.message, 'message',
              _settingsUnreadable));
      expect(requests, isEmpty, reason: 'no credentials were sent');
      expect(await ServerBindingRepository(db).current(), isNull);
      expect(events, ['Pending reset not checked: reason=marker_unreadable']);
      expect(await marker(), isTrue);
    });

    test('once the marker can be read, the pending reset is finished',
        () async {
      final first = await scope(markerUnreadable: true);
      await first.read(sessionServiceProvider).connect('http://b');
      final next = await scope();
      final start = await next.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.resetFinished);
      expect(await marker(), isNull);
    });
  });

  group('finishing a pending reset fails', () {
    setUp(() => SharedPreferences.setMockInitialValues(
        {'serverUrl': 'http://s', LocalResetService.resetPendingKey: true}));

    Future<ProviderContainer> failing(String reason) async {
      switch (reason) {
        case 'fence_failed':
          return scope(repository: _FailingFence(db));
        case 'database_wipe_failed':
          final failingDb = _FailingDbWipe();
          addTearDown(failingDb.close);
          return scope(wipe: [_ClearPrefs(), failingDb]);
        case 'marker_not_cleared':
          return scope(markerKept: true);
        default:
          return scope(wipe: [_ClearPrefs(), _FailingWipe()]);
      }
    }

    for (final reason in [
      'fence_failed',
      'database_wipe_failed',
      'wipe_failed',
      'marker_not_cleared',
    ]) {
      test('$reason, at launch: the sentence without the error; the marker '
          'kept; nothing binds', () async {
        final c = await failing(reason);
        final start = await c.read(sessionServiceProvider).resumeSavedSession();
        expect(start.kind, SessionStartKind.serverAddress);
        expect(start.error, _notFinished);
        expect(events, ['Pending reset not finished: reason=$reason']);
        expectNoRawText();
        expect(await marker(), isTrue, reason: 'the next launch tries again');
        expect(requests, isEmpty);
        expect(await ServerBindingRepository(db).current(), isNull);
      });
    }

    test('at connect: the same sentence; nothing sent', () async {
      final c = await failing('wipe_failed');
      final outcome = await c.read(sessionServiceProvider).connect('http://b');
      expect(outcome,
          isA<ConnectFailed>().having((o) => o.message, 'message', _notFinished));
      expect(requests, isEmpty);
      expect(events, ['Pending reset not finished: reason=wipe_failed']);
      expect(await marker(), isTrue);
    });

    test('at sign-in: the same sentence; nothing sent', () async {
      final c = await failing('wipe_failed');
      final outcome =
          await c.read(sessionServiceProvider).login('tester', 'pw-tester-1');
      expect(outcome,
          isA<SignInFailed>().having((o) => o.message, 'message', _notFinished));
      expect(requests, isEmpty);
      expect(events, ['Pending reset not finished: reason=wipe_failed']);
      expectNoRawText();
      expect(await marker(), isTrue);
    });

    test('the next launch whose wipe succeeds finishes it', () async {
      final first = await failing('wipe_failed');
      await first.read(sessionServiceProvider).resumeSavedSession();
      final next = await scope();
      final start = await next.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.resetFinished);
      expect(await marker(), isNull);
    });

  });

  test('nothing pending: nothing finished, nothing logged', () async {
    SharedPreferences.setMockInitialValues({});
    final c = await scope();
    expect(await c.read(sessionServiceProvider).connect('http://b'),
        isA<ConnectSucceeded>());
    expect(events, isEmpty);
  });
}
