import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/ui/widgets/album_card.dart';

const _kArtistId = 1;
const _kAlbumId = 1;

const _album = AlbumUI(
  id: _kAlbumId,
  name: 'Test Album',
  artist: 'Test Artist',
  artistId: _kArtistId,
  year: 2024,
);

const _albumWithArt = AlbumUI(
  id: _kAlbumId,
  name: 'Test Album',
  artist: 'Test Artist',
  artistId: _kArtistId,
  year: 2024,
  coverArtId: 7,
);

const _singleAlbum = AlbumUI(
  id: _kAlbumId,
  artistId: _kArtistId,
  isSingleGrouping: true,
);

Widget buildCard(AlbumUI album) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 200,
        height: 280,
        child: AlbumCard(album: album, onTap: () {}),
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    ApiClient.init('http://localhost:8000');
  });

  group('AlbumCard cover art', () {
    testWidgets(
      'shows fallback album icon when no cover art',
      (tester) async {
        await tester.pumpWidget(buildCard(_album));

        expect(find.byIcon(Icons.album), findsOneWidget);
        expect(find.byType(CachedNetworkImage), findsNothing);
      },
    );

    testWidgets(
      'shows CachedNetworkImage when coverArtId is set',
      (tester) async {
        await tester.pumpWidget(buildCard(_albumWithArt));

        expect(find.byType(CachedNetworkImage), findsOneWidget);
      },
    );

    testWidgets(
      'single album shows library_music_outlined fallback icon when no art',
      (tester) async {
        await tester.pumpWidget(buildCard(_singleAlbum));

        expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
      },
    );

    testWidgets(
      'displays album name correctly',
      (tester) async {
        await tester.pumpWidget(buildCard(_album));

        expect(find.text('Test Album'), findsOneWidget);
      },
    );
  });
}
