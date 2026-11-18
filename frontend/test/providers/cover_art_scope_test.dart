// Phase M §7.2 "Process-lifetime artwork objects stay global, but auth is per
// call" (M-U19 art): the disk cache is process-wide; the cover-art wrappers
// (CoverArtCacheManager, LocalCoverArtStore) are built per provider scope
// over that scope's client, and views read the scope-bound provider.
import 'dart:io';

import 'package:file/file.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The process-wide disk cache: records what each scope asks it for.
class _SpyDiskCache extends Fake implements BaseCacheManager {
  final requested = <String>[];

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) {
    requested.add(url);
    return Future.error(const SocketException('not in this test'));
  }
}

void main() {
  late Directory dir;
  late _SpyDiskCache disk;
  final served = <Uri>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cover_art_scope_test_');
    disk = _SpyDiskCache();
    served.clear();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ProviderContainer scope(String url) {
    final c = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          testApiClient(
            url,
            MockClient((req) async {
              served.add(req.url);
              return http.Response.bytes([1, 2, 3], 200);
            }),
          ),
        ),
        coverArtDirectoryProvider.overrideWithValue(dir),
        coverArtDiskCacheProvider.overrideWithValue(disk),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test("each scope's cover-art URLs use that scope's server over one shared "
      'disk cache', () async {
    final a = scope('http://a:1');
    final b = scope('http://b:2');

    a.read(coverArtCacheProvider).prefetch([7]);
    b.read(coverArtCacheProvider).prefetch([7]);
    await pumpEventQueue();

    expect(disk.requested, ['http://a:1/cover_art/7', 'http://b:2/cover_art/7']);
  });

  test("the local cover-art store downloads through its scope's client",
      () async {
    final a = scope('http://a:1');

    expect(await a.read(localCoverArtStoreProvider).download(9), isTrue);

    expect(served.map((u) => u.toString()), ['http://a:1/cover_art/9']);
    expect(a.read(localCoverArtStoreProvider).has(9), isTrue);
  });

  testWidgets('CoverArtImage reads the scope-bound cover-art provider',
      (tester) async {
    final manager = CoverArtCacheManager(
      api: testApiClient(
        'http://scope:3',
        MockClient((_) async => http.Response('', 404)),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [coverArtCacheProvider.overrideWithValue(manager)],
        child: const MaterialApp(
          home: CoverArtImage(
            hasAlbumArt: true,
            coverArtId: 5,
            width: 40,
            height: 40,
            borderRadius: BorderRadius.zero,
            fallback: SizedBox(),
          ),
        ),
      ),
    );

    ImageProvider provider = tester.widget<Image>(find.byType(Image)).image;
    if (provider is ResizeImage) provider = provider.imageProvider;
    expect(provider, isA<NetworkImage>());
    expect((provider as NetworkImage).url, 'http://scope:3/cover_art/5');
  });
}
