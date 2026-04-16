import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';

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

Widget buildCard(
  AlbumUI album, {
  bool downloaded = false,
  VoidCallback? onPlayNext,
  VoidCallback? onAddToQueue,
  VoidCallback? onDownload,
  void Function(String)? onDownloadAtQuality,
  VoidCallback? onDeleteDownload,
}) {
  return ProviderScope(
    overrides: [
      albumDownloadedProvider.overrideWith((ref, albumId) async => downloaded),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 280,
          child: AlbumCard(
            album: album,
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

  group('AlbumCard cover art', () {
    testWidgets(
      'shows fallback album icon when no cover art',
      (tester) async {
        await tester.pumpWidget(buildCard(_album));

        expect(find.byIcon(Icons.album), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );

    testWidgets(
      'shows Image when coverArtId is set',
      (tester) async {
        await tester.pumpWidget(buildCard(_albumWithArt));

        expect(find.byType(Image), findsOneWidget);
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

  group('AlbumCard download state', () {
    testWidgets('shows downloaded badge when fully downloaded', (tester) async {
      await tester.pumpWidget(buildCard(_album, downloaded: true));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.download_done), findsOneWidget);
    });

    testWidgets('omits downloaded badge when not fully downloaded',
        (tester) async {
      await tester.pumpWidget(buildCard(_album, downloaded: false));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.download_done), findsNothing);
    });

    testWidgets('long-press menu shows Download for un-downloaded album',
        (tester) async {
      var downloaded = false;
      await tester.pumpWidget(buildCard(
        _album,
        downloaded: false,
        onDownload: () => downloaded = true,
        onDeleteDownload: () {},
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Delete downloads'), findsNothing);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(downloaded, isTrue);
    });

    testWidgets('long-press menu shows Delete downloads when downloaded',
        (tester) async {
      var deleted = false;
      await tester.pumpWidget(buildCard(
        _album,
        downloaded: true,
        onDownload: () {},
        onDeleteDownload: () => deleted = true,
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.text('Delete downloads'), findsOneWidget);
      expect(find.text('Download'), findsNothing);

      await tester.tap(find.text('Delete downloads'));
      await tester.pumpAndSettle();
      expect(deleted, isTrue);
    });

    testWidgets('split tile shows chevron icon', (tester) async {
      await tester.pumpWidget(buildCard(
        _album,
        downloaded: false,
        onDownload: () {},
        onDownloadAtQuality: (_) {},
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('chevron opens quality sheet and calls onDownloadAtQuality',
        (tester) async {
      String? chosenQuality;
      await tester.pumpWidget(buildCard(
        _album,
        downloaded: false,
        onDownload: () {},
        onDownloadAtQuality: (q) => chosenQuality = q,
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      // Quality sheet should be visible.
      expect(find.text('Download quality'), findsOneWidget);
      expect(find.text('128 kbps'), findsOneWidget);

      await tester.tap(find.text('128 kbps'));
      await tester.pumpAndSettle();

      expect(chosenQuality, '128');
    });
  });
}
