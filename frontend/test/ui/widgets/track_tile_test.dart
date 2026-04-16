import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

TrackUI _track({
  bool hasAlbumArt = false,
  int? coverArtId,
  String? filePath,
}) {
  return TrackUI(
    uuidId: 'test-uuid',
    filePath: filePath,
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

  Widget buildTile(
    TrackUI track, {
    bool isHighlighted = false,
    VoidCallback? onPlayNext,
    VoidCallback? onAddToQueue,
    VoidCallback? onDownload,
    void Function(String)? onDownloadAtQuality,
    VoidCallback? onDeleteDownload,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: TrackTile(
          track: track,
          isHighlighted: isHighlighted,
          onPlayNext: onPlayNext,
          onAddToQueue: onAddToQueue,
          onDownload: onDownload,
          onDownloadAtQuality: onDownloadAtQuality,
          onDeleteDownload: onDeleteDownload,
        ),
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

  group('TrackTile downloaded indicator', () {
    testWidgets('shows download_done icon when track is downloaded',
        (tester) async {
      await tester.pumpWidget(buildTile(_track(filePath: '/tmp/abc.audio')));

      expect(find.byIcon(Icons.download_done), findsOneWidget);
    });

    testWidgets('omits the icon when track is not downloaded', (tester) async {
      await tester.pumpWidget(buildTile(_track()));

      expect(find.byIcon(Icons.download_done), findsNothing);
    });
  });

  group('TrackTile context menu', () {
    testWidgets('Download menu item appears for un-downloaded tracks',
        (tester) async {
      var downloadCalled = false;
      await tester.pumpWidget(buildTile(
        _track(),
        onPlayNext: () {},
        onDownload: () => downloadCalled = true,
        onDeleteDownload: () {},
      ));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Delete download'), findsNothing);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(downloadCalled, isTrue);
    });

    testWidgets('Delete download appears instead when track is downloaded',
        (tester) async {
      var deleteCalled = false;
      await tester.pumpWidget(buildTile(
        _track(filePath: '/tmp/abc.audio'),
        onPlayNext: () {},
        onDownload: () {},
        onDeleteDownload: () => deleteCalled = true,
      ));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Delete download'), findsOneWidget);
      expect(find.text('Download'), findsNothing);

      await tester.tap(find.text('Delete download'));
      await tester.pumpAndSettle();
      expect(deleteCalled, isTrue);
    });

    testWidgets('split tile shows chevron icon in track menu', (tester) async {
      await tester.pumpWidget(buildTile(
        _track(),
        onPlayNext: () {},
        onDownload: () {},
        onDownloadAtQuality: (_) {},
      ));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('chevron in track menu opens quality sheet', (tester) async {
      String? chosenQuality;
      await tester.pumpWidget(buildTile(
        _track(),
        onPlayNext: () {},
        onDownload: () {},
        onDownloadAtQuality: (q) => chosenQuality = q,
      ));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(find.text('Download quality'), findsOneWidget);
      expect(find.text('Original'), findsOneWidget);

      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();

      expect(chosenQuality, 'original');
    });
  });
}
