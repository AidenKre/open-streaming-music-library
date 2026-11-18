// 6-R1-05 / DEV-6-05: album and artist cards use one availability rule on
// every surface that shows them (browse grids, Search, Home, See all).
// Offline with nothing playable they dim but stay navigable; at least one
// playable member, online, or availability still unknown: not dimmed
// (unknown is not zero).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/library_card.dart';

import '../browse_harness.dart' show teardownTree;
import '../fake_library_actions.dart';
import '../../helpers/test_offline.dart';

const _album = AlbumUI(
    id: 7, name: 'Test Album', artist: 'Test Artist', artistId: 3);
const _artist = ArtistUI(id: 3, name: 'Test Artist');

/// [counts] null = the counts are still loading (availability unknown).
Widget _build(
  Widget Function(VoidCallback onTap) card, {
  required bool offline,
  required ({int downloaded, int total})? counts,
  required VoidCallback onTap,
}) {
  final availability = counts == null
      ? PlaybackAvailability.unknown(offline: offline)
      : PlaybackAvailability.of(
          offline: offline,
          downloaded: counts.downloaded,
          total: counts.total);
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
      albumIsDownloadingProvider.overrideWith((ref, id) => false),
      artistIsDownloadingProvider.overrideWith((ref, id) => false),
      albumDownloadCountsProvider.overrideWith((ref, id) =>
          counts == null ? const AsyncLoading() : AsyncData(counts)),
      artistDownloadCountsProvider.overrideWith((ref, id) =>
          counts == null ? const AsyncLoading() : AsyncData(counts)),
      offlineModeProvider.overrideWith(() => TestOffline(offline)),
      playbackAvailabilityProvider.overrideWith((ref, scope) => availability),
      libraryActionsProvider.overrideWithValue(FakeLibraryActions()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 200, height: 280, child: card(onTap)),
      ),
    ),
  );
}

void main() {
  final cards = <(String, Widget Function(VoidCallback))>[
    ('album card', (onTap) => AlbumCard(album: _album, onTap: onTap)),
    ('artist card', (onTap) => ArtistCard(artist: _artist, onTap: onTap)),
  ];

  bool dimmed(WidgetTester tester) =>
      tester.widget<LibraryCard>(find.byType(LibraryCard)).dimmed;

  for (final (name, card) in cards) {
    group(name, () {
      testWidgets('offline, nothing playable: dimmed and still navigable',
          (tester) async {
        var taps = 0;
        await tester.pumpWidget(_build(card,
            offline: true,
            counts: (downloaded: 0, total: 4),
            onTap: () => taps++));
        await tester.pumpAndSettle();
        expect(dimmed(tester), isTrue);
        await tester.tap(find.byType(LibraryCard));
        await tester.pumpAndSettle();
        expect(taps, 1, reason: 'a dimmed collection card still opens');
        await teardownTree(tester);
      });

      testWidgets('offline, one member playable: not dimmed', (tester) async {
        await tester.pumpWidget(_build(card,
            offline: true, counts: (downloaded: 1, total: 4), onTap: () {}));
        await tester.pumpAndSettle();
        expect(dimmed(tester), isFalse);
        await teardownTree(tester);
      });

      testWidgets('online, nothing downloaded: not dimmed', (tester) async {
        await tester.pumpWidget(_build(card,
            offline: false, counts: (downloaded: 0, total: 4), onTap: () {}));
        await tester.pumpAndSettle();
        expect(dimmed(tester), isFalse);
        await teardownTree(tester);
      });

      testWidgets('offline, availability unknown: not dimmed', (tester) async {
        await tester.pumpWidget(
            _build(card, offline: true, counts: null, onTap: () {}));
        await tester.pump();
        expect(dimmed(tester), isFalse,
            reason: 'unknown is not zero: not yet known is not "none"');
        await teardownTree(tester);
      });
    });
  }
}
