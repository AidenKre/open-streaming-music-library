import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/main.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/browse_controller.dart';
import 'package:frontend/ui/tracks_page.dart';

import 'browse_harness.dart';

class _FakeBrowse implements BrowseControls {
  int refreshes = 0;
  @override
  Future<void> refreshLibrary() async => refreshes++;
}

class _CountingSync extends TrackSyncNotifier {
  int syncs = 0;
  @override
  Future<TrackSyncState> build() async => const TrackSyncState();
  @override
  Future<void> sync() async => syncs++;
}

/// SC-26: pages ask their controller to refresh the library; they never
/// call the sync notifier themselves.
void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late _FakeBrowse browse;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'u1',
        title: 'Song',
        artistId: 1,
        artist: 'Ann',
        albumId: 2,
        album: 'Air',
      ),
    ]);
    harness = await BrowseHarness.create(db);
    browse = _FakeBrowse();
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      harness.wrap(
        page,
        overrides: [browseControlsProvider.overrideWithValue(browse)],
      ),
    );
    await tester.pumpAndSettle();
  }

  // 4A.4 (phase-4 §4): the session host runs the initial sync; only the
  // creation of a Tracks browse route still refreshes (was: every browse
  // page and detail refreshed once on creation).
  for (final (name, page, expected) in [
    ('Tracks browse', const TracksBrowsePage() as Widget, 1),
    ('Artists browse', const ArtistsBrowsePage(), 0),
    ('Albums browse', const AlbumsBrowsePage(), 0),
    (
      'artist detail (albums)',
      const Scaffold(body: AlbumsPage(artistId: 1)),
      0,
    ),
    (
      'album detail',
      const Scaffold(body: TracksPage(artistId: 1, albumId: 2)),
      0,
    ),
  ]) {
    testWidgets('$name refreshes the library $expected time(s) when created', (
      tester,
    ) async {
      await pump(tester, page);
      expect(browse.refreshes, expected);
      // Rebuilds do not add network work.
      await tester.pump(const Duration(seconds: 1));
      expect(browse.refreshes, expected);
      await teardownTree(tester);
    });
  }

  // 4A.4: the Tracks-tab re-select hook is gone (phase-4 §4); opening the
  // Tracks browse route from Home refreshes instead, and re-tapping the tab
  // does not (was: re-selecting the Tracks tab refreshed again).
  testWidgets('opening Tracks browse from Home refreshes; re-tapping Home '
      'does not', (tester) async {
    await pump(tester, const AppShell());
    expect(browse.refreshes, 0);
    await tester.tap(find.text('Tracks'));
    await tester.pumpAndSettle();
    expect(browse.refreshes, 1);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(browse.refreshes, 1);
    await teardownTree(tester);
  });

  // Audit 4A(b) #4: one model entry for a catalog sync (5A.0 gates it).
  test('refreshLibrary goes through SessionService.syncLibrary', () async {
    late _CountingService service;
    final container = ProviderContainer(
      overrides: [
        sessionServiceProvider.overrideWith(
          (ref) => service = _CountingService(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(browseControlsProvider).refreshLibrary();
    expect(service.syncs, 1);
  });

  test('BrowseController.refreshLibrary runs a catalog sync', () async {
    final sync = _CountingSync();
    final container = ProviderContainer(
      overrides: [trackSyncProvider.overrideWith(() => sync)],
    );
    addTearDown(container.dispose);
    await container.read(trackSyncProvider.future);
    await container.read(browseControlsProvider).refreshLibrary();
    expect(sync.syncs, 1);
  });
}

class _CountingService extends SessionService {
  _CountingService(super.ref);
  int syncs = 0;
  @override
  Future<void> syncLibrary() async => syncs++;
}
