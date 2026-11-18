// Phase 9D.2d (SC-03, D23): `integrationsFeatureProvider`, same provenance
// rules as the other feature providers: the block the server sent on this
// read is `fromCache: false`; one read from the prefs cache (offline, or a
// failed refresh) is `fromCache: true` and `featureForNetwork` refuses it,
// so a cached block never starts network work.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/feature_providers.dart';

class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() {
    super.build();
    return _value;
  }
}

const _blob = {
  'entities': {},
  'history': {'version': 1},
  'integrations': {
    'version': 1,
    'lastfm': {'available': true},
  },
};

ProviderContainer _container({
  required bool offline,
  required http.Response Function() server,
}) {
  final api = testApiClient(
    'http://localhost:8000',
    MockClient((req) async => server()),
  );
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    offlineModeProvider.overrideWith(() => _StubOffline(offline)),
  ]);
  addTearDown(c.dispose);
  return c;
}

/// Riverpod 3 pauses an unlistened provider: listen, then await.
Future<T> _read<T>(ProviderContainer c, FutureProvider<T> p) {
  c.listen(p, (_, _) {});
  return c.read(p.future);
}

void main() {
  test('online: the block the server sent, usable for network work',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = _container(
      offline: false,
      server: () => http.Response(jsonEncode(_blob), 200),
    );

    final advertised = await _read(c, integrationsFeatureProvider);

    expect(advertised!.fromCache, isFalse);
    expect(advertised.block.lastfm!.available, isTrue);
    expect(featureForNetwork(advertised), same(advertised.block));
  });

  test('offline: the cached block is shown but never enables network work',
      () async {
    SharedPreferences.setMockInitialValues(
        {'appInfo.cache': jsonEncode(_blob)});
    final c = _container(
      offline: true,
      server: () => throw StateError('offline: no request'),
    );

    final advertised = await _read(c, integrationsFeatureProvider);

    expect(advertised!.fromCache, isTrue);
    expect(advertised.block.lastfm!.available, isTrue);
    expect(featureForNetwork(advertised), isNull);
  });

  test('a failed refresh falls back to the cache: fromCache', () async {
    SharedPreferences.setMockInitialValues(
        {'appInfo.cache': jsonEncode(_blob)});
    final c = _container(offline: false, server: () => http.Response('x', 500));

    final advertised = await _read(c, integrationsFeatureProvider);
    expect(advertised!.fromCache, isTrue);
    expect(featureForNetwork(advertised), isNull);
  });

  test('a server without the block: absent; other features unaffected',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = _container(
      offline: false,
      server: () => http.Response(
        jsonEncode({
          'entities': {},
          'history': {'version': 1},
        }),
        200,
      ),
    );

    expect(await _read(c, integrationsFeatureProvider), isNull);
    expect(featureForNetwork<IntegrationsFeature>(null), isNull);
    expect(await _read(c, historyFeatureProvider), isNotNull);
  });
}
