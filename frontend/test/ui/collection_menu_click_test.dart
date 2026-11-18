// Phase 6A.2 (spec §3 "Collection Play next / Add to queue: one collection
// click, no per-track clicks; include existing menus in Search/browse",
// 6-U05, 6-P02 unit half): every existing collection menu (Search's artist
// and album cards, the browse grids' cards, an artist's album grid; all
// LibraryCard menus) reaches the real LibraryActions and PlaybackRequests,
// and an accepted Play Next / Add to Queue records exactly one album or
// artist click and never a member track click, with or without a queue
// (the no-session fallback starts one).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';

import '../helpers/no_server_api.dart';
import '../helpers/server_binding.dart';
import 'browse_harness.dart';
import 'collection_playback_harness.dart';
import '../helpers/library_seed.dart' show SeedTrack, seedLibrary;

void main() {
  late AppDatabase db;
  late Directory dir;
  late LocalCoverArtStore covers;
  late CollectionPlayer player;

  const seed = [
    SeedTrack(uuid: 'k1', title: 'Kite One', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'Air', trackNumber: 1),
    SeedTrack(uuid: 'k2', title: 'Kite Two', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'Air', trackNumber: 2),
  ];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, seed);
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    dir = await Directory.systemTemp.createTemp('collection-menu-click');
    covers = await LocalCoverArtStore.create(
      directoryProvider: () async => dir,
      apiClient: noServerApi(),
    );
  });

  tearDown(() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget page, {int? sessionId}) async {
    player = CollectionPlayer(sessionId);
    await tester.pumpWidget(collectionPlaybackScope(
        db: db, covers: covers, dir: dir, player: player, child: page));
    await tester.pumpAndSettle();
  }

  Future<List<(String, String)>> clicks(WidgetTester tester) =>
      recordedClicks(tester, db);

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, Finder card, String entry) async {
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.longPress(card);
    await tester.pumpAndSettle();
    await tester.tap(find.text(entry));
    await tester.runAsync(() => pumpEventQueue(times: 50));
    await tester.pumpAndSettle();
  }

  final surfaces = <(String, Widget, String?, Finder Function(), (String, String))>[
    ('Search artist card', const SearchPage(), 'Ann',
        () => find.byType(ArtistCard).first, ('artist', 'srv-1:1')),
    ('Search album card', const SearchPage(), 'Air',
        () => find.byType(AlbumCard).first, ('album', 'srv-1:2')),
    ('Artists browse card', const ArtistsBrowsePage(), null,
        () => find.byType(ArtistCard).first, ('artist', 'srv-1:1')),
    ('Albums browse card', const AlbumsBrowsePage(), null,
        () => find.byType(AlbumCard).first, ('album', 'srv-1:2')),
    ('artist detail album card', const AlbumsPage(artistId: 1), null,
        () => find.byType(AlbumCard).first, ('album', 'srv-1:2')),
  ];

  for (final (label, page, query, card, click) in surfaces) {
    for (final entry in ['Play Next', 'Add to Queue']) {
      for (final sessionId in <int?>[7, null]) {
        final queue = sessionId == null ? 'no queue (fallback)' : 'a queue';
        testWidgets('$label, $entry with $queue: one ${click.$1} click, '
            'no member click', (tester) async {
          await pump(tester, page, sessionId: sessionId);
          if (query != null) await search(tester, query);
          await choose(tester, card(), entry);
          if (sessionId != null) {
            expect(player.enqueued, [
              ['k1', 'k2'],
            ]);
          } else {
            expect(player.activated, hasLength(1),
                reason: 'the no-session fallback started a queue');
          }
          final recorded = await clicks(tester);
          expect(recorded, [click]);
          expect(recorded.where((c) => c.$1 == 'track'), isEmpty);
          await teardownTree(tester);
        });
      }
    }
  }
}
