import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/ui/widgets/artist_card.dart';

const _artist = ArtistUI(id: 1, name: 'Test Artist');
const _artistWithArt = ArtistUI(id: 1, name: 'Test Artist', coverArtId: 3);

Widget buildCard(ArtistUI artist) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 200,
        height: 240,
        child: ArtistCard(artist: artist, onTap: () {}),
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  group('ArtistCard cover art', () {
    testWidgets(
      'shows fallback person icon when no cover art',
      (tester) async {
        await tester.pumpWidget(buildCard(_artist));

        expect(find.byIcon(Icons.person), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );

    testWidgets(
      'shows Image when coverArtId is set',
      (tester) async {
        await tester.pumpWidget(buildCard(_artistWithArt));

        expect(find.byType(Image), findsOneWidget);
      },
    );

    testWidgets(
      'artist name is displayed correctly',
      (tester) async {
        await tester.pumpWidget(buildCard(_artist));

        expect(find.text('Test Artist'), findsOneWidget);
      },
    );
  });
}
