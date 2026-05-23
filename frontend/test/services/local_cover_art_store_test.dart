import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/services/local_cover_art_store.dart';

void main() {
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

  void installClient(http.Client client) {
    ApiClient.initForTest('http://test:8080', client);
  }

  Future<LocalCoverArtStore> buildStore({http.Client? client}) {
    installClient(client ?? MockClient((_) async => http.Response('', 404)));
    return LocalCoverArtStore.create(
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
    final partial = File(p.join(store.directory.path, '99.bin.partial'));
    expect(partial.existsSync(), isFalse);
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
    final partial = File(p.join(store.directory.path, '42.bin.partial'));
    expect(partial.existsSync(), isFalse);
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
    final partial = File(p.join(store.directory.path, '77.bin.partial'));
    expect(partial.existsSync(), isFalse,
        reason: '.partial must be cleaned up on filesystem failure');
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
}
