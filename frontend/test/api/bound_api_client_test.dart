// Phase 7B.1a-f1 (SC-01 rule 6 for writes; 7B.1a review #1): the bound API
// client checks the `X-Server-Instance-Id` stamp of EVERY response it gets
// (any verb, any status) against the bound instance before anything reads
// the response:
//  * a stamp naming another instance throws ServerInstanceChangedException:
//    no body is returned, no ApiException is raised (the caller's error
//    branches never run), and the request is not retried, so nothing
//    further is sent;
//  * no stamp (a pre-Phase-7 server), a matching stamp (any case, extra
//    whitespace, a proxy-repeated "a, a"), an unbound row (NULL instance)
//    or no row at all (a reset) leave the request exactly as today;
//  * the scope's plain client is not affected.
// The primitive is what a new write path (7B.1c/7B.1d uploads) builds on, so
// these cases use verbs and routes no current caller uses.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/server_binding.dart';

const _bound = '3f1c2a9e-7b4d-4e2a-9c1f-0a1b2c3d4e5f';
const _other = '9d8e7f6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a';

void main() {
  late AppDatabase db;
  late ProviderContainer c;
  late List<http.BaseRequest> sent;
  late http.Response Function(http.Request req) answer;
  late ApiClient plain;

  http.Response stamped(
    Object? body,
    int status,
    String? stamp,
  ) => http.Response(
    jsonEncode(body),
    status,
    headers: {
      'content-type': 'application/json',
      'x-server-instance-id': ?stamp,
    },
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sent = [];
    answer = (_) => stamped({'ok': true}, 200, null);
    plain = testApiClient(
      'http://s',
      MockClient((req) async {
        sent.add(req);
        return answer(req);
      }),
    );
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(plain),
      ],
    );
  });

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  ApiClient bound() => c.read(boundApiClientProvider);

  group('bound to an instance', () {
    setUp(() => seedTestBinding(db, baseUrl: 'http://s', instanceId: _bound));

    test('a 200 stamped by another instance is not returned', () async {
      answer = (_) => stamped({'acknowledged': ['e1']}, 200, _other);

      await expectLater(
        bound().postJson(['uploads', 'batches'], body: {'n': 1}),
        throwsA(
          isA<ServerInstanceChangedException>()
              .having((e) => e.servedBy, 'servedBy', _other)
              .having((e) => e.boundInstanceId, 'bound', _bound),
        ),
      );
      expect(sent, hasLength(1));
    });

    test('an error status stamped by another instance is not an ApiException',
        () async {
      for (final status in [409, 404, 410, 413, 422]) {
        answer = (_) => stamped({'detail': 'nope'}, status, _other);
        await expectLater(
          bound().putJson(['uploads', 'items', 'i1'], body: {'n': 1}),
          throwsA(isA<ServerInstanceChangedException>()),
          reason: 'status $status',
        );
      }
    });

    test('a retryable answer stamped by another instance is not retried',
        () async {
      answer = (_) => stamped({'detail': 'busy'}, 503, _other);

      await expectLater(
        bound().patchJson(['uploads', 'items', 'i1'], body: {}, retry: true),
        throwsA(isA<ServerInstanceChangedException>()),
      );
      expect(sent, hasLength(1));
    });

    test('every verb is checked, a new write path included', () async {
      answer = (_) => stamped({'ok': true}, 200, _other);
      final calls = <Future<Object?> Function()>[
        () => bound().deleteJson(['uploads', 'items', 'i1']),
        () => bound().getJson(['tracks', 't1']),
        () => bound().getJsonResponse(['changes']),
        () => bound().getBytes(['cover_art', '1']),
      ];
      for (final call in calls) {
        await expectLater(call(), throwsA(isA<ServerInstanceChangedException>()));
      }
      expect(sent, hasLength(calls.length));
    });

    test('a streamed response stamped by another instance is not returned',
        () async {
      answer = (_) => stamped({'ok': true}, 200, _other);

      await expectLater(
        bound().send(() => http.Request('PUT', Uri.parse('http://s/x'))),
        throwsA(isA<ServerInstanceChangedException>()),
      );
      expect(sent, hasLength(1));
    });

    test('a matching stamp passes, whatever its case, padding or repetition',
        () async {
      for (final stamp in [
        _bound,
        _bound.toUpperCase(),
        '  $_bound ',
        '$_bound, ${_bound.toUpperCase()}',
      ]) {
        answer = (_) => stamped({'ok': stamp}, 200, stamp);
        expect(
          await bound().postJson(['history'], body: {}),
          {'ok': stamp},
          reason: stamp,
        );
      }
    });

    test('a repeated header naming two instances is a mismatch', () async {
      answer = (_) => stamped({'ok': true}, 200, '$_bound, $_other');

      await expectLater(
        bound().postJson(['history'], body: {}),
        throwsA(isA<ServerInstanceChangedException>()),
      );
    });

    test('no stamp (a pre-Phase-7 server) behaves exactly as today', () async {
      answer = (_) => stamped({'ok': true}, 200, null);
      expect(await bound().postJson(['history'], body: {}), {'ok': true});

      answer = (_) => stamped({'detail': 'conflict'}, 409, null);
      await expectLater(
        bound().postJson(['history'], body: {}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
      );

      answer = (_) => stamped({'detail': 'busy'}, 503, '   ');
      await expectLater(
        bound().patchJson(['tracks', 't1'], body: {}, retry: true),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 503)),
      );
      expect(sent.length, greaterThan(3), reason: 'the 503 was retried');
    });

    test('the plain client of the scope does not check', () async {
      answer = (_) => stamped({'ok': true}, 200, _other);

      expect(await c.read(apiClientProvider).postJson(['x'], body: {}),
          {'ok': true});
    });

    test('a transport failure still reaches the scope client listeners',
        () async {
      var offline = 0;
      final failing = testApiClient(
        'http://s',
        MockClient((_) async => throw http.ClientException('down')),
      )..addNetworkFailureListener(() => offline++);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(failing),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(boundApiClientProvider).postJson(['x'], body: {}),
        throwsA(isA<NetworkException>()),
      );
      expect(offline, 1);
    });

    test('the exception text names neither instance', () async {
      answer = (_) => stamped({}, 200, _other);
      try {
        await bound().postJson(['x'], body: {});
        fail('expected a throw');
      } on ServerInstanceChangedException catch (e) {
        expect('$e', isNot(contains(_other)));
        expect('$e', isNot(contains(_bound)));
      }
    });
  });

  test('an unbound row (no instance id yet) accepts any stamp', () async {
    await seedTestBinding(db, baseUrl: 'http://s');
    answer = (_) => stamped({'ok': true}, 200, _other);

    expect(await bound().postJson(['x'], body: {}), {'ok': true});
  });

  test('no binding row (a reset under way) accepts any stamp', () async {
    answer = (_) => stamped({'ok': true}, 200, _other);

    expect(await bound().postJson(['x'], body: {}), {'ok': true});
  });
}
