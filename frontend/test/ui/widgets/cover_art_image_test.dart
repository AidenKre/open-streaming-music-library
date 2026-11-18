import 'package:flutter/material.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';

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
}
