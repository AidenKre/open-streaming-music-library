import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_secure_backend.dart';
import 'server_binding.dart';
import 'test_credentials.dart';

/// A Phase M server that revoked this device's token (Phase M §7.7): the
/// public paths answer, every other request is 401 `invalid_token` in the
/// SC-22 envelope with `WWW-Authenticate: Bearer`.
class RevokedServer extends http.BaseClient {
  /// Every request's method and path, in order.
  final requests = <String>[];

  static bool _public(String path) =>
      path == '/' || path == '' || path == '/app/info';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    final (int status, String body) = switch (path) {
      '/' || '' => (200, '{"message":"Healthy"}'),
      '/app/info' => (
        200,
        '{"server":{"instance_id":"inst-1"},'
            '"auth":{"version":1,"signup_enabled":true}}',
      ),
      _ => (
        401,
        '{"detail":{"code":"invalid_token","message":"Sign in again."}}',
      ),
    };
    return http.StreamedResponse(
      Stream.value(body.codeUnits),
      status,
      request: request,
      headers: {
        'content-type': 'application/json',
        if (status == 401) 'www-authenticate': 'Bearer',
      },
    );
  }

  /// Requests to anything but the public paths.
  List<String> get private => [
    for (final r in requests)
      if (!_public(r.substring(r.indexOf(' ') + 1))) r,
  ];
}

/// A signed-in scope at `http://s` against [server], with the scope's 401
/// hook wired as FrontendApp wires it (`SessionService.onUnauthorized`), a
/// stored sign-in in an in-memory secure store, and a verified binding row.
class RevokedSession {
  RevokedSession._(
      this.db, this.store, this.storeDirectory, this.server, this.container);

  final AppDatabase db;
  final CredentialStore store;

  /// The credential store's temp directory, deleted by [dispose].
  final Directory storeDirectory;
  final RevokedServer server;
  final ProviderContainer container;

  static Future<RevokedSession> create({
    List<Override> overrides = const [],
  }) async {
    final db = AppDatabase(NativeDatabase.memory());
    final storeDirectory =
        await Directory.systemTemp.createTemp('revoked_session_');
    final store =
        CredentialStore(secure: FakeSecureBackend(), directory: storeDirectory);
    await store.save(testCredentials);
    final server = RevokedServer();
    SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
    final c = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(server),
        sessionUrlProvider.overrideWithValue('http://s'),
        credentialsProvider.overrideWithValue(testCredentials),
        credentialStoreProvider.overrideWithValue(store),
        databaseProvider.overrideWithValue(db),
        onUnauthorizedProvider.overrideWith(
          (ref) => ref.read(sessionServiceProvider).onUnauthorized,
        ),
        ...overrides,
      ],
    );
    return RevokedSession._(db, store, storeDirectory, server, c);
  }

  SessionService get session => container.read(sessionServiceProvider);

  /// Verifies the scope's connection through the real gate (the probe reads
  /// the public `/app/info`).
  Future<void> verify() async {
    await container.read(serverBindingGateProvider).startConnection('http://s');
    if (container.read(serverBindingGateProvider).state is! BindingVerified) {
      throw StateError('the test session did not verify');
    }
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
    if (await storeDirectory.exists()) {
      await storeDirectory.delete(recursive: true);
    }
  }
}
