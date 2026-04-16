import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';

const _artist = ArtistUI(id: 1, name: 'Test Artist');
const _artistWithArt = ArtistUI(id: 1, name: 'Test Artist', coverArtId: 3);

Widget buildCard(
  ArtistUI artist, {
  double width = 200,
  double height = 240,
  bool downloaded = false,
  VoidCallback? onPlayNext,
  VoidCallback? onAddToQueue,
  VoidCallback? onDownload,
  void Function(String)? onDownloadAtQuality,
  VoidCallback? onDeleteDownload,
}) {
  return ProviderScope(
    overrides: [
      artistDownloadedProvider.overrideWith((ref, artistId) async => downloaded),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: height,
          child: ArtistCard(
            artist: artist,
            onTap: () {},
            onPlayNext: onPlayNext,
            onAddToQueue: onAddToQueue,
            onDownload: onDownload,
            onDownloadAtQuality: onDownloadAtQuality,
            onDeleteDownload: onDeleteDownload,
          ),
        ),
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
      'keeps cover art square in compact search-style layout',
      (tester) async {
        await tester.pumpWidget(
          buildCard(_artistWithArt, width: 140, height: 190),
        );

        final imageSize = tester.getSize(find.byType(Image));
        expect(imageSize.width, imageSize.height);
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

  group('ArtistCard download state', () {
    testWidgets('shows downloaded badge when fully downloaded', (tester) async {
      await tester.pumpWidget(buildCard(_artist, downloaded: true));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.download_done), findsOneWidget);
    });

    testWidgets('omits badge when not fully downloaded', (tester) async {
      await tester.pumpWidget(buildCard(_artist, downloaded: false));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.download_done), findsNothing);
    });

    testWidgets('long-press menu shows Download for un-downloaded artist',
        (tester) async {
      var downloadCalled = false;
      await tester.pumpWidget(buildCard(
        _artist,
        downloaded: false,
        onDownload: () => downloadCalled = true,
        onDeleteDownload: () {},
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(ArtistCard));
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Delete downloads'), findsNothing);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(downloadCalled, isTrue);
    });

    testWidgets('long-press menu shows Delete downloads when fully downloaded',
        (tester) async {
      var deleteCalled = false;
      await tester.pumpWidget(buildCard(
        _artist,
        downloaded: true,
        onDownload: () {},
        onDeleteDownload: () => deleteCalled = true,
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(ArtistCard));
      await tester.pumpAndSettle();

      expect(find.text('Delete downloads'), findsOneWidget);
      expect(find.text('Download'), findsNothing);

      await tester.tap(find.text('Delete downloads'));
      await tester.pumpAndSettle();
      expect(deleteCalled, isTrue);
    });

    testWidgets('split tile shows chevron icon', (tester) async {
      await tester.pumpWidget(buildCard(
        _artist,
        downloaded: false,
        onDownload: () {},
        onDownloadAtQuality: (_) {},
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(ArtistCard));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('chevron opens quality sheet and calls onDownloadAtQuality',
        (tester) async {
      String? chosenQuality;
      await tester.pumpWidget(buildCard(
        _artist,
        downloaded: false,
        onDownload: () {},
        onDownloadAtQuality: (q) => chosenQuality = q,
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(ArtistCard));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(find.text('Download quality'), findsOneWidget);
      expect(find.text('320 kbps'), findsOneWidget);

      await tester.tap(find.text('320 kbps'));
      await tester.pumpAndSettle();

      expect(chosenQuality, '320');
    });
  });
}
