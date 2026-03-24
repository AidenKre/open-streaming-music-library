import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';

void main() {
  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  Widget buildWidget({
    required bool hasAlbumArt,
    required int? coverArtId,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: CoverArtImage(
          hasAlbumArt: hasAlbumArt,
          coverArtId: coverArtId,
          width: 48,
          height: 48,
          borderRadius: BorderRadius.circular(4),
          fallback: const Icon(Icons.music_note),
        ),
      ),
    );
  }

  group('CoverArtImage', () {
    testWidgets(
      'shows fallback when hasAlbumArt=false and coverArtId=null',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: false, coverArtId: null),
        );

        expect(find.byIcon(Icons.music_note), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );

    testWidgets(
      'shows fallback when hasAlbumArt=true but coverArtId=null',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: true, coverArtId: null),
        );

        expect(find.byIcon(Icons.music_note), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );

    testWidgets(
      'shows fallback when hasAlbumArt=false but coverArtId is set',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: false, coverArtId: 5),
        );

        expect(find.byIcon(Icons.music_note), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );

    testWidgets(
      'shows Image when hasAlbumArt=true and coverArtId is set',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: true, coverArtId: 5),
        );

        expect(find.byType(Image), findsOneWidget);
      },
    );

    testWidgets(
      'Image uses correct URL from ApiClient',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: true, coverArtId: 42),
        );

        final image = tester.widget<Image>(find.byType(Image));
        final provider = image.image as NetworkImage;
        expect(provider.url, 'http://localhost:8000/cover_art/42');
      },
    );

    testWidgets(
      'frameBuilder shows fallback before first frame arrives',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: true, coverArtId: 99),
        );

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
      },
    );

    testWidgets(
      'errorBuilder shows fallback on load failure',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: true, coverArtId: 99),
        );

        final image = tester.widget<Image>(find.byType(Image));
        final result = image.errorBuilder!(
          tester.element(find.byType(Image)),
          Exception('network error'),
          null,
        );
        expect(result, isA<Icon>());
        expect((result as Icon).icon, Icons.music_note);
      },
    );
  });
}
