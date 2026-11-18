// Phase 9 §5 / SC-10 / SC-12 / 9-U05 / 9-U11: the Home suggestions model
// service. One snapshot = one SC-10 token captured with catalog attribution
// plus the 9B.1 pools loaded at that token's boundary and captured now.
// Picks come from the pure 9B.1 selection and are hydrated through SC-12's
// order-preserving `getTracksByUuids`; a track that vanished from the catalog
// is dropped. The current track is excluded from the same frozen snapshot
// without a new load, at once for tracks already hydrated.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/suggestions.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/home_suggestions_service.dart';
import 'package:frontend/repositories/suggestion_pools_repository.dart';

import '../helpers/fake_clock.dart';
import 'catalog_seed.dart';

/// Returns [pools] and records what it was asked for.
class _RecordingPools implements SuggestionPoolsRepository {
  _RecordingPools(this.pools);
  SuggestionPools pools;
  final calls = <(int, int)>[];

  @override
  Future<SuggestionPools> load(int boundaryLocalId, int capturedNowUtcMs) async {
    calls.add((boundaryLocalId, capturedNowUtcMs));
    return pools;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _all = BrowseFilters(policy: OfflineFilterPolicy.manual);
final _downloadedOnly = _all.userSetDownloaded(true);

SuggestionCandidate _c(String uuid, {bool downloaded = false, int? artist}) =>
    SuggestionCandidate(
      uuid: uuid,
      artistId: artist,
      title: 'Title $uuid',
      isDownloaded: downloaded,
    );

/// Rediscover entry ranked by [micros] (higher first).
RediscoverCandidate _r(String uuid, int micros, {bool downloaded = false}) =>
    RediscoverCandidate(
      track: _c(uuid, downloaded: downloaded),
      listeningMicros: micros,
      qualifiedPlays: 2,
      lastQualifiedAtUtcMs: 1000,
    );

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late _RecordingPools pools;
  late HomeSuggestionsService service;

  // 22 Rediscover candidates r00..r21, ranked r00 first (most listened); the
  // cap keeps r00..r19, so r20 is the first refill.
  final rediscoverIds = [for (var i = 0; i < 22; i++) 'r${'$i'.padLeft(2, '0')}'];
  List<RediscoverCandidate> rediscoverPool({Set<String> downloaded = const {}}) => [
    // Listed in reverse rank so "pool order" never equals rank order.
    for (final id in rediscoverIds.reversed)
      _r(id, 1000000 - rediscoverIds.indexOf(id), downloaded: downloaded.contains(id)),
  ];

  // Artist 7 (two unplayed tracks, "B" before "A" by uuid, ordered by title).
  final artistPool = ArtistPool(
    artistId: 7,
    recentMicros: 5000000,
    recentQualifiedPlays: 3,
    candidates: [
      SuggestionCandidate(uuid: 'u-b', artistId: 7, title: 'alpha', isDownloaded: false),
      SuggestionCandidate(uuid: 'u-a', artistId: 7, title: 'beta', isDownloaded: false),
    ],
  );

  SuggestionPools poolsWith({
    List<RediscoverCandidate>? rediscover,
    List<ArtistPool>? artists,
  }) => SuggestionPools(
    boundaryLocalId: 0,
    capturedNowUtcMs: 0,
    rediscover: rediscover ?? rediscoverPool(),
    artists: artists ?? [artistPool],
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(startUtcMs: 1800000000000);
    final seed = CatalogSeed(db);
    await seed.artist(7, 'Seven');
    for (final id in rediscoverIds) {
      await seed.track(id, title: 'Title $id');
    }
    await seed.track('u-a', artistId: 7, title: 'beta');
    await seed.track('u-b', artistId: 7, title: 'alpha');
    // Two history rows: the boundary is 2.
    await seed.click('track', 'r00', at: 1, kind: 'play');
    await seed.click('track', 'r01', at: 2, kind: 'play');
    pools = _RecordingPools(poolsWith());
    service = HomeSuggestionsService(
      snapshots: HistorySnapshotService(db, clock: clock),
      freshness: SnapshotFreshness(db),
      pools: pools,
      browse: BrowseRepository(db),
    );
  });

  tearDown(() => db.close());

  List<String> uuids(RailPicks picks) => [for (final t in picks.tracks) t.uuidId];

  group('capture', () {
    test('one token with catalog attribution; pools loaded at its boundary '
        'and captured now', () async {
      final snapshot = await service.capture();
      expect(snapshot.token.boundaryLocalId, 2);
      expect(snapshot.token.capturedNowUtcMs, 1800000000000);
      expect(snapshot.token.catalogAttributionVersion, isNotNull);
      expect(pools.calls, [(2, 1800000000000)]);
      expect(snapshot.pools, same(pools.pools));
    });
  });

  group('resolve', () {
    test('hydrated tracks in selection order, capped', () async {
      final snapshot = await service.capture();
      final view = await service.resolve(snapshot, filter: _all);
      expect(uuids(view.rediscover), rediscoverIds.take(20).toList());
      expect(uuids(view.moreFromArtists), ['u-b', 'u-a']);
      expect(view.rediscover.tracks.first.title, 'Title r00');
      expect(view.complete, isTrue);
      expect(view.rediscover.emptiedByFilter, isFalse);
    });

    test('a track that vanished from the catalog is dropped, not replaced',
        () async {
      final snapshot = await service.capture();
      await (db.delete(db.trackmetadata)..where((t) => t.uuidId.equals('r03')))
          .go();
      await (db.delete(db.tracks)..where((t) => t.uuidId.equals('r03'))).go();
      final view = await service.resolve(snapshot, filter: _all);
      expect(uuids(view.rediscover), [
        for (final id in rediscoverIds.take(20))
          if (id != 'r03') id,
      ]);
      expect(view.complete, isTrue);
    });

    test('the current track is excluded and the next candidate refills',
        () async {
      final snapshot = await service.capture();
      final view = await service.resolve(
        snapshot,
        currentUuid: 'r05',
        filter: _all,
      );
      expect(uuids(view.rediscover), [
        for (final id in rediscoverIds.take(21))
          if (id != 'r05') id,
      ]);
      final more = await service.resolve(
        snapshot,
        currentUuid: 'u-b',
        filter: _all,
      );
      expect(uuids(more.moreFromArtists), ['u-a']);
      expect(pools.calls, hasLength(1), reason: 'same frozen snapshot');
    });

    test('the Downloaded filter applies before the cap', () async {
      pools.pools = poolsWith(
        rediscover: rediscoverPool(downloaded: {'r21', 'r02'}),
      );
      final snapshot = await service.capture();
      final view = await service.resolve(snapshot, filter: _downloadedOnly);
      expect(uuids(view.rediscover), ['r02', 'r21']);
      expect(view.rediscover.emptiedByFilter, isFalse);
    });

    test('empty only because of the Downloaded filter is told apart from '
        'empty', () async {
      pools.pools = poolsWith(artists: const []);
      final snapshot = await service.capture();
      final filtered = await service.resolve(snapshot, filter: _downloadedOnly);
      expect(filtered.rediscover.tracks, isEmpty);
      expect(filtered.rediscover.emptiedByFilter, isTrue);
      // No artists at all: empty whatever the filter.
      expect(filtered.moreFromArtists.tracks, isEmpty);
      expect(filtered.moreFromArtists.emptiedByFilter, isFalse);
      final unfiltered = await service.resolve(snapshot, filter: _all);
      expect(unfiltered.moreFromArtists.emptiedByFilter, isFalse);
    });

    test('a filter-empty rail whose only unfiltered pick is the current track '
        'is plain empty', () async {
      pools.pools = poolsWith(
        rediscover: [_r('r00', 10)],
        artists: const [],
      );
      final snapshot = await service.capture();
      final view = await service.resolve(
        snapshot,
        currentUuid: 'r00',
        filter: _downloadedOnly,
      );
      expect(view.rediscover.tracks, isEmpty);
      expect(view.rediscover.emptiedByFilter, isFalse);
    });
  });

  group('pickNow (same frozen snapshot, no I/O)', () {
    test('a new current track is excluded synchronously from what was '
        'hydrated; resolve then adds the refill', () async {
      final snapshot = await service.capture();
      await service.resolve(snapshot, filter: _all);
      final now = service.pickNow(snapshot, currentUuid: 'r00', filter: _all);
      expect(uuids(now.rediscover), rediscoverIds.sublist(1, 20));
      expect(now.complete, isFalse, reason: 'r20 is not hydrated yet');
      final full = await service.resolve(
        snapshot,
        currentUuid: 'r00',
        filter: _all,
      );
      expect(uuids(full.rediscover), rediscoverIds.sublist(1, 21));
      // Back to no current track: everything is hydrated now.
      final back = service.pickNow(snapshot, filter: _all);
      expect(uuids(back.rediscover), rediscoverIds.take(20).toList());
      expect(back.complete, isTrue);
      expect(pools.calls, hasLength(1));
    });

    test('nothing hydrated yet: empty and incomplete', () async {
      final snapshot = await service.capture();
      final now = service.pickNow(snapshot, filter: _all);
      expect(now.rediscover.tracks, isEmpty);
      expect(now.complete, isFalse);
    });

    test('a vanished track stays out without making the view incomplete',
        () async {
      final snapshot = await service.capture();
      await (db.delete(db.trackmetadata)..where((t) => t.uuidId.equals('r03')))
          .go();
      await (db.delete(db.tracks)..where((t) => t.uuidId.equals('r03'))).go();
      await service.resolve(snapshot, filter: _all);
      final now = service.pickNow(snapshot, filter: _all);
      expect(uuids(now.rediscover), isNot(contains('r03')));
      expect(now.complete, isTrue);
    });
  });

  group('watch', () {
    Future<List<SnapshotStaleness>> collect(
      HomeSuggestionsService s,
      SuggestionSnapshot snapshot,
      Future<void> Function() write,
    ) async {
      final seen = <SnapshotStaleness>[];
      final sub = s.watch(snapshot).listen(seen.add);
      await pumpEventQueue();
      await write();
      await pumpEventQueue();
      await sub.cancel();
      return seen;
    }

    test('a finished listen is new activity; a click is not', () async {
      final snapshot = await service.capture();
      final clicked = await collect(
        service,
        snapshot,
        () => CatalogSeed(db).click('track', 'r02', at: 3, eventUuid: 'ev-click'),
      );
      expect(clicked, [SnapshotStaleness.fresh]);
      final played = await collect(
        service,
        snapshot,
        () => CatalogSeed(db)
            .click('track', 'r02', at: 4, kind: 'play', eventUuid: 'ev-play'),
      );
      expect(played.last, SnapshotStaleness.newActivity);
    });

    test('a catalog rename makes the snapshot history-changed', () async {
      final snapshot = await service.capture();
      final seen = await collect(
        service,
        snapshot,
        () => (db.update(db.trackmetadata)
              ..where((t) => t.uuidId.equals('r04')))
            .write(const TrackmetadataCompanion(title: Value('Renamed'))),
      );
      expect(seen.last, SnapshotStaleness.historyChanged);
    });
  });
}
