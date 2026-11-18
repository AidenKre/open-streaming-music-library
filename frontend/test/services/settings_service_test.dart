import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/settings_service.dart';

import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

ApiClient api = testApiClient('', MockClient((_) async => fail('unexpected request')));

/// A session scope: a bound database and a connection that verifies at
/// once (the backend reconcile is a gated network runner, SC-01 rule 1).
Future<ProviderContainer> _containerWith(
  SharedPreferences prefs, {
  ServerBindingGate? gate,
  List<Override> extra = const [],
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await seedTestBinding(db);
  return ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWith((_) async => prefs),
    apiClientProvider.overrideWithValue(api),
    // Signed in only when a server is configured ("no server" = signed out).
    if (api.baseUrl.isNotEmpty) ...signedInOverrides,
    databaseProvider.overrideWithValue(db),
    if (gate != null)
      serverBindingGateProvider.overrideWithValue(gate)
    else
      autoVerifiedGateOverride(),
    ...extra,
  ]);
}

/// The reset lifecycle with a generation the test moves (a reset started).
class _Resets extends LocalResetService {
  _Resets(super.ref);
  int gen = 0;
  @override
  int get generation => gen;
}

void main() {
  setUp(() {
    // Reset the client so cross-test state doesn't bleed.
    api = testApiClient('', MockClient((_) async => fail('unexpected request')));
    SharedPreferences.setMockInitialValues({});
    // build() no longer awaits the backend sync, but the per-attempt
    // timeout still bounds the reconcile in flight — keep it tight in
    // tests so timeout cases run fast. Production default is 3s.
    final originalSyncTimeout = SettingsNotifier.backendSyncTimeout;
    addTearDown(
      () => SettingsNotifier.backendSyncTimeout = originalSyncTimeout,
    );
    SettingsNotifier.backendSyncTimeout = const Duration(milliseconds: 200);
  });

  test('build returns original/original on first launch', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    final settings = await container.read(settingsProvider.future);
    expect(settings.streamQuality, originalQuality);
    expect(settings.downloadQuality, originalQuality);
  });

  test('build hydrates from SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({
      'settings.streamQuality': '256',
      'settings.downloadQuality': '320',
    });
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    final settings = await container.read(settingsProvider.future);
    expect(settings.streamQuality, '256');
    expect(settings.downloadQuality, '320');
  });

  test('build falls back to original for stale/invalid stored values', () async {
    SharedPreferences.setMockInitialValues({
      'settings.streamQuality': 'lossless-DSD',
      'settings.downloadQuality': '500',
    });
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    final settings = await container.read(settingsProvider.future);
    expect(settings.streamQuality, originalQuality);
    expect(settings.downloadQuality, originalQuality);
  });

  test('setStreamQualityFull persists and updates state', () async {
    final prefs = await SharedPreferences.getInstance();
    // Backend PUT must succeed for persistence to happen.
    api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async => http.Response('{}', 200)),
    );
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    await container.read(settingsProvider.notifier).setStreamQualityFull('192');

    expect(prefs.getString('settings.streamQuality'), '192');
    expect(container.read(settingsProvider).value!.streamQuality, '192');
    expect(
      container.read(settingsProvider).value!.streamQualityChangeKind,
      QualityChangeKind.full,
    );
  });

  test('setStreamQualityFull clears any temporary override', () async {
    final prefs = await SharedPreferences.getInstance();
    api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async => http.Response('{}', 200)),
    );
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    container.read(settingsProvider.notifier).setStreamQualityTemporary('128');
    expect(container.read(settingsProvider).value!.streamQuality, '128');

    await container.read(settingsProvider.notifier).setStreamQualityFull('256');
    expect(container.read(settingsProvider).value!.streamQuality, '256');
    expect(
      container.read(settingsProvider).value!.temporaryStreamQuality,
      isNull,
    );
  });

  test('setStreamQualityTemporary does not persist', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    container.read(settingsProvider.notifier).setStreamQualityTemporary('320');

    // streamQuality reflects temporary value.
    expect(container.read(settingsProvider).value!.streamQuality, '320');
    // But SharedPreferences was not touched.
    expect(prefs.getString('settings.streamQuality'), isNull);
    expect(
      container.read(settingsProvider).value!.streamQualityChangeKind,
      QualityChangeKind.temporary,
    );
  });

  test('setStreamQualityTemporary overrides persisted quality', () async {
    SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    expect(container.read(streamQualityProvider), '256');

    container.read(settingsProvider.notifier).setStreamQualityTemporary('128');
    expect(container.read(streamQualityProvider), '128');
  });

  test('setDownloadQuality persists and updates state', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    await container.read(settingsProvider.notifier).setDownloadQuality('128');

    expect(prefs.getString('settings.downloadQuality'), '128');
    expect(
      container.read(settingsProvider).value!.downloadQuality,
      '128',
    );
  });

  test('notifyStaleDownloads defaults to true', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    final settings = await container.read(settingsProvider.future);
    expect(settings.notifyStaleDownloads, isTrue);
  });

  test('setNotifyStaleDownloads persists and updates state', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    await container.read(settingsProvider.notifier).setNotifyStaleDownloads(false);

    expect(prefs.getBool('settings.notifyStaleDownloads'), false);
    expect(
      container.read(settingsProvider).value!.notifyStaleDownloads,
      isFalse,
    );
  });

  test('setStreamQualityFull rejects invalid values', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    expect(
      () => container.read(settingsProvider.notifier).setStreamQualityFull('hi-res'),
      throwsArgumentError,
    );
  });

  test('setStreamQualityTemporary rejects invalid values', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    expect(
      () => container
          .read(settingsProvider.notifier)
          .setStreamQualityTemporary('hi-res'),
      throwsArgumentError,
    );
  });

  test('streamQualityProvider returns original while settings are loading',
      () async {
    final container = ProviderContainer(overrides: [
      // Never resolves — simulates loading state.
      sharedPreferencesProvider.overrideWith(
        (_) => Completer<SharedPreferences>().future,
      ),
    ]);
    addTearDown(container.dispose);

    expect(container.read(streamQualityProvider), originalQuality);
    expect(container.read(downloadQualityProvider), originalQuality);
  });

  test('streamQualityProvider reflects loaded settings', () async {
    SharedPreferences.setMockInitialValues({
      'settings.streamQuality': '256',
      'settings.downloadQuality': '320',
    });
    final prefs = await SharedPreferences.getInstance();
    final container = await _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    expect(container.read(streamQualityProvider), '256');
    expect(container.read(downloadQualityProvider), '320');
  });

  group('setStreamQualityFull backend-first persistence', () {
    // D7 (owner, 2026-11-17): a refused default is not shown as the default.
    test('PUT failure: the old default stays, prefs NOT written, the call '
        'throws', () async {
      // Pref starts at 256; user picks 128 but the backend PUT fails.
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      // GET (build-time sync) returns 256; PUT 500s on every retry.
      api = testApiClient(
        'http://localhost:8000',
        MockClient((req) async {
          if (req.method == 'PUT') {
            return http.Response('boom', 500);
          }
          return http.Response(
            jsonEncode({'quality': '256'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await expectLater(
        container.read(settingsProvider.notifier).setStreamQualityFull('128'),
        throwsA(anything),
      );

      // In memory: the old default, not the refused one ...
      expect(container.read(settingsProvider).value!.streamQuality, '256');
      expect(container.read(settingsProvider).value!.persistedStreamQuality,
          '256');
      // ... and the pref is unchanged (still the pre-call value).
      expect(prefs.getString('settings.streamQuality'), '256');
    });

    test('PUT success: prefs are written and state updates', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      api = testApiClient(
        'http://localhost:8000',
        MockClient((req) async {
          if (req.method == 'PUT') return http.Response('{}', 200);
          return http.Response(
            jsonEncode({'quality': originalQuality}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await container.read(settingsProvider.notifier).setStreamQualityFull('320');

      expect(prefs.getString('settings.streamQuality'), '320');
      expect(container.read(settingsProvider).value!.streamQuality, '320');
    });
  });

  group('build publishes local prefs then reconciles backend', () {
    http.Response qualityResponse(String quality) => http.Response(
          jsonEncode({'quality': quality}),
          200,
          headers: {'content-type': 'application/json'},
        );

    test('build returns local prefs immediately, before backend resolves',
        () async {
      // Local pref is "256"; backend will eventually say "128".
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      final getCompleter = Completer<http.Response>();
      api = testApiClient(
        'http://localhost:8000',
        MockClient((_) => getCompleter.future),
      );

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      // build() must NOT wait on the GET — the local pref is published
      // immediately, so downstream providers don't sit on `original`.
      final settings = await container.read(settingsProvider.future);
      expect(settings.streamQuality, '256');
      expect(container.read(streamQualityProvider), '256');
      expect(container.read(downloadQualityProvider), originalQuality);

      // Release the GET; the reconcile then updates state to the backend value.
      getCompleter.complete(qualityResponse('128'));
      await container.read(settingsProvider.notifier).debugBackendSyncDone;
      expect(container.read(settingsProvider).value!.streamQuality, '128');
      expect(prefs.getString('settings.streamQuality'), '128');
    });

    // SC-01 rule 1 (found live, 5-T19(c)): the reconcile reads the server's
    // setting, so it waits for a verified connection: never adopt another
    // server's value before the binding check.
    test('the backend reconcile waits for a verified connection', () async {
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      var requests = 0;
      api = testApiClient(
        'http://localhost:8000',
        MockClient((_) async {
          requests++;
          return qualityResponse('128');
        }),
      );
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await seedTestBinding(db);
      final controlled = ControlledGate(db);
      addTearDown(controlled.dispose);
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWith((_) async => prefs),
        apiClientProvider.overrideWithValue(api),
    ...signedInOverrides,
        databaseProvider.overrideWithValue(db),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
      ]);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await pumpEventQueue();
      expect(requests, 0, reason: 'no request before verification');
      expect(container.read(settingsProvider).value!.streamQuality, '256');

      unawaited(controlled.gate.startConnection('http://localhost:8000'));
      await pumpEventQueue();
      controlled.respond('inst-1');
      await container.read(settingsProvider.notifier).debugBackendSyncDone;
      expect(requests, 1);
      expect(container.read(settingsProvider).value!.streamQuality, '128');
    });

    test('backend reconcile updates state to backend value', () async {
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      api = testApiClient(
        'http://localhost:8000',
        MockClient((_) async => qualityResponse('128')),
      );

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await container.read(settingsProvider.notifier).debugBackendSyncDone;

      expect(container.read(settingsProvider).value!.streamQuality, '128');
      expect(prefs.getString('settings.streamQuality'), '128');
    });

    test('backend reconcile leaves streamQualityChangeKind null (no rebuild)',
        () async {
      // A silent backend sync must not look like a user change-kind, or the
      // QueuePlayer would rebuild the whole playlist on startup.
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      api = testApiClient(
        'http://localhost:8000',
        MockClient((_) async => qualityResponse('128')),
      );

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await container.read(settingsProvider.notifier).debugBackendSyncDone;

      expect(container.read(settingsProvider).value!.streamQuality, '128');
      expect(
        container.read(settingsProvider).value!.streamQualityChangeKind,
        isNull,
      );
    });

    test('backend timeout leaves AppSettings on the cached pref, not loading',
        () async {
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '320'});
      final prefs = await SharedPreferences.getInstance();
      // MockClient hangs forever — the per-attempt timeout in the
      // RetryPolicy must kick in (the outer .timeout() is gone).
      api = testApiClient(
        'http://localhost:8000',
        MockClient((_) => Completer<http.Response>().future),
      );
      SettingsNotifier.backendSyncTimeout = const Duration(milliseconds: 50);

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      final settings = await container.read(settingsProvider.future);
      expect(settings.streamQuality, '320');
      // After the timeout fires the reconcile completes — the AsyncValue
      // must not be left in AsyncLoading.
      await container.read(settingsProvider.notifier).debugBackendSyncDone;
      expect(container.read(settingsProvider).hasValue, isTrue);
      expect(container.read(settingsProvider).value!.streamQuality, '320');
    });

    test('backend network failure leaves cached pref in place', () async {
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      api = testApiClient(
        'http://localhost:8000',
        MockClient((_) async => throw Exception('network error')),
      );

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      final settings = await container.read(settingsProvider.future);
      expect(settings.streamQuality, '256');
      await container.read(settingsProvider.notifier).debugBackendSyncDone;
      expect(container.read(settingsProvider).value!.streamQuality, '256');
    });

    test('backend returns invalid quality → local value kept', () async {
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      api = testApiClient(
        'http://localhost:8000',
        MockClient((_) async => http.Response(
              jsonEncode({'quality': '999'}),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await container.read(settingsProvider.notifier).debugBackendSyncDone;
      expect(container.read(settingsProvider).value!.streamQuality, '256');
    });

    test('no server URL configured → no HTTP request made, local value kept',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      var requestCount = 0;
      api = testApiClient(
        '',
        MockClient((_) async {
          requestCount++;
          return qualityResponse('128');
        }),
      );

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      final settings = await container.read(settingsProvider.future);
      await container.read(settingsProvider.notifier).debugBackendSyncDone;

      expect(requestCount, 0);
      expect(settings.streamQuality, originalQuality);
    });

    test('late backend reconcile does not clobber concurrent user choice',
        () async {
      // Regression: the user changes quality while the post-build GET is
      // still in flight. The late GET must not clobber the user's choice.
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();

      final getCompleter = Completer<http.Response>();
      api = testApiClient(
        'http://localhost:8000',
        MockClient((req) async {
          if (req.method == 'PUT') return http.Response('{}', 200);
          return getCompleter.future;
        }),
      );
      SettingsNotifier.backendSyncTimeout = const Duration(seconds: 5);

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      // build() publishes local prefs immediately.
      final settings = await container.read(settingsProvider.future);
      expect(settings.streamQuality, '256');

      // User picks "128" before the build-time GET resolves.
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setStreamQualityFull('128');
      expect(container.read(settingsProvider).value!.streamQuality, '128');

      // The build-time GET finally returns the OLD server value ("256").
      getCompleter.complete(qualityResponse('256'));
      await notifier.debugBackendSyncDone;

      // The user's choice survives — the reconcile detects the in-memory
      // persistedStreamQuality moved off `initial` and aborts.
      expect(container.read(settingsProvider).value!.streamQuality, '128');
    });

    // U22-FE-LIFECYCLE-A-01: the stored value is read at the next start, so
    // a late answer must not overwrite it after the user chose, after a
    // reset wiped the prefs, or once the notifier is gone.
    group('a late backend answer writes nothing to the prefs', () {
      late Completer<http.Response> getCompleter;

      setUp(() {
        getCompleter = Completer<http.Response>();
        api = testApiClient(
          'http://localhost:8000',
          MockClient((req) async {
            if (req.method == 'PUT') return http.Response('{}', 200);
            return getCompleter.future;
          }),
        );
        SettingsNotifier.backendSyncTimeout = const Duration(seconds: 5);
      });

      test('when the user chose meanwhile', () async {
        SharedPreferences.setMockInitialValues(
            {'settings.streamQuality': '256'});
        final prefs = await SharedPreferences.getInstance();
        final container = await _containerWith(prefs);
        addTearDown(container.dispose);
        await container.read(settingsProvider.future);
        final notifier = container.read(settingsProvider.notifier);
        await notifier.setStreamQualityFull('128');
        expect(prefs.getString('settings.streamQuality'), '128');

        getCompleter.complete(qualityResponse('256'));
        await notifier.debugBackendSyncDone;
        expect(prefs.getString('settings.streamQuality'), '128',
            reason: "the next start must read the user's choice");
      });

      test('when a reset happened meanwhile', () async {
        final prefs = await SharedPreferences.getInstance();
        late _Resets resets;
        final container = await _containerWith(prefs, extra: [
          localResetServiceProvider.overrideWith((ref) => resets = _Resets(ref)),
        ]);
        addTearDown(container.dispose);
        container.read(localResetServiceProvider);
        await container.read(settingsProvider.future);
        final notifier = container.read(settingsProvider.notifier);
        await pumpEventQueue(); // the GET is in flight

        resets.gen++; // a reset starts and wipes the prefs
        await prefs.clear();
        getCompleter.complete(qualityResponse('256'));
        await notifier.debugBackendSyncDone;
        expect(prefs.getString('settings.streamQuality'), isNull,
            reason: "the old server's quality must not survive the reset");
      });

      // Pre-merge review A5-04: the same rule for "Set as default": its PUT
      // answered after a reset (Disconnect wiped the prefs) writes nothing.
      test('a Set as default answered after a reset writes nothing', () async {
        final putCompleter = Completer<http.Response>();
        api = testApiClient(
          'http://localhost:8000',
          MockClient((req) async {
            if (req.method == 'PUT') return putCompleter.future;
            return getCompleter.future;
          }),
        );
        final prefs = await SharedPreferences.getInstance();
        late _Resets resets;
        final container = await _containerWith(prefs, extra: [
          localResetServiceProvider.overrideWith((ref) => resets = _Resets(ref)),
        ]);
        addTearDown(container.dispose);
        container.read(localResetServiceProvider);
        await container.read(settingsProvider.future);
        final notifier = container.read(settingsProvider.notifier);
        final before = container.read(settingsProvider).value!;
        final set = notifier.setStreamQualityFull('128');
        await pumpEventQueue(); // the PUT is in flight

        resets.gen++; // a reset starts and wipes the prefs
        await prefs.clear();
        putCompleter.complete(http.Response('{}', 200));
        await set;
        expect(prefs.getString('settings.streamQuality'), isNull,
            reason: "the old server's quality must not survive the reset");
        expect(container.read(settingsProvider).value!.persistedStreamQuality,
            before.persistedStreamQuality);
        getCompleter.complete(qualityResponse(originalQuality));
        await notifier.debugBackendSyncDone;
      });

      test('when the notifier is gone', () async {
        final prefs = await SharedPreferences.getInstance();
        final container = await _containerWith(prefs);
        await container.read(settingsProvider.future);
        final done = container.read(settingsProvider.notifier).debugBackendSyncDone;
        await pumpEventQueue(); // the GET is in flight
        container.dispose();

        getCompleter.complete(qualityResponse(originalQuality));
        await done;
        expect(prefs.getString('settings.streamQuality'), isNull);
      });
    });

    test('streamQualityProvider reflects local pref before backend resolves',
        () async {
      // Direct regression for issue #15: settings consumers must NOT see
      // `original` while the backend sync is in flight.
      SharedPreferences.setMockInitialValues({
        'settings.streamQuality': '256',
        'settings.downloadQuality': '320',
      });
      final prefs = await SharedPreferences.getInstance();
      final getCompleter = Completer<http.Response>();
      api = testApiClient(
        'http://localhost:8000',
        MockClient((_) => getCompleter.future),
      );

      final container = await _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      // Backend still hanging — the providers must already reflect the
      // cached prefs, not the `original` fallback.
      expect(container.read(streamQualityProvider), '256');
      expect(container.read(downloadQualityProvider), '320');

      getCompleter.complete(http.Response(
        jsonEncode({'quality': '192'}),
        200,
        headers: {'content-type': 'application/json'},
      ));
      await container.read(settingsProvider.notifier).debugBackendSyncDone;
      expect(container.read(streamQualityProvider), '192');
      // Download quality is local-only — unaffected by the backend sync.
      expect(container.read(downloadQualityProvider), '320');
    });
  });
}
