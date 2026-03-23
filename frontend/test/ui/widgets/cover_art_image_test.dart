import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';

void main() {
  setUpAll(() {
    ApiClient.init('http://localhost:8000');
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
        expect(find.byType(CachedNetworkImage), findsNothing);
      },
    );

    testWidgets(
      'shows fallback when hasAlbumArt=true but coverArtId=null',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: true, coverArtId: null),
        );

        expect(find.byIcon(Icons.music_note), findsOneWidget);
        expect(find.byType(CachedNetworkImage), findsNothing);
      },
    );

    testWidgets(
      'shows fallback when hasAlbumArt=false but coverArtId is set',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: false, coverArtId: 5),
        );

        expect(find.byIcon(Icons.music_note), findsOneWidget);
        expect(find.byType(CachedNetworkImage), findsNothing);
      },
    );

    testWidgets(
      'shows CachedNetworkImage when hasAlbumArt=true and coverArtId is set',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: true, coverArtId: 5),
        );

        // CachedNetworkImage is in the tree (image load is async;
        // the placeholder/error widget may still appear, which is correct)
        expect(find.byType(CachedNetworkImage), findsOneWidget);
      },
    );

    testWidgets(
      'CachedNetworkImage uses correct URL from ApiClient',
      (tester) async {
        await tester.pumpWidget(
          buildWidget(hasAlbumArt: true, coverArtId: 42),
        );

        final image = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        expect(image.imageUrl, 'http://localhost:8000/cover_art/42');
      },
    );

    testWidgets(
      'placeholder builder returns fallback widget',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CoverArtImage(
                hasAlbumArt: true,
                coverArtId: 99,
                width: 48,
                height: 48,
                borderRadius: BorderRadius.circular(4),
                fallback: const Icon(Icons.music_note),
              ),
            ),
          ),
        );

        final image = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        // Verify placeholder builder produces our fallback
        final placeholder = image.placeholder!(
          tester.element(find.byType(CachedNetworkImage)),
          'http://localhost:8000/cover_art/99',
        );
        expect(placeholder, isA<Icon>());
        expect((placeholder as Icon).icon, Icons.music_note);
      },
    );

    testWidgets(
      'errorWidget builder returns fallback widget',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CoverArtImage(
                hasAlbumArt: true,
                coverArtId: 99,
                width: 48,
                height: 48,
                borderRadius: BorderRadius.circular(4),
                fallback: const Icon(Icons.music_note),
              ),
            ),
          ),
        );

        final image = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        final errorWidget = image.errorWidget!(
          tester.element(find.byType(CachedNetworkImage)),
          'http://localhost:8000/cover_art/99',
          Exception('network error'),
        );
        expect(errorWidget, isA<Icon>());
        expect((errorWidget as Icon).icon, Icons.music_note);
      },
    );
  });
}
