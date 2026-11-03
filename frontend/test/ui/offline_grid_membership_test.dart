import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/widgets/album_card.dart';

import 'browse_harness.dart';
import 'fake_library_actions.dart';

/// Page-level wiring of the model's offline grid rule, and the album card's
/// scope through the REAL availability provider (only the network-bound
/// providers are replaced).
void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(uuid: 'k', title: 'k', artistId: 3, artist: 'Kim',
          albumId: 7, album: 'Kept', downloaded: true),
      SeedTrack(uuid: 'r', title: 'r', artistId: 3, artist: 'Kim',
          albumId: 8, album: 'Remote'),
      SeedTrack(uuid: 'x', title: 'x', artistId: 4, artist: 'Xan',
          albumId: 9, album: 'Far'),
    ]);
    harness = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  testWidgets('offline, an artist detail lists only albums with a download',
      (tester) async {
    await tester.pumpWidget(harness.wrap(
      const Scaffold(body: AlbumsPage(artistId: 3)),
      offline: true,
    ));
    await tester.pumpAndSettle();
    expect(find.text('Kept'), findsOneWidget);
    expect(find.text('Remote'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('offline, a chip-less ArtistsPage lists only downloaded artists',
      (tester) async {
    await tester.pumpWidget(harness.wrap(
      const Scaffold(body: ArtistsPage()),
      offline: true,
    ));
    await tester.pumpAndSettle();
    expect(find.text('Kim'), findsOneWidget);
    expect(find.text('Xan'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('album card menu reads its own scope through the real provider',
      (tester) async {
    final actions = FakeLibraryActions();
    // Offline: only a fully downloaded album may queue. Album 7 (artist 3) is
    // fully downloaded; a swapped scope (artist 7, album 3) would be unknown.
    await tester.pumpWidget(harness.wrap(
      const Scaffold(
        body: SizedBox(
          width: 200,
          height: 280,
          child: AlbumCard(
            album: AlbumUIFixture.kept,
            onTap: _noop,
          ),
        ),
      ),
      offline: true,
      overrides: [libraryActionsProvider.overrideWithValue(actions)],
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(AlbumCard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play Next'));
    await tester.pumpAndSettle();
    expect(actions.calls, ['playNext album(3,7)']);
    await teardownTree(tester);
  });
}

void _noop() {}

abstract final class AlbumUIFixture {
  static const kept = AlbumUI(id: 7, artistId: 3, name: 'Kept', artist: 'Kim');
}
