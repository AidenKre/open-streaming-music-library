// Phase 9 review r1, 9-R1-42 (DR-332-STATS-B-03): offline, the statistics
// cards resolve album and artist covers from downloaded tracks only, like
// Recently Played (whose Downloaded filter auto-applies offline, Phase 3
// D12), so a cover never needs the network. Online the shared rule picks the
// lowest-numbered track with art, downloaded or not.
//
// Real in-memory SQLite; the expected covers follow from the seed alone.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

import 'catalog_seed.dart';

const _now = 1800000000000;
const _remoteArt = 11; // track 1, streaming only
const _localArt = 22; // track 2, downloaded

void main() {
  late AppDatabase db;
  var offline = false;

  ListeningStatsRepository repo() => ListeningStatsRepository(
    db,
    BrowseRepository(db),
    downloadedArtOnly: () => offline,
  );

  setUp(() async {
    offline = false;
    db = AppDatabase(NativeDatabase.memory());
    final seed = CatalogSeed(db);
    await seed.artist(1, 'One');
    await seed.album(1, artistId: 1);
    await seed.track('t-1', artistId: 1, albumId: 1, trackNumber: 1,
        art: _remoteArt);
    await seed.track('t-2', artistId: 1, albumId: 1, trackNumber: 2,
        art: _localArt, downloaded: true);
    var i = 0;
    for (final ref in ['t-1', 't-2']) {
      await db.into(db.historyEvents).insert(
        HistoryEventsCompanion.insert(
          eventUuid: 'p-${i++}',
          kind: 'play',
          entityType: 'track',
          entityRef: ref,
          occurredAt: _now - 3600000,
          secondsPlayed: const Value(120.0),
          trackLength: const Value(180.0),
          pendingUpload: false,
        ),
      );
    }
  });

  tearDown(() => db.close());

  for (final (label, isOffline, art) in [
    ('online: the lowest-numbered track with art', false, _remoteArt),
    ('offline: a downloaded track with art', true, _localArt),
  ]) {
    test('top lists, $label', () async {
      offline = isOffline;
      final s = await repo().load(StatsRange.allTime, 1 << 40, _now);
      expect(s.topAlbums.single.entity.coverArtId, art);
      expect(s.topArtists.single.entity.coverArtId, art);
    });

    test('See all pages, $label', () async {
      offline = isOffline;
      final r = repo();
      final albums =
          await r.albumRanking(StatsRange.allTime, 1 << 40, _now, limit: 10);
      final artists =
          await r.artistRanking(StatsRange.allTime, 1 << 40, _now, limit: 10);
      expect(albums.single.entry.entity.coverArtId, art);
      expect(artists.single.entry.entity.coverArtId, art);
    });

    test('current entities, $label', () async {
      offline = isOffline;
      final current = await repo()
          .watchCurrent(trackUuids: const [], artistIds: const [1],
              albumIds: const [1])
          .first;
      expect(current.albums[1]!.coverArtId, art);
      expect(current.artists[1]!.coverArtId, art);
    });
  }
}
