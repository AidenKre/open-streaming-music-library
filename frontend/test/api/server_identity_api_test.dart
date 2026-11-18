// Phase M §7.4 / decision O3 (DEV-M-03): the pre-session `/app/info` probe
// returns the server's `instance_id` AND its `auth.version`, so `connect`
// (M.3c) can reject a pre-M server. Read straight from `/app/info`, no
// SC-03 typed feature-block parser. A missing block is unknown (null),
// never 0; a mistyped one is an error.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ServerIdentityApi _api(Object body) => ServerIdentityApi(
      api: testApiClient(
        'http://srv:1',
        MockClient((request) async {
          expect(request.url.path, '/app/info');
          return http.Response(jsonEncode(body), 200);
        }),
      ),
    );

void main() {
  test('a Phase M server reports its instance id and auth version 1',
      () async {
    final identity = await _api({
      'server': {'instance_id': 'inst-1'},
      'auth': {'version': 1, 'signup_enabled': true},
    }).fetch();
    expect(identity.instanceId, 'inst-1');
    expect(identity.authVersion, 1);
  });

  test('a pre-M server without the auth block has an unknown auth version',
      () async {
    final identity = await _api({
      'server': {'instance_id': 'inst-1'},
    }).fetch();
    expect(identity.instanceId, 'inst-1');
    expect(identity.authVersion, isNull);
  });

  test('a future auth version is reported as is', () async {
    final identity = await _api({
      'server': {'instance_id': 'inst-1'},
      'auth': {'version': 2},
    }).fetch();
    expect(identity.authVersion, 2);
  });

  test('a mistyped auth block is an error, not a version', () async {
    for (final auth in [
      {'version': '1'},
      {'version': 1.5},
      'v1',
      {'signup_enabled': true},
    ]) {
      await expectLater(
        _api({
          'server': {'instance_id': 'inst-1'},
          'auth': auth,
        }).fetch(),
        throwsA(isA<FormatException>()),
        reason: '$auth',
      );
    }
  });
}
