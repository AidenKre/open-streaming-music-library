// Sign-off OPEN-M-11 (2026-11-17) guard: the session token reaches a server
// only through the one place, `AuthenticatedClient` (which asks the binding
// gate per request), plus the reviewed exceptions listed below.
//
// 1. Static: every way to put a token on a request (`bearerAuthHeader(`, an
//    `Authorization` header literal, `HttpHeaders.authorizationHeader`, a
//    `Bearer ` literal, `access_token`, a media-token read, a credentials
//    `.token` read, a new token client or a raw HTTP client) is counted per
//    file in `lib/`, comments excluded. Any new occurrence, in a new file or
//    an allowed one, fails until the allow-list below is updated on purpose,
//    with a reason and a review of the gate check on that path.
// 2. Behavioural: a real signed-in scope (real token client, real gate) whose
//    server is not verified drives every token-carrying sender the app has;
//    no request that reaches the transport or the cover-art cache carries
//    the token.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file/file.dart' as file;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/auth_api.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/source_failure_classifier.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/queue_warm_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

/// Pattern name -> regular expression (applied per line, comments removed).
final _patterns = <String, RegExp>{
  'bearerAuthHeader(': RegExp(r'bearerAuthHeader\('),
  'Authorization literal': RegExp(r'''['"]authorization['"]''',
      caseSensitive: false),
  'authorizationHeader': RegExp(r'authorizationHeader'),
  'Bearer literal': RegExp(r'''['"]Bearer '''),
  'access_token': RegExp(r'access_token'),
  'mediaToken read': RegExp(r'\.mediaToken\b'),
  'credentials .token read':
      RegExp(r'(\w*[cC]red\w*\??\.token\b|\bc\.token\b)'),
  'new AuthenticatedClient': RegExp(r'\bAuthenticatedClient\('),
  'revoke exemption': RegExp(r'\b(revokeExemption|revokeOnceClient)\('),
  'raw HTTP client':
      RegExp(r'(\bhttp\.Client\(\)|\bHttpClient\(|\bIOClient\()'),
  // A media token handed to a URL builder (sign-off OPEN-M-11 step D).
  'mediaToken: argument': RegExp(r'\bmediaToken:'),
};

/// The reviewed places, with exact counts per pattern. Changing this map is
/// a security review: say why the new place is safe (which gate check it
/// passes). Any file or pattern not listed must not occur at all.
const _allowed = <String, Map<String, int>>{
  // The one place: formats and attaches the header after the permit, and
  // the one-shot revoke exemption.
  'lib/api/authenticated_client.dart': {
    'bearerAuthHeader(': 3,
    'Authorization literal': 5,
    'Bearer literal': 1,
    'new AuthenticatedClient': 1,
    'credentials .token read': 2,
    'revoke exemption': 1,
  },
  // Builds the scope's token client with the gate permit; the shared
  // transport.
  'lib/api/api_client_provider.dart': {
    'new AuthenticatedClient': 1,
    'raw HTTP client': 1,
  },
  // The log-out/Disconnect exemption, taken while the revoke rule holds.
  'lib/api/api_client.dart': {'revoke exemption': 2},
  'lib/services/local_reset_service.dart': {'revoke exemption': 1},
  // The held sign-in's revoke: a session the login just issued, sent once
  // through the unhooked client to the server that issued it.
  'lib/api/auth_api.dart': {'bearerAuthHeader(': 1, 'mediaToken: argument': 1},
  'lib/services/session_service.dart': {'credentials .token read': 1},
  // Stores and parses the sign-in.
  'lib/services/credential_store.dart': {
    'mediaToken read': 2,
    'mediaToken: argument': 1,
  },
  // Cover art: the header goes per request only after whenMaySendTokenTo
  // (the gate's rule); the player's media token (OPEN-M-11 step D, not yet
  // gated at the stream-URL build).
  'lib/playback/audio_dependencies.dart': {
    'bearerAuthHeader(': 1,
    'credentials .token read': 1,
    'mediaToken read': 1,
  },
  // Media-token URL builders and log redaction.
  'lib/playback/track_cache_manager.dart': {'access_token': 4},
  // The player: the one stream-URL build with the media token, after the
  // gate's permit (OPEN-M-11 step D); reads the token back for redaction.
  'lib/playback/just_audio_engine.dart': {
    'access_token': 1,
    'mediaToken: argument': 1,
  },
  // The upload preview: the media token only after whenMaySendTokenTo.
  'lib/playback/preview_player.dart': {
    'mediaToken read': 1,
    'mediaToken: argument': 3,
  },
  // The process-lifetime transport.
  'lib/main.dart': {'raw HTTP client': 1},
};

/// Counts per file and pattern over `lib/`, comments removed. Generated
/// files are skipped.
Map<String, Map<String, int>> _scan() {
  final found = <String, Map<String, int>>{};
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));
  for (final f in files) {
    final path = f.path.replaceAll(r'\', '/');
    for (final raw in f.readAsLinesSync()) {
      final line = _withoutComment(raw);
      if (line.trim().isEmpty) continue;
      _patterns.forEach((name, re) {
        final n = re.allMatches(line).length;
        if (n > 0) {
          final counts = found.putIfAbsent(path, () => {});
          counts[name] = (counts[name] ?? 0) + n;
        }
      });
    }
  }
  return found;
}

/// The line without a `//` comment that is not inside a string literal.
String _withoutComment(String line) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quote != null) {
      if (ch == r'\') {
        i++;
      } else if (ch == quote) {
        quote = null;
      }
    } else if (ch == "'" || ch == '"') {
      quote = ch;
    } else if (ch == '/' && i + 1 < line.length && line[i + 1] == '/') {
      return line.substring(0, i);
    }
  }
  return line;
}

/// One request as it left the app.
class _Seen {
  _Seen(this.method, this.url, this.headers);
  final String method;
  final Uri url;
  final Map<String, String> headers;

  bool get carriesToken =>
      headers.keys.any((k) => k.toLowerCase() == 'authorization') ||
      url.queryParameters.containsKey('access_token');

  @override
  String toString() => '$method $url $headers';
}

/// The cover-art disk cache: nothing cached, every fetch recorded.
class _SpyArtCache extends Fake implements BaseCacheManager {
  _SpyArtCache(this.seen);
  final List<_Seen> seen;

  @override
  Future<file.File> getSingleFile(String url,
      {String? key, Map<String, String>? headers}) {
    seen.add(_Seen('GET(cache)', Uri.parse(url), headers ?? const {}));
    return Future.error(const SocketException('spy: no network'));
  }

  @override
  Future<FileInfo?> getFileFromCache(String key,
          {bool ignoreMemCache = false}) async =>
      null;
}

/// Warm-up has its own withheld test (its debounce timer would outlive
/// the sweep).
class _NoWarmTimer extends Fake implements QueueWarmService {
  @override
  void scheduleWarmUuids(List<String> trackUuids, {required String quality}) {}
  @override
  void dispose() {}
}

http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

void main() {
  group('static: every token attachment is in a reviewed place', () {
    test('no token use outside the allow-list, and no new one inside it', () {
      final found = _scan();
      final problems = <String>[];
      found.forEach((path, counts) {
        final allowed = _allowed[path];
        counts.forEach((pattern, n) {
          final ok = allowed?[pattern];
          if (ok != n) {
            problems.add('$path: $pattern x$n (allowed: ${ok ?? 0})');
          }
        });
      });
      // A reviewed place that disappeared also needs the list updated.
      _allowed.forEach((path, counts) {
        counts.forEach((pattern, n) {
          if ((found[path]?[pattern] ?? 0) != n && n > 0 &&
              !problems.any((p) => p.startsWith('$path: $pattern '))) {
            problems.add('$path: $pattern x${found[path]?[pattern] ?? 0} '
                '(allowed: $n)');
          }
        });
      });
      expect(problems, isEmpty,
          reason: 'A request that carries the session or media token must '
              'go through AuthenticatedClient (sign-off OPEN-M-11). If this '
              'place is reviewed and safe, add it to _allowed with a reason.');
    });

    // Review s7-session-network F2: the process-wide cover-art disk cache
    // queues its downloads, so its HTTP must reach the live scope's token
    // client at the send (scope token route), not carry a header decided
    // earlier.
    test('the cover-art disk cache sends through the scope token route', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, isNot(contains('DefaultCacheManager()')));
      expect(main, contains('HttpFileService(httpClient: scopeTokenRoute.client)'));
    });

    // Sign-off OPEN-M-11 step D: the player puts the media token in a stream
    // URL only through the gate's permit, and the scope wires the permit and
    // the gate's verdicts into the engine.
    test('the player attaches the media token only through the permit', () {
      final engine =
          File('lib/playback/just_audio_engine.dart').readAsStringSync();
      expect(engine,
          contains('final token = allowToken ? _permittedMediaToken(bare) : null;'));
      expect(engine, contains('quality: quality, mediaToken: token);'));
      final wiring =
          File('lib/playback/audio_dependencies.dart').readAsStringSync();
      expect(wiring, contains('mediaTokenPermit: gate,'));
      expect(wiring, contains('ref.read(streamsUnavailableProvider)'));
      // The gate's verdicts reach the engine through the queue player's lane.
      final core = File('lib/playback/queue_player.dart').readAsStringSync();
      expect(core, contains('mediaTokenActionFor('));
    });

    test('the scan sees the one place (it is not vacuous)', () {
      final found = _scan();
      expect(found['lib/api/authenticated_client.dart']?['bearerAuthHeader('],
          3);
      expect(found.keys, contains('lib/api/api_client_provider.dart'));
    });
  });

  group('behavioural: nothing carries the token to an unverified server', () {
    late AppDatabase db;
    late Directory dir;
    late List<_Seen> seen;
    late Future<http.Response> Function(http.Request) server;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final originalPoll = ConversionJobsNotifier.pollInterval;
      addTearDown(() => ConversionJobsNotifier.pollInterval = originalPoll);
      ConversionJobsNotifier.pollInterval = const Duration(days: 1);
      db = AppDatabase(NativeDatabase.memory());
      dir = await Directory.systemTemp.createTemp('osml-token-guard-');
      seen = [];
      await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-A');
      await db.into(db.tracks).insert(
          TracksCompanion.insert(uuidId: 'u1', createdAt: 0, lastUpdated: 0));
      await db.into(db.trackmetadata).insert(
          TrackmetadataCompanion.insert(uuidId: 'u1'));
    });

    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    ProviderContainer scope() {
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        httpClientProvider.overrideWithValue(MockClient((req) async {
          seen.add(_Seen(req.method, req.url, req.headers));
          return server(req);
        })),
        sessionUrlProvider.overrideWithValue('http://s'),
        credentialsProvider.overrideWithValue(testCredentials),
        coverArtDiskCacheProvider.overrideWithValue(_SpyArtCache(seen)),
        coverArtDirectoryProvider.overrideWithValue(dir),
        downloadDirectoryProvider.overrideWithValue(() async => dir),
        queueWarmServiceProvider.overrideWithValue(_NoWarmTimer()),
        streamQualityProvider.overrideWithValue('320'),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    /// Every sender that can carry the token, driven once. Each failure is
    /// expected (the server is not verified); only what went out counts.
    Future<void> driveEverySender(ProviderContainer c) async {
      Future<void> quietly(FutureOr<Object?> Function() send) async {
        try {
          await send();
        } catch (_) {}
      }

      final api = c.read(apiClientProvider);
      await quietly(() => api.getJson(['tracks']));
      await quietly(() => c.read(boundApiClientProvider).getJson(['changes']));
      await quietly(() => c.read(tracksApiProvider).getTrack('u1'));
      await quietly(() => trackStatusVia(c.read(tracksApiProvider), 'u1'));
      await quietly(() => c.read(jobsApiProvider).getJobs(uuidId: 'u1'));
      await quietly(() => c.read(jobsApiProvider).cancelJob(1));
      await quietly(
          () => c.read(conversionJobsProvider.notifier).refreshAll());
      await quietly(() => c.read(historyApiProvider).changes(after: 0));
      await quietly(() => c
          .read(settingsProvider.notifier)
          .setStreamQualityFull('256'));
      await quietly(() => c.read(localCoverArtStoreProvider).download(7));
      await quietly(() => c.read(downloadManagerProvider).enqueueTracks([
            const TrackUI(
              uuidId: 'u1',
              createdAt: 0,
              lastUpdated: 0,
              title: 't',
              artist: 'a',
              duration: 120,
              bitrateKbps: 320,
              sampleRateHz: 44100,
              channels: 2,
              hasAlbumArt: false,
            ),
          ], quality: '320'));
      await quietly(() => revokeBestEffort(api));
      c.read(coverArtCacheProvider).prefetch([8]);
      await quietly(() => c
          .read(coverArtCacheProvider)
          .resolveArtUri(hasAlbumArt: true, coverArtId: 9));

      // Phase 8 senders (E8): library tools and uploads. The calls that
      // wait at the gate are not awaited (unverified, they keep waiting).
      void detached(Future<Object?> Function() send) =>
          unawaited(send().then<void>((_) {}, onError: (Object _) {}));
      final tools = c.read(libraryToolsApiProvider);
      await quietly(() => tools.listJobs(waitForBinding: false));
      await quietly(() => tools.listDuplicates(waitForBinding: false));
      await quietly(() => tools.duplicateSummary(waitForBinding: false));
      detached(() => tools.preview(
          const [DeletionTargetDto(uuidId: 'u1', baseRevision: 1)]));
      detached(() => tools.createJob(DeletionJobRequestDto(
            operationUuid: '33333333-3333-4333-8333-333333333333',
            targets: const [DeletionTargetDto(uuidId: 'u1', baseRevision: 1)],
            confirmedCount: 1,
          ).toFrozenJson()));
      detached(() => tools.getJob('33333333-3333-4333-8333-333333333333'));
      detached(() => tools.dismissPair('u1', 'u2'));
      final uploads = c.read(uploadsApiProvider);
      detached(() => uploads.listBatches());
      detached(() => uploads.getBatch('b1'));
      detached(() => uploads.getItem('i1'));
      detached(() => uploads.cancelItem('i1'));
      await pumpEventQueue(times: 50);
    }

    Future<void> launchWith(ProviderContainer c) async {
      unawaited(c.read(serverBindingGateProvider).startConnection('http://s'));
      await pumpEventQueue(times: 50);
    }

    test('the identity check fails (unverified)', () async {
      server = (req) async => switch (req.url.path) {
            '/' || '' => _json({'message': 'Healthy'}),
            '/app/info' => http.Response('boom', 500),
            _ => _json({}),
          };
      final c = scope();
      await launchWith(c);
      expect(c.read(serverBindingGateProvider).state, isA<BindingUnverified>());

      await driveEverySender(c);

      expect(seen.where((r) => r.url.path == '/app/info'), isNotEmpty,
          reason: 'the check itself went out, without the token');
      expect(seen.where((r) => r.carriesToken), isEmpty, reason: '$seen');
    });

    test('a different server answers at the saved address', () async {
      server = (req) async => switch (req.url.path) {
            '/' || '' => _json({'message': 'Healthy'}),
            '/app/info' => _json({
                'server': {'instance_id': 'inst-OTHER'},
                'auth': {'version': 1, 'signup_enabled': false},
              }),
            _ => _json({}),
          };
      final c = scope();
      await launchWith(c);
      expect(c.read(serverBindingGateProvider).state,
          isA<BindingDifferentServer>());

      await driveEverySender(c);

      expect(seen.where((r) => r.carriesToken), isEmpty, reason: '$seen');
    });

    test('verified, but the app is offline', () async {
      server = (req) async => switch (req.url.path) {
            '/' || '' => _json({'message': 'Healthy'}),
            '/app/info' => _json({
                'server': {'instance_id': 'inst-A'},
                'auth': {'version': 1, 'signup_enabled': false},
              }),
            _ => _json({}),
          };
      final c = scope();
      await launchWith(c);
      expect(c.read(serverBindingGateProvider).state, isA<BindingVerified>());
      final offline = c.read(offlineModeProvider.notifier)..enterOffline();
      offline.cancelOfflinePolling();

      await driveEverySender(c);

      expect(seen.where((r) => r.carriesToken), isEmpty, reason: '$seen');
    });

    test('control: verified and online, the same senders do carry it',
        () async {
      server = (req) async => switch (req.url.path) {
            '/' || '' => _json({'message': 'Healthy'}),
            '/app/info' => _json({
                'server': {'instance_id': 'inst-A'},
                'auth': {'version': 1, 'signup_enabled': false},
              }),
            _ => _json({}),
          };
      final c = scope();
      await launchWith(c);
      expect(c.read(serverBindingGateProvider).state, isA<BindingVerified>());

      await driveEverySender(c);

      final carried = {
        for (final r in seen.where((r) => r.carriesToken)) r.url.path,
      };
      expect(
          carried,
          containsAll([
            '/tracks', '/tracks/u1', '/jobs',
            // Phase 8 (E8): library tools and uploads.
            '/tracks/deletions', '/tracks/duplicates/summary',
            '/tracks/uploads', '/tracks/uploads/b1',
          ]),
          reason: 'the sweep reaches the token client: $seen');
    });
  });
}
