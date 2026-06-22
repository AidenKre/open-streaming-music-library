import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/app_info_service.dart';

class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

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

ProviderContainer _container({required bool offline}) {
  final c = ProviderContainer(overrides: [
    offlineModeProvider.overrideWith(() => _StubOffline(offline)),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('online: refreshes from the server and caches the blob', () async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.initForTest(
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

  test('offline: falls back to the cached blob', () async {
    SharedPreferences.setMockInitialValues({
      'appInfo.cache': jsonEncode(_appInfoJson(['title'])),
    });
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((req) async => http.Response('boom', 500)),
    );

    final info = await _container(offline: true).read(appInfoProvider.future);
    expect(info.entity('track')!.fields.map((f) => f.key), ['title']);
  });

  test('cold offline with no cache: conservative built-in default', () async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((req) async => http.Response('boom', 500)),
    );

    final info = await _container(offline: true).read(appInfoProvider.future);
    expect(editableFieldsFor(info, 'track').length, 9);
  });
}
