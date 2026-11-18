import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/services/local_cover_art_store.dart';

void main() {
  // The reset evicts decoded covers from the painting binding's image cache.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('local-cover-art-store-test');
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  late ApiClient api;

  void installClient(http.Client client) {
    api = testApiClient('http://test:8080', client);
  }

  Future<LocalCoverArtStore> buildStore({http.Client? client}) {
    installClient(client ?? MockClient((_) async => http.Response('', 404)));
    return LocalCoverArtStore.create(
      apiClient: api,
      directoryProvider: () async => tempDirectory,
    );
  }

  test('create makes the cover_art directory', () async {
    final store = await buildStore();
    expect(store.directory.existsSync(), isTrue);
    expect(p.basename(store.directory.path), 'cover_art');
  });

  test('download writes the response bytes to {id}.bin', () async {
    final store = await buildStore(
      client: MockClient((req) async {
        expect(req.url.toString(), 'http://test:8080/cover_art/42');
        return http.Response.bytes([1, 2, 3, 4], 200);
      }),
    );

    final ok = await store.download(42);
    expect(ok, isTrue);
    expect(store.has(42), isTrue);
    expect(await store.fileFor(42).readAsBytes(), [1, 2, 3, 4]);
  });

  test('download is a no-op when the file already exists', () async {
    var requestCount = 0;
    final store = await buildStore(
      client: MockClient((req) async {
        requestCount++;
        return http.Response.bytes([9], 200);
      }),
    );

    await store.download(7);
    final beforeBytes = await store.fileFor(7).readAsBytes();
    await store.download(7);

    expect(requestCount, 1, reason: 'second download should not hit network');
    expect(await store.fileFor(7).readAsBytes(), beforeBytes);
  });

  test('download returns false on non-2xx response', () async {
    final store = await buildStore(
      client: MockClient((_) async => http.Response('not found', 404)),
    );

    expect(await store.download(11), isFalse);
    expect(store.has(11), isFalse);
  });

  test('download leaves no .partial file behind on failure', () async {
    final store = await buildStore(
      client: MockClient((_) async => http.Response('boom', 500)),
    );

    await store.download(99);
    expect(store.directory.listSync(), isEmpty,
        reason: 'no temporary file is left behind');
    expect(store.has(99), isFalse);
  });

  test('cover art download does not retry on a transient 503', () async {
    // Cover art opts out of ApiClient's retry. A single failed thumbnail
    // shouldn't trigger 3 attempts (× many tiles = thundering herd) or flip
    // the whole app into offline mode via the network-failure hook.
    var calls = 0;
    final store = await buildStore(
      client: MockClient((req) async {
        calls++;
        return http.Response('try again', 503);
      }),
    );

    final ok = await store.download(42);
    expect(ok, isFalse);
    expect(calls, 1);
    expect(store.has(42), isFalse);
    expect(store.directory.listSync(), isEmpty,
        reason: 'no temporary file is left behind');
  });

  test('download returns false and cleans up when persistence fails', () async {
    final store = await buildStore(
      client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
    );

    // Pre-create a non-empty directory at the target path so `rename` fails.
    final blockingDir = Directory(p.join(store.directory.path, '77.bin'));
    await blockingDir.create();
    await File(p.join(blockingDir.path, 'inside')).writeAsBytes([0]);

    final ok = await store.download(77);
    expect(ok, isFalse);
    expect(
        store.directory.listSync().map((e) => p.basename(e.path)), ['77.bin'],
        reason: 'the temporary file must be cleaned up on filesystem failure');
  });

  // SP-PE-FE-12 / U25-B-03: two downloads of one cover (two tiles, or a
  // track download and a tile) used to share one fixed temp file: one
  // rename moved the other's bytes away, and its own rename then failed.
  test('two concurrent downloads of one cover both succeed', () async {
    final release = Completer<void>();
    var requests = 0;
    final bothSent = Completer<void>();
    final store = await buildStore(
      client: MockClient((_) async {
        if (++requests == 2) bothSent.complete();
        await release.future;
        return http.Response.bytes([5, 6, 7], 200);
      }),
    );

    final first = store.download(5);
    final second = store.download(5);
    await bothSent.future;
    release.complete();

    expect(await Future.wait([first, second]), [true, true]);
    expect(await store.fileFor(5).readAsBytes(), [5, 6, 7]);
    expect(
        store.directory.listSync().map((e) => p.basename(e.path)), ['5.bin'],
        reason: 'no temporary file is left behind');
  });

  // Review #1 (TR-SWITCH-07 follow-up): the reset no longer waits for ever
  // on a download worker, and a worker may be fetching a track's cover. A
  // cover whose response lands after the reset is the previous library's
  // picture and must not be stored.
  test('a cover whose response lands after a reset is not stored', () async {
    final release = Completer<void>();
    final sent = Completer<void>();
    final store = await buildStore(
      client: MockClient((_) async {
        sent.complete();
        await release.future;
        return http.Response.bytes([1, 2], 200);
      }),
    );

    final download = store.download(9);
    await sent.future;
    await store.resetLocalState();
    release.complete();

    expect(await download, isFalse);
    expect(store.directory.listSync(), isEmpty,
        reason: 'the previous library\'s cover was written after the reset');
  });

  test('remove deletes the on-disk file', () async {
    final store = await buildStore(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );

    await store.download(3);
    expect(store.has(3), isTrue);
    await store.remove(3);
    expect(store.has(3), isFalse);
  });

  // Section 6 #8: the downloads' cover clean-up.
  test('removeIfUnused deletes a cover only when nothing uses it', () async {
    final store = await buildStore();
    store.fileFor(4).writeAsBytesSync([1]);

    expect(await store.removeIfUnused(4, () async => true), isFalse);
    expect(store.has(4), isTrue);
    expect(await store.removeIfUnused(4, () async => false), isTrue);
    expect(store.has(4), isFalse);
    expect(await store.removeIfUnused(4, () async => false), isFalse,
        reason: 'nothing to remove');
  });

  // A download committed while its cover is being removed must not skip the
  // cover on the strength of a file about to go: the lookup waits for the
  // removal, then answers.
  test('a lookup during a removal answers after it', () async {
    final store = await buildStore();
    store.fileFor(6).writeAsBytesSync([1]);
    final checking = Completer<void>();
    final answer = Completer<bool>();

    final removal = store.removeIfUnused(6, () {
      checking.complete();
      return answer.future;
    });
    await checking.future;
    final stored = store.holds(6);
    answer.complete(false);

    expect(await removal, isTrue);
    expect(await stored, isFalse);
  });

  test('clear removes every stored file', () async {
    final store = await buildStore(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    await store.download(1);
    await store.download(2);
    await store.download(3);

    await store.clear();

    expect(store.directory.listSync(), isEmpty);
    expect(store.has(1), isFalse);
  });

  // TR-SWITCH-02: after a reset (log-out, server switch) the next library's
  // cover with the same id is a different picture at the same file path. A
  // decoded image kept in Flutter's image cache under that path would keep
  // showing the previous library's cover.
  test('reset evicts decoded cover images from the image cache', () async {
    final store = await buildStore(
      client: MockClient((_) async => http.Response.bytes([1, 2], 200)),
    );
    await store.download(42);
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(() => cache
      ..clear()
      ..clearLiveImages());
    final key = FileImage(store.fileFor(42));
    final completer =
        OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
    final listener = ImageStreamListener((_, _) {});
    cache.putIfAbsent(key, () => completer);
    // A cover on screen: its stream has a listener, so it is a live image.
    completer.addListener(listener);
    addTearDown(() => completer.removeListener(listener));
    expect(cache.containsKey(key), isTrue);
    expect(cache.liveImageCount, 1);

    await store.resetLocalState();

    expect(cache.containsKey(key), isFalse,
        reason: 'the previous library\'s decoded cover is still cached');
    expect(cache.liveImageCount, 0,
        reason: 'a cover on screen keeps its decoded image cached');
  });

  test('downloads and removals leave the image cache alone', () async {
    final store = await buildStore(
      client: MockClient((_) async => http.Response.bytes([1, 2], 200)),
    );
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(() => cache
      ..clear()
      ..clearLiveImages());
    final key = FileImage(store.fileFor(7));
    final completer =
        OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
    cache.putIfAbsent(key, () => completer);
    final listener = ImageStreamListener((_, _) {});
    completer.addListener(listener);
    addTearDown(() => completer.removeListener(listener));

    await store.download(8);
    await store.remove(8);

    // Ordinary use never blanks a cover on screen.
    expect(cache.containsKey(key), isTrue);
    expect(cache.liveImageCount, 1);
  });
}
