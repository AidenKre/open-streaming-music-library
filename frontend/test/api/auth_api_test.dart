// Phase M §5.2 / §7.1 (M-U19 model): `AuthApi` wraps register, login,
// logout and me. Register (201) and login (200) answer
// `{token, media_token, server_instance_id, user: {id, username, is_admin,
// is_master_admin}}`; errors use the SC-22 `detail` envelope and surface as
// `ApiException` with the server's code and message; a login is one attempt
// (never retried) and its password never reaches a log. Logout and me are
// written against spec §5.2 (M.1b builds them on the server).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/auth_api.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = {
  'token': 'api-token-A',
  'media_token': 'media-token-A',
  'server_instance_id': 'inst-1',
  'user': {
    'id': 7,
    'username': 'alice',
    'is_admin': false,
    'is_master_admin': false,
  },
};

Map<String, Object> _error(String code, String message, {bool? retryable}) => {
      'detail': {
        'error': code,
        'message': message,
        'retryable': ?retryable,
      },
    };

void main() {
  late List<http.Request> requests;
  late List<String> logs;

  setUp(() {
    requests = [];
    logs = [];
  });

  AuthApi api(int status, Object body) {
    final client = testApiClient(
      'http://srv:1',
      MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode(body), status);
      }),
    )..setLogSinkForTest(logs.add);
    return AuthApi(client);
  }

  group('login', () {
    test('posts the username and password and returns the session',
        () async {
      final session = await api(200, _session).login('alice', 'pw-secret-1');
      final r = requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/auth/login');
      expect(jsonDecode(r.body), {
        'username': 'alice',
        'password': 'pw-secret-1',
      });
      expect(
        session.credentials,
        const Credentials(
          token: 'api-token-A',
          mediaToken: 'media-token-A',
          userId: 7,
          username: 'alice',
        ),
      );
      expect(session.serverInstanceId, 'inst-1');
      expect(session.user.id, 7);
      expect(session.user.isAdmin, isFalse);
      expect(session.user.isMasterAdmin, isFalse);
    });

    test('a wrong password is an ApiException with the server code and '
        'message', () async {
      await expectLater(
        api(401, _error('invalid_credentials', 'Wrong username or password'))
            .login('alice', 'nope-nope'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.errorCode, 'code', 'invalid_credentials')
            .having((e) => e.detailMessage, 'message',
                'Wrong username or password')),
      );
    });

    test('a busy server (503 auth_busy) is one attempt, not retried',
        () async {
      await expectLater(
        api(503, _error('auth_busy', 'Try again', retryable: true))
            .login('alice', 'pw-secret-1'),
        throwsA(isA<ApiException>()
            .having((e) => e.errorCode, 'code', 'auth_busy')
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
      expect(requests, hasLength(1));
    });

    test('the password never reaches a log', () async {
      await api(200, _session).login('alice', 'pw-secret-1');
      await expectLater(
        api(401, _error('invalid_credentials', 'x')).login('alice', 'pw-2-x'),
        throwsA(isA<ApiException>()),
      );
      for (final line in logs) {
        expect(line, isNot(contains('pw-secret-1')));
        expect(line, isNot(contains('pw-2-x')));
        expect(line, isNot(contains('api-token-A')));
      }
      expect(logs, isNotEmpty, reason: 'the client did log the calls');
    });

    test('a malformed success body is a FormatException', () async {
      for (final body in [
        {..._session}..remove('token'),
        {..._session, 'media_token': 5},
        {..._session}..remove('server_instance_id'),
        {..._session, 'user': {'id': '7', 'username': 'alice'}},
        {..._session, 'token': ''},
        {..._session, 'media_token': ''},
      ]) {
        await expectLater(
          api(200, body).login('alice', 'pw-secret-1'),
          throwsA(isA<FormatException>()),
          reason: '$body',
        );
      }
    });
  });

  group('register', () {
    test('posts to /auth/register and returns the session (201)', () async {
      final session =
          await api(201, _session).register('alice', 'pw-secret-1');
      final r = requests.single;
      expect(r.url.path, '/auth/register');
      expect(jsonDecode(r.body), {
        'username': 'alice',
        'password': 'pw-secret-1',
      });
      expect(session.credentials.token, 'api-token-A');
      expect(session.serverInstanceId, 'inst-1');
    });

    test('a taken username surfaces the server code', () async {
      await expectLater(
        api(409, _error('username_taken', 'That username is taken'))
            .register('alice', 'pw-secret-1'),
        throwsA(isA<ApiException>()
            .having((e) => e.errorCode, 'code', 'username_taken')),
      );
      expect(requests, hasLength(1));
    });
  });

  group('logout', () {
    test('posts to /auth/logout', () async {
      await api(200, const <String, Object>{}).logout();
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/auth/logout');
    });

    test('an explicit bearer token is sent as the header (the cancel-time '
        'revoke through the unhooked client)', () async {
      await api(200, const <String, Object>{})
          .logout(bearerToken: 'api-token-B');
      expect(
        requests.single.headers['Authorization'],
        'Bearer api-token-B',
      );
      expect(requests.single.url.toString(), isNot(contains('api-token-B')));
    });
  });

  group('me', () {
    test('reads the signed-in user and the instance id', () async {
      final me = await api(200, {
        'server_instance_id': 'inst-1',
        'user': {
          'id': 1,
          'username': 'admin',
          'is_admin': true,
          'is_master_admin': true,
        },
      }).me();
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/auth/me');
      expect(me.serverInstanceId, 'inst-1');
      expect(me.user.username, 'admin');
      expect(me.user.isAdmin, isTrue);
      expect(me.user.isMasterAdmin, isTrue);
    });
  });
}
