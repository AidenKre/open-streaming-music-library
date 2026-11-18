// Phase M §7.2 / §7.3 (M-U19 art, M-U20, exit proof "no cache key or
// cache-database row contains a token"): the process-wide cover-art disk
// cache stays global, and the scope-bound wrapper passes the auth header per
// call (`getSingleFile(url, headers:)`). Headers are not stored in the cache
// database, so its keys and rows stay token-free. For the OS media session,
// `resolveArtUri` never returns a network URL: uncached art is fetched with
// the header into the cache and handed over as `file://`, or null.
import 'dart:async';
import 'dart:io' as io;

import 'package:file/file.dart' hide FileSystem;
import 'package:drift/native.dart';
import 'package:file/local.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _alice = Credentials(
  token: 'api-token-A',
  mediaToken: 'media-token-A',
  userId: 7,
  username: 'alice',
);

/// Stands in for the network under the real cache manager: records the
/// headers of every fetch.
class _FileService extends FileService {
  _FileService({this.status = 200});
  final int status;
  final fetches = <({String url, Map<String, String>? headers})>[];

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    fetches.add((url: url, headers: headers));
    return _Response(status);
  }
}

class _Response implements FileServiceResponse {
  _Response(this.statusCode);
  @override
  final int statusCode;
  @override
  Stream<List<int>> get content => Stream.value(const [1, 2, 3, 4]);
  @override
  int? get contentLength => 4;
  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 7));
  @override
  String? get eTag => 'etag-1';
  @override
  String get fileExtension => '.jpg';
}

class _TempFileSystem implements FileSystem {
  _TempFileSystem(this.root);
  final io.Directory root;
  @override
  Future<File> createFile(String name) async {
    final file = const LocalFileSystem().file('${root.path}/$name');
    await file.parent.create(recursive: true);
    return file;
  }
}

/// A disk cache that records each call's headers and never completes.
class _SpyDiskCache extends Fake implements BaseCacheManager {
  final calls = <({String url, Map<String, String>? headers})>[];
  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) {
    calls.add((url: url, headers: headers));
    return Completer<File>().future;
  }

  @override
  Future<FileInfo?> getFileFromCache(String key,
          {bool ignoreMemCache = false}) async =>
      null;
}

/// The scope's binding gate, answering the token permit with [allowed] and
/// recording which URLs it was asked about.
class _Gate extends Fake implements ServerBindingGate {
  _Gate({required this.allowed});
  final bool allowed;
  final asked = <String>[];
  @override
  Future<bool> whenMaySendTokenTo(String baseUrl) async {
    asked.add(baseUrl);
    return allowed;
  }
}

ApiClient _client() => testApiClient(
      'http://srv:1',
      MockClient((_) async => http.Response('', 500)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory dir;
  late io.File repoFile;
  late _FileService network;
  late JsonCacheInfoRepository repo;
  late CacheManager disk;

  CacheManager realCache(_FileService service) {
    repo = JsonCacheInfoRepository.withFile(repoFile);
    return CacheManager(
      Config(
        'cover_art_auth_test',
        repo: repo,
        fileSystem: _TempFileSystem(io.Directory('${dir.path}/files')),
        fileService: service,
      ),
    );
  }

  setUp(() async {
    dir = await io.Directory.systemTemp.createTemp('cover_art_auth_test_');
    repoFile = io.File('${dir.path}/cache.json');
    network = _FileService();
    disk = realCache(network);
    // Let the cache open its repository before a test can dispose it.
    await disk.getFileFromCache('warm-up');
  });

  tearDown(() async {
    await disk.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// [permit]: what the binding gate answers about sending the token.
  CoverArtCacheManager manager({
    Credentials? credentials,
    BaseCacheManager? cache,
    bool permit = true,
  }) =>
      CoverArtCacheManager(
        api: _client(),
        cache: cache ?? disk,
        authHeaders: credentials == null
            ? null
            : {'Authorization': 'Bearer ${credentials.token}'},
        mayAttachToken: () async => permit,
      );

  group('the header is passed per call', () {
    test('prefetch fetches with the bearer header', () async {
      final spy = _SpyDiskCache();
      manager(credentials: _alice, cache: spy).prefetch([42]);
      await pumpEventQueue();
      expect(spy.calls.single.url, 'http://srv:1/cover_art/42');
      expect(spy.calls.single.headers, {'Authorization': 'Bearer api-token-A'});
    });

    test('an image tile loads with the bearer header', () async {
      final spy = _SpyDiskCache();
      final provider = manager(credentials: _alice, cache: spy)
          .imageProvider(42);
      provider.resolve(ImageConfiguration.empty);
      await Future<void>.delayed(Duration.zero);
      expect(spy.calls.single.url, 'http://srv:1/cover_art/42');
      expect(spy.calls.single.headers, {'Authorization': 'Bearer api-token-A'});
    });

    test('the image cache key is the token-free URL', () {
      final spy = _SpyDiskCache();
      final provider = manager(credentials: _alice, cache: spy)
          .imageProvider(42) as CoverArtImageProvider;
      expect(provider.url, 'http://srv:1/cover_art/42');
      expect('$provider', isNot(contains('api-token-A')));
    });

    test('without credentials no Authorization header is sent', () async {
      final spy = _SpyDiskCache();
      manager(cache: spy).prefetch([42]);
      await pumpEventQueue();
      final headers = spy.calls.single.headers ?? const {};
      expect(headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')));
    });

    test("the scope's provider uses the scope's credentials", () async {
      final spy = _SpyDiskCache();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(_client()),
          credentialsProvider.overrideWithValue(_alice),
          coverArtDiskCacheProvider.overrideWithValue(spy),
          coverArtDirectoryProvider.overrideWithValue(dir),
          serverBindingGateProvider.overrideWithValue(_Gate(allowed: true)),
        ],
      );
      addTearDown(container.dispose);
      container.read(coverArtCacheProvider).prefetch([42]);
      await pumpEventQueue();
      expect(spy.calls.single.headers, {'Authorization': 'Bearer api-token-A'});
    });
  });

  group('the cache database stays token-free', () {
    test('after a fetch, no cache key or row contains a token', () async {
      final m = manager(credentials: _alice);
      final uri = await m.resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      expect(uri, isNotNull);
      expect(network.fetches.single.headers?['Authorization'],
          'Bearer api-token-A');

      final rows = await repo.getAllObjects();
      expect(rows, isNotEmpty);
      for (final row in rows) {
        for (final field in [row.key, row.url, row.relativePath, row.eTag]) {
          expect('$field', isNot(contains('api-token-A')));
          expect('$field', isNot(contains('media-token-A')));
        }
        expect(row.key, 'http://srv:1/cover_art/42');
      }
      await repo.close(); // flush the rows to the file
      final text = await repoFile.readAsString();
      expect(text, contains('/cover_art/42'));
      expect(text, isNot(contains('api-token-A')));
      expect(text, isNot(contains('media-token-A')));
      expect(text.toLowerCase(), isNot(contains('authorization')));
    });
  });

  group('resolveArtUri never returns a network URL', () {
    test('uncached art is fetched with the header and returned as file://',
        () async {
      final uri = await manager(credentials: _alice)
          .resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      expect(uri!.scheme, 'file');
      expect(io.File.fromUri(uri).existsSync(), isTrue);
      expect(network.fetches.single.url, 'http://srv:1/cover_art/42');
      expect(network.fetches.single.headers?['Authorization'],
          'Bearer api-token-A');
    });

    test('cached art is served without a second fetch', () async {
      final m = manager(credentials: _alice);
      await m.resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      final again = await m.resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      expect(again!.scheme, 'file');
      expect(network.fetches, hasLength(1));
    });

    test('a failed fetch returns null', () async {
      await disk.dispose();
      network = _FileService(status: 401);
      disk = realCache(network);
      await disk.getFileFromCache('warm-up');
      final uri = await manager(credentials: _alice)
          .resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      expect(uri, isNull);
    });

    test('without a disk cache it returns null', () async {
      final uri = await CoverArtCacheManager.noop(api: _client())
          .resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      expect(uri, isNull);
    });
  });

  // Review r3 m-R3-01: the header goes with a request only when the gate
  // allows it for this request. Withheld: no request carries the token;
  // art already in the disk cache still shows; anything else fails like a
  // failed fetch (placeholder, prefetch dropped, resolveArtUri null).
  group('the token goes only where the gate allows it', () {
    bool hasToken(Map<String, String>? headers) => (headers ?? const {})
        .keys
        .any((k) => k.toLowerCase() == 'authorization');

    test('withheld: prefetch sends no request with the token', () async {
      final spy = _SpyDiskCache();
      manager(credentials: _alice, cache: spy, permit: false).prefetch([42]);
      await pumpEventQueue();
      expect(spy.calls.where((c) => hasToken(c.headers)), isEmpty);
    });

    test('withheld: an image tile fails to load and sends no token',
        () async {
      final spy = _SpyDiskCache();
      // Its own id: a pending load of 42 from an earlier test stays in the
      // global image cache, keyed by the URL.
      final provider = manager(credentials: _alice, cache: spy, permit: false)
          .imageProvider(43);
      final failed = Completer<Object>();
      provider.resolve(ImageConfiguration.empty).addListener(
            ImageStreamListener((image, sync) {},
                onError: (e, stack) => failed.complete(e)),
          );
      await failed.future;
      expect(spy.calls.where((c) => hasToken(c.headers)), isEmpty);
    });

    test('withheld: uncached art resolves to null without a fetch', () async {
      final uri = await manager(credentials: _alice, permit: false)
          .resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      expect(uri, isNull);
      expect(network.fetches, isEmpty);
    });

    test('withheld: art already in the disk cache still shows', () async {
      await manager(credentials: _alice)
          .resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      expect(network.fetches, hasLength(1));

      final withheld = manager(credentials: _alice, permit: false);
      final uri =
          await withheld.resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      expect(uri!.scheme, 'file');

      expect(network.fetches, hasLength(1), reason: 'no second fetch');
    });

    test('the gate is asked per request, not once per scope', () async {
      final spy = _SpyDiskCache();
      var allowed = false;
      final m = CoverArtCacheManager(
        api: _client(),
        cache: spy,
        authHeaders: {'Authorization': 'Bearer ${_alice.token}'},
        mayAttachToken: () async => allowed,
      );
      m.prefetch([1]);
      await pumpEventQueue();
      allowed = true;
      m.prefetch([2]);
      await pumpEventQueue();

      expect(spy.calls.where((c) => hasToken(c.headers)).map((c) => c.url),
          ['http://srv:1/cover_art/2']);
    });

    test('a header with no permit wired is never sent (fails closed)',
        () async {
      final spy = _SpyDiskCache();
      CoverArtCacheManager(
        api: _client(),
        cache: spy,
        authHeaders: {'Authorization': 'Bearer ${_alice.token}'},
      ).prefetch([42]);
      await pumpEventQueue();
      expect(spy.calls.where((c) => hasToken(c.headers)), isEmpty);
    });

    test("the scope's provider asks the scope's gate about the session URL",
        () async {
      final spy = _SpyDiskCache();
      final gate = _Gate(allowed: false);
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(_client()),
          credentialsProvider.overrideWithValue(_alice),
          coverArtDiskCacheProvider.overrideWithValue(spy),
          coverArtDirectoryProvider.overrideWithValue(dir),
          serverBindingGateProvider.overrideWithValue(gate),
        ],
      );
      addTearDown(container.dispose);
      container.read(coverArtCacheProvider).prefetch([42]);
      await pumpEventQueue();
      expect(gate.asked, ['http://srv:1']);
      expect(spy.calls.where((c) => hasToken(c.headers)), isEmpty);
    });
  });

  // Review m-R3c-01: while the server's check has not answered (a launch
  // whose server does not respond), the permit waits for the verdict, up to
  // its 10 s bound. Art that is already in the disk cache (and still valid)
  // needs no network fetch, so it is served at once instead of waiting on
  // the permit. (An Idle gate answers "no" at once and could not show this;
  // pre-merge review D5-04.)
  group('a disk-cache hit does not wait on the permit', () {
    test('pending verdict: cached art loads without waiting out the bound',
        () async {
      // Put the art in the disk cache through a permitted fetch.
      await manager(credentials: _alice)
          .resolveArtUri(hasAlbumArt: true, coverArtId: 42);
      expect(network.fetches, hasLength(1));

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = ServerBindingRepository(db);
      await repository.ensureProvisional('http://srv:1', userId: _alice.userId);
      final bounds = <Duration>[];
      final gate = ServerBindingGate(
        repository: repository,
        signedInUserId: _alice.userId,
        probe: ({required String baseUrl, required bool reportOffline}) =>
            Completer<ServerIdentity>().future,
        backoff: BackoffSchedule(jitter: 0),
        // Records each timer and never fires it: the bound never expires.
        timer: (delay, fire) {
          bounds.add(delay);
          return Timer(const Duration(days: 1), () {});
        },
      );
      addTearDown(gate.dispose);
      // The check starts and its probe never answers: the verdict stays
      // pending, so the permit would wait on the (never firing) bound.
      unawaited(gate.startConnection('http://srv:1'));
      await pumpEventQueue();
      expect(gate.state, isA<BindingVerifying>());

      final pending = CoverArtCacheManager(
        api: _client(),
        cache: disk,
        authHeaders: {'Authorization': 'Bearer ${_alice.token}'},
        mayAttachToken: () => gate.whenMaySendTokenTo('http://srv:1'),
      );
      final provider = pending.imageProvider(42) as CoverArtImageProvider;
      // The cache read is real file I/O, so it is awaited (bounded) rather
      // than given a fixed number of event-queue turns; the gate's timer
      // never fires here, so a load that waited on the permit never ends.
      final loaded = await provider.load().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('not served from the disk cache at once'),
      );
      expect(await loaded.readAsBytes(), [1, 2, 3, 4]);
      expect(bounds, isNot(contains(ServerBindingGate.tokenWaitBound)),
          reason: 'the permit was not waited on');
      expect(network.fetches, hasLength(1), reason: 'no second fetch');

      // Fixture check: in this state the permit really does wait.
      var answered = false;
      unawaited(gate
          .whenMaySendTokenTo('http://srv:1')
          .then((_) => answered = true));
      await pumpEventQueue();
      expect(answered, isFalse);
      expect(bounds, contains(ServerBindingGate.tokenWaitBound));
    });
  });
}
