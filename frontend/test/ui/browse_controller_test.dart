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
import 'package:frontend/ui/artist_page.dart';
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
      SeedTrack(uuid: 'u1', title: 'Song', artistId: 1, artist: 'Ann',
          albumId: 2, album: 'Air'),
    ]);
    harness = await BrowseHarness.create(db);
    browse = _FakeBrowse();
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(harness.wrap(
      page,
      overrides: [browseControlsProvider.overrideWithValue(browse)],
    ));
    await tester.pumpAndSettle();
  }

  for (final (name, page) in [
    ('Artists root', const ArtistsPage(isRoot: true) as Widget),
    ('artist detail (albums)', const Scaffold(body: AlbumsPage(artistId: 1))),
    ('Tracks root', const TracksPage(isRoot: true)),
    ('album detail', const Scaffold(body: TracksPage(artistId: 1, albumId: 2))),
  ]) {
    testWidgets('$name refreshes the library once when created',
        (tester) async {
      await pump(tester, page);
      expect(browse.refreshes, 1);
      // Rebuilds do not add network work.
      await tester.pump(const Duration(seconds: 1));
      expect(browse.refreshes, 1);
      await teardownTree(tester);
    });
  }

  testWidgets('re-selecting the Tracks tab refreshes again', (tester) async {
    await pump(tester, const AppShell());
    final atStart = browse.refreshes;
    await tester.tap(find.text('Tracks').last);
    await tester.pumpAndSettle();
    expect(browse.refreshes, atStart + 1);
    await teardownTree(tester);
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
