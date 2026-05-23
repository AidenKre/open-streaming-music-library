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
    // build() awaits the backend sync — keep it tight in tests so timeout
    // cases run fast. Production default is 3s.
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

  group('build awaits backend sync', () {
    http.Response qualityResponse(String quality) => http.Response(
          jsonEncode({'quality': quality}),
          200,
          headers: {'content-type': 'application/json'},
        );

    test('build uses backend value as initial state', () async {
      // Local pref is "256"; backend says "128" — build() must return "128".
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async => qualityResponse('128')),
      );

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      // The very first read of state after build() resolves should be "128",
      // not "256" — i.e. the sync was awaited.
      final settings = await container.read(settingsProvider.future);
      expect(settings.streamQuality, '128');
      expect(prefs.getString('settings.streamQuality'), '128');
    });

    test('backend timeout falls back to cached pref', () async {
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '320'});
      final prefs = await SharedPreferences.getInstance();
      // MockClient hangs forever — the timeout in build() must kick in.
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) => Completer<http.Response>().future),
      );
      // Use a very tight timeout so the test runs quickly.
      SettingsNotifier.backendSyncTimeout = const Duration(milliseconds: 50);

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      final settings = await container.read(settingsProvider.future);
      expect(settings.streamQuality, '320');
    });

    test('backend network failure falls back to cached pref', () async {
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

      final settings = await container.read(settingsProvider.future);
      expect(settings.streamQuality, '256');
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

      expect(requestCount, 0);
      expect(settings.streamQuality, originalQuality);
    });

    test('build does not race with a concurrent setStreamQualityFull',
        () async {
      // Regression for the prior fire-and-forget bug: the user changes
      // quality before the build-time GET resolves. The late GET must not
      // clobber the user's choice.
      SharedPreferences.setMockInitialValues({'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();

      final getCompleter = Completer<http.Response>();
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          if (req.method == 'PUT') return http.Response('{}', 200);
          // GET resolves only when we release it.
          return getCompleter.future;
        }),
      );
      // Long backend sync timeout so the GET stays pending while we test.
      SettingsNotifier.backendSyncTimeout = const Duration(seconds: 5);

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      // Start build() but don't await it yet — kick it off.
      final buildFuture = container.read(settingsProvider.future);

      // While build() is awaiting the GET, the user picks "128" — the PUT
      // succeeds and the in-memory state updates.
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setStreamQualityFull('128');
      expect(container.read(settingsProvider).value!.streamQuality, '128');

      // Now the GET finally returns the OLD server value ("256"). In the
      // old fire-and-forget code, this would clobber the user's "128".
      getCompleter.complete(qualityResponse('256'));
      await buildFuture;

      // Because build() now awaits the GET as part of its return value
      // (returning a merged snapshot) and the post-build user choice
      // overwrites that snapshot, the user's choice survives.
      expect(container.read(settingsProvider).value!.streamQuality, '128');
    });
  });
}

