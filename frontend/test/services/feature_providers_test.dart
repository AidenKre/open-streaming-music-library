// Phase 7B.1a (D23, SC-03): one provider per feature, with provenance.
//  * `historyFeatureProvider` / `uploadsFeatureProvider` expose the typed
//    block of the scope's app info, or null when the server doesn't
//    advertise it (or advertises it malformed);
//  * a block read from the prefs-cached blob (offline, or the refresh
//    failed) is marked `fromCache`: the UI may still show the feature, but
//    the cached blob never enables a network action by itself; only a block
//    the server sent on this read is `fromCache: false`;
//  * the built-in default (cold offline, no cache) advertises no feature.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/app_info_service.dart';
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
  'uploads': {
    'version': 1,
    'limits': {'max_files_per_batch': 100, 'receives_per_user': 1},
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

http.Response _ok() => http.Response(jsonEncode(_blob), 200,
    headers: {'content-type': 'application/json'});

void main() {
  test('online: the blocks the server sent now, not from the cache', () async {
    SharedPreferences.setMockInitialValues({});
    final c = _container(offline: false, server: _ok);

    final uploads = await _read(c, uploadsFeatureProvider);
    final history = await _read(c, historyFeatureProvider);

    expect(uploads!.fromCache, isFalse);
    expect(uploads.block.limits.maxFilesPerBatch, 100);
    expect(uploads.block.limits.receivesPerUser, 1);
    expect(history!.fromCache, isFalse);
    expect(history.block.version, 1);
  });

  test('offline: the cached blob shows the feature but is marked fromCache',
      () async {
    SharedPreferences.setMockInitialValues({'appInfo.cache': jsonEncode(_blob)});
    final c = _container(
      offline: true,
      server: () => throw StateError('offline: no request'),
    );

    final uploads = await _read(c, uploadsFeatureProvider);

    expect(uploads, isNotNull);
    expect(uploads!.fromCache, isTrue);
    expect(uploads.block.limits.maxFilesPerBatch, 100);
  });

  test('a failed refresh falls back to the cache: fromCache', () async {
    SharedPreferences.setMockInitialValues({'appInfo.cache': jsonEncode(_blob)});
    final c = _container(offline: false, server: () => http.Response('x', 500));

    expect((await _read(c, uploadsFeatureProvider))!.fromCache, isTrue);
    expect((await _read(c, appInfoProvider)).fromCache, isTrue);
  });

  test('cold offline without a cache: the default advertises nothing',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = _container(
      offline: true,
      server: () => throw StateError('offline: no request'),
    );

    expect(await _read(c, uploadsFeatureProvider), isNull);
    expect(await _read(c, historyFeatureProvider), isNull);
  });

  test('a server without the blocks (or a malformed one) has no feature',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = _container(
      offline: false,
      server: () => http.Response(
        jsonEncode({
          'entities': {},
          'uploads': {'version': 1}, // no limits object
        }),
        200,
      ),
    );

    expect(await _read(c, uploadsFeatureProvider), isNull);
    expect(await _read(c, historyFeatureProvider), isNull);
  });

  test('an overridden app info (tests, older code paths) is not a cache read',
      () async {
    final c = ProviderContainer(overrides: [
      appInfoProvider.overrideWith(
        (ref) async => AppInfo.fromJson({'history': {'version': 1}}),
      ),
    ]);
    addTearDown(c.dispose);

    final history = await _read(c, historyFeatureProvider);
    expect(history!.fromCache, isFalse);
  });
}
