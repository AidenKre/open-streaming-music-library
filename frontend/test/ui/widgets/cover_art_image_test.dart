import 'dart:async';
import 'dart:io' show SocketException;

import 'package:file/file.dart' show File;

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';

import '../../helpers/test_offline.dart';

void main() {
  Widget buildSizedWidget({
    required bool hasAlbumArt,
    required int? coverArtId,
    required double width,
    required double height,
  }) {
    return ProviderScope(
      overrides: [
        coverArtCacheProvider.overrideWithValue(
        CoverArtCacheManager.noop(
          api: testApiClient(
            'http://localhost:8000',
            MockClient((_) async => http.Response('', 404)),
          ),
        ),
      ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CoverArtImage(
            hasAlbumArt: hasAlbumArt,
            coverArtId: coverArtId,
            width: width,
            height: height,
            borderRadius: BorderRadius.circular(4),
            fallback: const Icon(Icons.music_note),
          ),
        ),
      ),
    );
  }

  Widget buildWidget({required bool hasAlbumArt, required int? coverArtId}) {
    return buildSizedWidget(
      hasAlbumArt: hasAlbumArt,
      coverArtId: coverArtId,
      width: 48,
      height: 48,
    );
  }

  group('CoverArtImage', () {
    testWidgets('shows fallback when hasAlbumArt=false and coverArtId=null', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildWidget(hasAlbumArt: false, coverArtId: null),
      );

      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('shows fallback when hasAlbumArt=true but coverArtId=null', (
      tester,
    ) async {
      await tester.pumpWidget(buildWidget(hasAlbumArt: true, coverArtId: null));

      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('shows fallback when hasAlbumArt=false but coverArtId is set', (
      tester,
    ) async {
      await tester.pumpWidget(buildWidget(hasAlbumArt: false, coverArtId: 5));

      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('shows Image when hasAlbumArt=true and coverArtId is set', (
      tester,
    ) async {
      await tester.pumpWidget(buildWidget(hasAlbumArt: true, coverArtId: 5));

      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('Image uses correct URL from ApiClient', (tester) async {
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildWidget(hasAlbumArt: true, coverArtId: 42));

      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image as ResizeImage;
      expect(provider.width, 96);
      expect(provider.height, 96);
      expect(
        (provider.imageProvider as NetworkImage).url,
        'http://localhost:8000/cover_art/42',
      );
    });

    testWidgets('uses the full requested decode size for larger artwork', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildSizedWidget(
          hasAlbumArt: true,
          coverArtId: 42,
          width: 140,
          height: 140,
        ),
      );

      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image as ResizeImage;
      expect(provider.width, 140);
      expect(provider.height, 140);
    });

    testWidgets('frameBuilder shows fallback before first frame arrives', (
      tester,
    ) async {
      await tester.pumpWidget(buildWidget(hasAlbumArt: true, coverArtId: 99));

      final image = tester.widget<Image>(find.byType(Image));
      // Simulate frameBuilder called with frame=null (loading)
      final result = image.frameBuilder!(
        tester.element(find.byType(Image)),
        const SizedBox(), // child
        null, // frame (null = not yet loaded)
        false, // wasSynchronouslyLoaded
      );
      expect(result, isA<Icon>());
      expect((result as Icon).icon, Icons.music_note);
    });

    testWidgets('errorBuilder shows fallback on load failure', (tester) async {
      await tester.pumpWidget(buildWidget(hasAlbumArt: true, coverArtId: 99));

      final image = tester.widget<Image>(find.byType(Image));
      final result = image.errorBuilder!(
        tester.element(find.byType(Image)),
        Exception('network error'),
        null,
      );
      expect(result, isA<Icon>());
      expect((result as Icon).icon, Icons.music_note);
    });
  });

  // Other-issues row 73: a tile whose load failed loads again when the
  // connection returns; a tile that did not fail keeps its image.
  group('reconnecting', () {
    Widget tile(_FlakyDiskCache cache, TestOffline offline) => ProviderScope(
          overrides: [
            offlineModeProvider.overrideWith(() => offline),
            coverArtCacheProvider.overrideWithValue(CoverArtCacheManager(
              api: testApiClient(
                'http://localhost:8000',
                MockClient((_) async => http.Response('', 500)),
              ),
              cache: cache,
            )),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CoverArtImage(
                hasAlbumArt: true,
                coverArtId: 7,
                width: 48,
                height: 48,
                borderRadius: BorderRadius.circular(4),
                fallback: const Icon(Icons.music_note),
              ),
            ),
          ),
        );

    testWidgets('a tile whose load failed loads again on reconnect',
        (tester) async {
      final cache = _FlakyDiskCache(fail: true);
      final offline = TestOffline(false);
      await tester.pumpWidget(tile(cache, offline));
      await tester.pump();
      expect(cache.loads, 1);
      expect(find.byIcon(Icons.music_note), findsOneWidget);

      // The app keeps the offline flag alive; here the test does.
      ProviderScope.containerOf(tester.element(find.byType(Scaffold)))
          .listen(offlineModeProvider, (_, _) {});
      offline.set(true);
      await tester.pump();
      offline.set(false);
      await tester.pump();
      await tester.pump();
      expect(cache.loads, 2);
      imageCache.clear();
    });

    // Review F2: the retried load is pending; the old error must not mark
    // the tile failed again, or every later reconnect would load it again.
    testWidgets('a retried tile still loading is not loaded again at the next '
        'reconnect', (tester) async {
      final cache = _FlakyDiskCache(fail: true, failFirstOnly: true);
      final offline = TestOffline(false);
      await tester.pumpWidget(tile(cache, offline));
      await tester.pump();
      ProviderScope.containerOf(tester.element(find.byType(Scaffold)))
          .listen(offlineModeProvider, (_, _) {});
      for (var i = 0; i < 2; i++) {
        offline.set(true);
        await tester.pump();
        offline.set(false);
        await tester.pump();
        await tester.pump();
      }
      expect(cache.loads, 2, reason: 'one retry, still pending');
      imageCache.clear();
    });

    testWidgets('a tile that has not failed is not loaded again',
        (tester) async {
      final cache = _FlakyDiskCache(fail: false);
      final offline = TestOffline(false);
      await tester.pumpWidget(tile(cache, offline));
      await tester.pump();
      final before = tester.widget<Image>(find.byType(Image)).image;

      // The app keeps the offline flag alive; here the test does.
      ProviderScope.containerOf(tester.element(find.byType(Scaffold)))
          .listen(offlineModeProvider, (_, _) {});
      offline.set(true);
      await tester.pump();
      offline.set(false);
      await tester.pump();
      await tester.pump();
      expect(cache.loads, 1);
      expect(tester.widget<Image>(find.byType(Image)).image, before);
      imageCache.clear();
    });
  });
}

/// A disk cache whose every fetch fails ([fail]) or never answers.
class _FlakyDiskCache extends Fake implements BaseCacheManager {
  _FlakyDiskCache({required this.fail, this.failFirstOnly = false});
  final bool fail;

  /// Only the first fetch fails; later ones never answer.
  final bool failFirstOnly;
  int loads = 0;

  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) {
    loads++;
    return fail && (!failFirstOnly || loads == 1)
        ? Future.error(const SocketException('offline'))
        : Completer<File>().future;
  }
}

