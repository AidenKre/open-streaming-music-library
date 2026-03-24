import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

TrackUI _track({bool hasAlbumArt = false, int? coverArtId}) {
  return TrackUI(
    uuidId: 'test-uuid',
    createdAt: 1,
    lastUpdated: 1,
    title: 'Test Track',
    artist: 'Test Artist',
    duration: 180,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: hasAlbumArt,
    coverArtId: coverArtId,
  );
}

void main() {
  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  Widget buildTile(TrackUI track, {bool isHighlighted = false}) {
    return MaterialApp(
      home: Scaffold(
        body: TrackTile(track: track, isHighlighted: isHighlighted),
      ),
    );
  }

  group('TrackTile cover art', () {
    testWidgets(
      'shows music note fallback when track has no cover art',
      (tester) async {
        await tester.pumpWidget(
          buildTile(_track(hasAlbumArt: false, coverArtId: null)),
        );

        expect(find.byIcon(Icons.music_note), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );

    testWidgets(
      'shows CoverArtImage when track has cover art',
      (tester) async {
        await tester.pumpWidget(
          buildTile(_track(hasAlbumArt: true, coverArtId: 42)),
        );

        expect(find.byType(CoverArtImage), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
      },
    );

    testWidgets(
      'highlighted track shows equalizer icon regardless of cover art',
      (tester) async {
        await tester.pumpWidget(
          buildTile(
            _track(hasAlbumArt: true, coverArtId: 42),
            isHighlighted: true,
          ),
        );

        expect(find.byIcon(Icons.equalizer), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );
  });
}
