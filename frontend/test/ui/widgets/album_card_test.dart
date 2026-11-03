import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';

import '../fake_library_actions.dart';

/// Forces [offlineModeProvider] to a fixed value without starting the real
/// health-poll timer.
class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

// Distinct so a swapped (artist, album) scope cannot pass.
const _kArtistId = 3;
const _kAlbumId = 7;

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
  bool offline = false,
  ({int downloaded, int total})? counts,
  FakeLibraryActions? actions,
}) {
  final effectiveCounts =
      counts ?? (downloaded: downloaded ? 10 : 0, total: 10);
  return ProviderScope(
    overrides: [
      // Keep the card isolated — don't build the real download-manager graph.
      albumIsDownloadingProvider.overrideWith((ref, albumId) => false),
      albumDownloadCountsProvider.overrideWith(
        (ref, albumId) => AsyncData(effectiveCounts),
      ),
      offlineModeProvider.overrideWith(() => _StubOffline(offline)),
      // The menu reads availability for its scope from the same counts.
      playbackAvailabilityProvider.overrideWith(
        (ref, scope) => PlaybackAvailability.of(
          offline: offline,
          downloaded: effectiveCounts.downloaded,
          total: effectiveCounts.total,
        ),
      ),
      libraryActionsProvider.overrideWithValue(
        actions ?? FakeLibraryActions(),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 280,
          child: AlbumCard(
            album: album,
            onTap: () {},
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
      final actions = FakeLibraryActions();
      await tester.pumpWidget(buildCard(
        actions: actions,
        _album,
        downloaded: false,
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Delete downloads'), findsNothing);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['download album(3,7)']);
    });

    testWidgets('long-press menu shows Delete downloads when downloaded',
        (tester) async {
      final actions = FakeLibraryActions();
      await tester.pumpWidget(buildCard(
        actions: actions,
        _album,
        downloaded: true,
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.text('Delete downloads'), findsOneWidget);
      expect(find.text('Download'), findsNothing);

      await tester.tap(find.text('Delete downloads'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['deleteDownloads album(3,7)']);
    });

    testWidgets('offline: no Download row (downloading needs the server)',
          (tester) async {
      await tester.pumpWidget(buildCard(
        _album,
        downloaded: false,
        offline: true,
        counts: (downloaded: 0, total: 10),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('split tile shows chevron icon', (tester) async {
      await tester.pumpWidget(buildCard(
        _album,
        downloaded: false,
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('chevron opens quality sheet and downloads at that quality',
        (tester) async {
      final actions = FakeLibraryActions();
      await tester.pumpWidget(buildCard(
        actions: actions,
        _album,
        downloaded: false,
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

      expect(actions.calls, ['downloadAtQuality album(3,7) 128']);
    });
  });

  group('AlbumCard offline mode', () {
    testWidgets(
      'partially downloaded: queue actions disabled, delete available',
      (tester) async {
        await tester.pumpWidget(buildCard(
          _album,
          offline: true,
          counts: (downloaded: 3, total: 10),
        ));
        await tester.pumpAndSettle();

        await tester.longPress(find.byType(AlbumCard));
        await tester.pumpAndSettle();

        final playNext = tester.widget<ListTile>(find.ancestor(
          of: find.text('Play Next'),
          matching: find.byType(ListTile),
        ));
        final addToQueue = tester.widget<ListTile>(find.ancestor(
          of: find.text('Add to Queue'),
          matching: find.byType(ListTile),
        ));
        expect(playNext.enabled, isFalse);
        expect(addToQueue.enabled, isFalse);
        expect(find.text('Delete downloads'), findsOneWidget);
      },
    );

    testWidgets('fully downloaded: queue actions enabled', (tester) async {
      await tester.pumpWidget(buildCard(
        _album,
        offline: true,
        counts: (downloaded: 10, total: 10),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      final playNext = tester.widget<ListTile>(find.ancestor(
        of: find.text('Play Next'),
        matching: find.byType(ListTile),
      ));
      expect(playNext.enabled, isTrue);
    });
  });

  testWidgets('menu queue actions act on this card\'s scope', (tester) async {
    final actions = FakeLibraryActions();
    await tester.pumpWidget(buildCard(_album, actions: actions));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(AlbumCard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play Next'));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(AlbumCard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to Queue'));
    await tester.pumpAndSettle();
    expect(actions.calls, ['playNext album(3,7)', 'addToQueue album(3,7)']);
  });
}
