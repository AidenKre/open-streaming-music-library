import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/local_reset_service.dart';
import '../helpers/test_offline.dart';

Map<String, dynamic> _appInfoJson(List<String> fieldKeys) => {
      'entities': {
        'track': {
          'fields': [
            for (final k in fieldKeys)
              {'key': k, 'label': k, 'valueType': 'text', 'editable': true},
          ],
          'actions': [],
        },
      },
    };

ApiClient api = testApiClient('', MockClient((_) async => throw StateError('unset')));

/// A reset service whose generation the test bumps, as a reset that has
/// just begun does (before its first await).
class _Resets extends LocalResetService {
  _Resets(super.ref);
  int gen = 0;
  @override
  int get generation => gen;
}

ProviderContainer _container({
  required bool offline,
  List<Override> extra = const [],
}) {
  final c = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(api),
    offlineModeProvider.overrideWith(() => TestOffline(offline)),
    ...extra,
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('online: refreshes from the server and caches the blob', () async {
    SharedPreferences.setMockInitialValues({});
    api = testApiClient(
      'http://localhost:8000',
      MockClient((req) async {
        expect(req.url.path, '/app/info');
        return http.Response(jsonEncode(_appInfoJson(['title', 'artist'])), 200,
            headers: {'content-type': 'application/json'});
      }),
    );

    final info = await _container(offline: false).read(appInfoProvider.future);
    expect(info.entity('track')!.fields.map((f) => f.key), ['title', 'artist']);

    // Cached for offline restarts.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('appInfo.cache'), isNotNull);
  });

  // One server's capabilities must not be what the next
  // server's offline start reads.
  test('an answer that arrives after a reset began is not cached', () async {
    SharedPreferences.setMockInitialValues({});
    final response = Completer<http.Response>();
    api = testApiClient(
      'http://localhost:8000',
      MockClient((req) => response.future),
    );
    late _Resets resets;
    final container = _container(offline: false, extra: [
      localResetServiceProvider.overrideWith((ref) => resets = _Resets(ref)),
    ]);
    container.read(localResetServiceProvider);
    final sub = container.listen(appInfoProvider.future, (_, _) {});
    addTearDown(sub.close);
    final loaded = sub.read();
    await pumpEventQueue(); // the GET is in flight

    resets.gen++; // a reset begins and wipes the prefs
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    response.complete(http.Response(
        jsonEncode(_appInfoJson(['title', 'artist'])), 200,
        headers: {'content-type': 'application/json'}));
    await loaded;

    expect(prefs.getString('appInfo.cache'), isNull,
        reason: "the old server's capabilities must not survive the reset");
  });

  test('offline: falls back to the cached blob', () async {
    SharedPreferences.setMockInitialValues({
      'appInfo.cache': jsonEncode(_appInfoJson(['title'])),
    });
    api = testApiClient(
      'http://localhost:8000',
      MockClient((req) async => http.Response('boom', 500)),
    );

    final info = await _container(offline: true).read(appInfoProvider.future);
    expect(info.entity('track')!.fields.map((f) => f.key), ['title']);
  });

  // U22-FE-LIFECYCLE-B-02: one malformed answer must not replace the good
  // cached copy (offline would then fall back to the built-in defaults).
  test('a malformed answer keeps the good cache', () async {
    final good = jsonEncode(_appInfoJson(['title']));
    SharedPreferences.setMockInitialValues({'appInfo.cache': good});
    api = testApiClient(
      'http://localhost:8000',
      MockClient((req) async => http.Response(
            jsonEncode({
              'entities': {
                'track': {
                  'fields': [
                    {'key': 42, 'label': 'x', 'valueType': 'text'},
                  ],
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );

    final info = await _container(offline: false).read(appInfoProvider.future);
    expect(info.entity('track')!.fields.map((f) => f.key), ['title'],
        reason: 'falls back to the cached copy');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('appInfo.cache'), good);
  });

  test('cold offline with no cache: conservative built-in default', () async {
    SharedPreferences.setMockInitialValues({});
    api = testApiClient(
      'http://localhost:8000',
      MockClient((req) async => http.Response('boom', 500)),
    );

    final info = await _container(offline: true).read(appInfoProvider.future);
    expect(editableFieldsFor(info, 'track').length, 9);
  });
}
