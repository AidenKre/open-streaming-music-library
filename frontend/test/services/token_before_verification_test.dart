// Live gate m-L-11 (M-U19, spec §7.2): no request may carry the token before
// this scope's verification of the server stands, and none after it is lost.
//
// Run 3 stopped the server, launched the app with a stored sign-in and
// logged out: the launch health check and the offline health poll sent
// `GET /` with `Authorization: Bearer <token>` to the saved URL, which was
// never verified in that run. The health probe is a public path, and the
// gate's identity probe is how the server gets verified: both go through a
// client that carries no token.
//
// These tests use the real apiClientProvider (it adds the bearer header with
// credentials) and the real binding gate over one recording transport.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file/file.dart' show File;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

class _Quiesce implements Quiescable {
  _Quiesce(this.quiesceName);
  @override
  final String quiesceName;
  @override
  Future<void> quiesce() async {}
}

/// One request as the transport saw it.
class _Seen {
  _Seen(this.method, this.url, this.authorization);
  final String method;
  final Uri url;
  final String? authorization;

  bool get carriesToken =>
      authorization != null ||
      url.queryParameters.containsKey('access_token');

  @override
  String toString() =>
      '$method ${url.path}${authorization == null ? '' : ' [$authorization]'}';
}

/// The cover-art disk cache: records each network fetch's headers and never
/// has anything cached; every fetch fails like an unreachable server.
class _SpyArtCache extends Fake implements BaseCacheManager {
  final calls = <({String url, Map<String, String>? headers})>[];

  Iterable<({String url, Map<String, String>? headers})> withToken() =>
      calls.where((c) => (c.headers ?? const {})
          .keys
          .any((k) => k.toLowerCase() == 'authorization'));

  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) {
    calls.add((url: url, headers: headers));
    return Future.error(const SocketException('spy: no network'));
  }

  @override
  Future<FileInfo?> getFileFromCache(String key,
          {bool ignoreMemCache = false}) async =>
      null;
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

/// A server at the saved URL: healthy, reporting [instanceId]. With [hold],
/// each identity probe waits for it before answering.
Future<http.Response> Function(http.Request) _serverWith(String instanceId,
        {Future<void> Function()? hold}) =>
    (req) async {
      switch (req.url.path) {
        case '/' || '':
          return _json({'message': 'Healthy'});
        case '/app/info':
          await hold?.call();
          return _json({
            'server': {'instance_id': instanceId},
            'auth': {'version': 1, 'signup_enabled': false},
          });
        default:
          return _json({});
      }
    };

void main() {
  late AppDatabase db;
  late Directory dir;
  late CredentialStore store;
  late List<_Seen> seen;
  late Future<http.Response> Function(http.Request) server;

  setUp(() async {
    seen = [];
    final originalPoll = OfflineModeNotifier.pollInterval;
    addTearDown(() => OfflineModeNotifier.pollInterval = originalPoll);
    OfflineModeNotifier.pollInterval = Duration.zero;
    SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('osml-token-verify-');
    store = CredentialStore(secure: FakeSecureBackend(), directory: dir);
    await store.save(testCredentials);
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-A');
    server = (_) async => throw const SocketException('connection refused');
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  /// A signed-in scope at http://s with the real clients and the real gate.
  ProviderContainer scope({List<Override> extra = const []}) {
    final transport = MockClient((req) async {
      seen.add(_Seen(req.method, req.url, req.headers['Authorization']));
      return server(req);
    });
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      httpClientProvider.overrideWithValue(transport),
      sessionUrlProvider.overrideWithValue('http://s'),
      credentialsProvider.overrideWithValue(testCredentials),
      credentialStoreProvider.overrideWithValue(store),
      localQuiescablesProvider.overrideWithValue([
        _Quiesce('playback'),
        _Quiesce('listens'),
        _Quiesce('history'),
      ]),
      localResettablesProvider.overrideWithValue(<LocalResettable>[store]),
      onSessionChangedProvider.overrideWithValue(() async {}),
      ...extra,
    ]);
    addTearDown(c.dispose);
    return c;
  }

  /// Launch as the app does: resume the saved session, then the gate's
  /// verification attempt of the session URL.
  Future<SessionStart> launch(ProviderContainer c) async {
    final start = await c.read(sessionServiceProvider).resumeSavedSession();
    unawaited(c.read(serverBindingGateProvider).startConnection('http://s'));
    await pumpEventQueue();
    return start;
  }

  Iterable<_Seen> withToken() => seen.where((r) => r.carriesToken);

  test('launch with the server unreachable: the health check, the offline '
      'poll and the identity probe carry no token', () async {
    final c = scope();

    final start = await launch(c);
    await pumpEventQueue(times: 50); // offline polls run (zero interval)

    expect(start.kind, SessionStartKind.offline);
    expect(c.read(offlineModeProvider), isTrue);
    expect(seen.where((r) => r.url.path == '/' || r.url.path.isEmpty).length,
        greaterThan(1),
        reason: 'the launch check and at least one offline poll were sent');
    expect(seen.where((r) => r.url.path == '/app/info'), isNotEmpty,
        reason: 'the gate tried to verify');
    expect(c.read(serverBindingGateProvider).maySendTokenTo('http://s'),
        isFalse);
    expect(withToken(), isEmpty);
  });

  test('logout with the server unreachable sends no request with the token',
      () async {
    final c = scope();
    await launch(c);
    seen.clear();

    await c.read(sessionServiceProvider).logout();
    await pumpEventQueue(times: 50);

    expect(withToken(), isEmpty);
    expect(await store.read(), isNull);
  });

  // Covers the session, gate and logout requests only; cover art and app
  // info have their own tests below (review r3 m-R3-14).
  test('a foreign host answering at the saved URL: the launch, the identity '
      'probe and logout send it no token', () async {
    server = _serverWith('inst-OTHER');
    final c = scope();

    await launch(c);
    await pumpEventQueue(times: 50);
    expect(c.read(serverBindingGateProvider).state,
        isA<BindingDifferentServer>());
    await c.read(sessionServiceProvider).logout();
    await pumpEventQueue(times: 50);

    expect(seen.where((r) => r.url.path == '/app/info'), isNotEmpty);
    expect(withToken(), isEmpty);
  });

  test('control: once the bound server is verified, requests carry the token',
      () async {
    server = _serverWith('inst-A');
    final c = scope();

    await launch(c);
    await pumpEventQueue(times: 50);
    expect(c.read(serverBindingGateProvider).state, isA<BindingVerified>());

    await c.read(apiClientProvider).getJson(['tracks']);

    expect(seen.last.url.path, '/tracks');
    expect(seen.last.authorization, 'Bearer ${testCredentials.token}');
  });

  // Review r3 m-R3-01 (spec §7.2 "auth is per call", §7.4): cover art goes
  // through the cache manager, not the token client. It attaches the token
  // only while the gate allows it for the session URL: during the first
  // verification it waits (bounded), otherwise it fails like any failed
  // artwork fetch.
  group('cover art', () {
    late _SpyArtCache art;

    ProviderContainer artScope() {
      art = _SpyArtCache();
      final c = scope(extra: [
        coverArtDiskCacheProvider.overrideWithValue(art),
        coverArtDirectoryProvider.overrideWithValue(dir),
      ]);
      return c;
    }

    test('a different server at the saved URL: no artwork request carries '
        'the token, before or after the verdict', () async {
      server = _serverWith('inst-OTHER');
      final c = artScope();
      final covers = c.read(coverArtCacheProvider);

      covers.prefetch([1]); // before the verdict
      final early = covers.resolveArtUri(hasAlbumArt: true, coverArtId: 2);
      await launch(c);
      await pumpEventQueue(times: 50);
      expect(c.read(serverBindingGateProvider).state,
          isA<BindingDifferentServer>());

      covers.prefetch([3]); // after the verdict
      final late = await covers.resolveArtUri(hasAlbumArt: true, coverArtId: 4);
      await pumpEventQueue(times: 20);

      expect(await early, isNull);
      expect(late, isNull);
      expect(art.withToken(), isEmpty, reason: '${art.calls}');
      expect(withToken(), isEmpty);
    });

    test('an unverified connection (the identity probe fails): no artwork '
        'request carries the token', () async {
      server = (req) async => req.url.path == '/app/info'
          ? http.Response('boom', 500)
          : _json({'message': 'Healthy'});
      final c = artScope();
      final covers = c.read(coverArtCacheProvider);

      covers.prefetch([1]);
      await launch(c);
      await pumpEventQueue(times: 50);
      expect(c.read(serverBindingGateProvider).state, isA<BindingUnverified>());
      covers.prefetch([2]);
      final uri = await covers.resolveArtUri(hasAlbumArt: true, coverArtId: 3);
      await pumpEventQueue(times: 20);

      expect(uri, isNull);
      expect(art.withToken(), isEmpty, reason: '${art.calls}');
    });

    // Sign-off OPEN-M-11: the wait is for a verdict that is pending (the
    // check has started); an unstarted gate answers no at once.
    test('control: a request made before the verdict waits, then goes with '
        'the token once the bound server is verified', () async {
      final probe = Completer<void>();
      server = _serverWith('inst-A', hold: () => probe.future);
      final c = artScope();
      final covers = c.read(coverArtCacheProvider);

      await launch(c); // the check is running, its probe held
      covers.prefetch([1]);
      await pumpEventQueue();
      expect(art.calls, isEmpty, reason: 'no verdict yet: it waits');

      probe.complete();
      await pumpEventQueue(times: 50);
      expect(c.read(serverBindingGateProvider).state, isA<BindingVerified>());

      expect(art.calls.single.url, 'http://s/cover_art/1');
      expect(art.calls.single.headers,
          {'Authorization': 'Bearer ${testCredentials.token}'});
    });
  });

  // Sign-off OPEN-M-11 (2026-11-17): the scope's token client attaches the
  // token only while this connection is verified and the app is online.
  group('the token client (sign-off OPEN-M-11)', () {
    test('resume, then a request at once: it waits for that probe, the probe '
        'passes, the request goes with the token', () async {
      var hold = Completer<void>()..complete();
      server = _serverWith('inst-A', hold: () => hold.future);
      final c = scope();
      await launch(c);
      await pumpEventQueue(times: 50);
      final gate = c.read(serverBindingGateProvider);
      expect(gate.state, isA<BindingVerified>());
      seen.clear();

      hold = Completer<void>();
      unawaited(gate.startConnection('http://s')); // appResume edge
      final request = c.read(apiClientProvider).getJson(['tracks']);
      await pumpEventQueue(times: 20);
      expect(seen.where((r) => r.url.path == '/tracks'), isEmpty,
          reason: 'it waits for the re-probe');

      hold.complete();
      await request;
      final tracks = seen.where((r) => r.url.path == '/tracks').single;
      expect(tracks.authorization, 'Bearer ${testCredentials.token}');
    });

    test('an unverified connection (the identity probe fails): a request is '
        'withheld with its own error and nothing carries the token', () async {
      server = (req) async => req.url.path == '/app/info'
          ? http.Response('boom', 500)
          : _json({'message': 'Healthy'});
      final c = scope();
      await launch(c);
      await pumpEventQueue(times: 50);
      expect(c.read(serverBindingGateProvider).state, isA<BindingUnverified>());

      await expectLater(c.read(apiClientProvider).getJson(['tracks']),
          throwsA(isA<TokenWithheldException>()));
      expect(seen.where((r) => r.url.path == '/tracks'), isEmpty);
      expect(c.read(offlineModeProvider), isFalse,
          reason: 'a withheld request is not a lost connection');
      expect(withToken(), isEmpty);
    });

    test('a different server at the saved URL: withheld', () async {
      server = _serverWith('inst-OTHER');
      final c = scope();
      await launch(c);
      await pumpEventQueue(times: 50);
      expect(c.read(serverBindingGateProvider).state,
          isA<BindingDifferentServer>());

      await expectLater(c.read(apiClientProvider).getJson(['tracks']),
          throwsA(isA<TokenWithheldException>()));
      expect(withToken(), isEmpty);
    });

    test('verified but offline: withheld until back online', () async {
      server = _serverWith('inst-A');
      final c = scope();
      await launch(c);
      await pumpEventQueue(times: 50);
      expect(c.read(serverBindingGateProvider).state, isA<BindingVerified>());
      c.read(offlineModeProvider.notifier).enterOffline();
      c.read(offlineModeProvider.notifier).cancelOfflinePolling();

      await expectLater(c.read(apiClientProvider).getJson(['tracks']),
          throwsA(isA<TokenWithheldException>()));
      expect(seen.where((r) => r.url.path == '/tracks'), isEmpty);
    });

    test('before the gate has started (no check running): withheld at once',
        () async {
      server = _serverWith('inst-A');
      final c = scope();
      await expectLater(c.read(apiClientProvider).getJson(['tracks']),
          throwsA(isA<TokenWithheldException>()));
      expect(seen, isEmpty);
    });
  });

  // Review r3 m-R3-11: /app/info is a public, user-independent path, so the
  // capabilities read never carries the token: not before the verdict, and
  // not while the connection stays unverified.
  test('app info is read without the token, before the verdict and while '
      'unverified', () async {
    server = (req) async => req.url.path == '/app/info'
        ? http.Response('boom', 500)
        : _json({'message': 'Healthy'});
    final c = scope();

    final sub = c.listen(appInfoProvider, (previous, next) {});
    addTearDown(sub.close);
    await pumpEventQueue(times: 20); // read before any verdict
    final early = seen.where((r) => r.url.path == '/app/info').length;
    expect(early, greaterThan(0));

    await launch(c);
    await pumpEventQueue(times: 50);
    expect(c.read(serverBindingGateProvider).state, isA<BindingUnverified>());
    c.invalidate(appInfoProvider); // a re-read (tracks page, Get Info)
    await pumpEventQueue(times: 20);

    final reads = seen.where((r) => r.url.path == '/app/info');
    expect(reads.length, greaterThan(early + 1),
        reason: 'the gate probe and the re-read both went out');
    expect(reads.where((r) => r.carriesToken), isEmpty, reason: '$reads');
  });
}
