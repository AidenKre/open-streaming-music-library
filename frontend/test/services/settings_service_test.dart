import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/settings_service.dart';

ProviderContainer _containerWith(SharedPreferences prefs) {
  return ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWith((_) async => prefs),
  ]);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // build() no longer awaits the backend sync, but the per-attempt
    // timeout still bounds the reconcile in flight — keep it tight in
    // tests so timeout cases run fast. Production default is 3s.
    SettingsNotifier.backendSyncTimeout = const Duration(milliseconds: 200);
  });

  tearDown(() {
    // Reset ApiClient so cross-test state doesn't bleed.
    ApiClient.init('');
  });

  test('build returns original/original on first launch', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _containerWith(prefs);
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
    final container = _containerWith(prefs);
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
    final container = _containerWith(prefs);
    addTearDown(container.dispose);

    final settings = await container.read(settingsProvider.future);
    expect(settings.streamQuality, originalQuality);
    expect(settings.downloadQuality, originalQuality);
  });

  test('setStreamQualityFull persists and updates state', () async {
    final prefs = await SharedPreferences.getInstance();
    // Backend PUT must succeed for persistence to happen.
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => http.Response('{}', 200)),
    );
    final container = _containerWith(prefs);
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
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => http.Response('{}', 200)),
    );
    final container = _containerWith(prefs);
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
    final container = _containerWith(prefs);
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
    final container = _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    expect(container.read(streamQualityProvider), '256');

    container.read(settingsProvider.notifier).setStreamQualityTemporary('128');
    expect(container.read(streamQualityProvider), '128');
  });

  test('setDownloadQuality persists and updates state', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    await container.read(settingsProvider.notifier).setDownloadQuality('128');

    expect(prefs.getString('settings.downloadQuality'), '128');
    expect(
      container.read(settingsProvider).value!.downloadQuality,
      '128',
    );
  });

  test('setStreamQualityFull rejects invalid values', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    expect(
      () => container.read(settingsProvider.notifier).setStreamQualityFull('hi-res'),
      throwsArgumentError,
    );
  });

  test('setStreamQualityTemporary rejects invalid values', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _containerWith(prefs);
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
    final container = _containerWith(prefs);
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    expect(container.read(streamQualityProvider), '256');
    expect(container.read(downloadQualityProvider), '320');
  });

  group('setStreamQualityFull backend-first persistence', () {
    test('PUT failure: in-memory state updates, prefs NOT written', () async {
      // Pref starts at 256; user picks 128 but the backend PUT fails.
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      // GET (build-time sync) returns 256; PUT 500s on every retry.
      ApiClient.initForTest(
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

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await container.read(settingsProvider.notifier).setStreamQualityFull('128');

      // In-memory: user's choice is visible (UI feedback) ...
      expect(container.read(settingsProvider).value!.streamQuality, '128');
      // ... but the pref is unchanged (still the pre-call value).
      expect(prefs.getString('settings.streamQuality'), '256');
    });

    test('PUT success: prefs are written and state updates', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      ApiClient.initForTest(
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

      final container = _containerWith(prefs);
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
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) => getCompleter.future),
      );

      final container = _containerWith(prefs);
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

    test('backend reconcile updates state to backend value', () async {
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async => qualityResponse('128')),
      );

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await container.read(settingsProvider.notifier).debugBackendSyncDone;

      expect(container.read(settingsProvider).value!.streamQuality, '128');
      expect(prefs.getString('settings.streamQuality'), '128');
    });

    test('backend reconcile leaves streamQualityChangeKind null (no rebuild)',
        () async {
      // A silent backend sync must not look like a user change-kind, or the
      // AudioCoordinator would rebuild the whole playlist on startup.
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async => qualityResponse('128')),
      );

      final container = _containerWith(prefs);
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
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) => Completer<http.Response>().future),
      );
      SettingsNotifier.backendSyncTimeout = const Duration(milliseconds: 50);

      final container = _containerWith(prefs);
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
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async => throw Exception('network error')),
      );

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      final settings = await container.read(settingsProvider.future);
      expect(settings.streamQuality, '256');
      await container.read(settingsProvider.notifier).debugBackendSyncDone;
      expect(container.read(settingsProvider).value!.streamQuality, '256');
    });

    test('backend returns invalid quality → local value kept', () async {
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async => http.Response(
              jsonEncode({'quality': '999'}),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      final container = _containerWith(prefs);
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
      ApiClient.initForTest(
        '',
        MockClient((_) async {
          requestCount++;
          return qualityResponse('128');
        }),
      );

      final container = _containerWith(prefs);
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
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          if (req.method == 'PUT') return http.Response('{}', 200);
          return getCompleter.future;
        }),
      );
      SettingsNotifier.backendSyncTimeout = const Duration(seconds: 5);

      final container = _containerWith(prefs);
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
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) => getCompleter.future),
      );

      final container = _containerWith(prefs);
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
