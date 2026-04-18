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

  group('syncQualityFromBackend', () {
    http.Response _qualityResponse(String quality) => http.Response(
          jsonEncode({'quality': quality}),
          200,
          headers: {'content-type': 'application/json'},
        );

    tearDown(() {
      // Reset ApiClient to empty state so other tests aren't affected.
      ApiClient.init('');
    });

    test('backend returns different quality → state updated and persisted',
        () async {
      SharedPreferences.setMockInitialValues(
          {'settings.streamQuality': originalQuality});
      final prefs = await SharedPreferences.getInstance();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async => _qualityResponse('128')),
      );

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      // Allow the fire-and-forget sync to complete.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(streamQualityProvider), '128');
      expect(prefs.getString('settings.streamQuality'), '128');
    });

    test('backend returns same quality → no state change', () async {
      SharedPreferences.setMockInitialValues(
          {'settings.streamQuality': '128'});
      final prefs = await SharedPreferences.getInstance();

      var calls = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async {
          calls++;
          return _qualityResponse('128');
        }),
      );

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Quality unchanged — no unnecessary state emission.
      expect(container.read(streamQualityProvider), '128');
      expect(calls, 1); // request was still made; just no state update
    });

    test('backend unreachable → local value kept', () async {
      SharedPreferences.setMockInitialValues(
          {'settings.streamQuality': '256'});
      final prefs = await SharedPreferences.getInstance();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async => throw Exception('network error')),
      );

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(streamQualityProvider), '256');
    });

    test('first-time launch (no pref) + backend returns "128"', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async => _qualityResponse('128')),
      );

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(streamQualityProvider), '128');
      expect(prefs.getString('settings.streamQuality'), '128');
    });

    test('no server URL configured → no HTTP request made', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      var requestCount = 0;
      ApiClient.initForTest(
        '',
        MockClient((_) async {
          requestCount++;
          return _qualityResponse('128');
        }),
      );

      final container = _containerWith(prefs);
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(requestCount, 0);
      expect(container.read(streamQualityProvider), originalQuality);
    });

    test('backend returns invalid quality string → local value kept', () async {
      SharedPreferences.setMockInitialValues(
          {'settings.streamQuality': '256'});
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
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(streamQualityProvider), '256');
    });
  });
}
