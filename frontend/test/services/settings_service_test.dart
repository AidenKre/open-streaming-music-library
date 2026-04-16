import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
