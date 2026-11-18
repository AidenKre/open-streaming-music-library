// Phase 9A.1c (spec §3 paras 1 and 4; SC-10; review 9-U04): the ranking
// pagers behind "See all". Pages of 50 keyset-paged on (rank, id) through
// HistorySnapshotService.readPage, bound to one token; SnapshotExpired when
// history content or catalog attribution changed, decided inside the page's
// read transaction before the keyset query runs. Every expected order below
// is written by hand from the seeded rows, never from production SQL.
import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_rank_pagers.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

import '../helpers/fake_clock.dart';
import '../helpers/server_binding.dart';
import 'catalog_seed.dart';
import 'history_snapshot_fixtures.dart';

// 2026-01-03T12:00Z.
const _now = 1767441600000;
const _hour = 3600000;
const _day = 24 * _hour;

/// Records the SELECTs reaching SQLite while [on].
class _Recorder extends QueryInterceptor {
  final selects = <String>[];
  bool on = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (on) selects.add(statement);
    return super.runSelect(executor, statement, args);
  }
}

void main() {
  late AppDatabase db;
  late _Recorder recorder;
  late HistorySnapshotService snapshots;
  late ListeningStatsRepository stats;
  late TopTracksPager tracks;
  late HistoryRepository history;
  late String binding;
  late CatalogSeed seed;
  var seq = 0;

  setUp(() async {
    recorder = _Recorder();
    db = AppDatabase(NativeDatabase.memory().interceptWith(recorder));
    binding = await seedTestBinding(db);
    history = HistoryRepository(db);
    snapshots = HistorySnapshotService(db, clock: FakeClock(startUtcMs: _now));
    stats = ListeningStatsRepository(db, BrowseRepository(db));
    tracks = TopTracksPager(snapshots, stats);
    seed = CatalogSeed(db);
    seq = 0;
  });

  tearDown(() => db.close());

  Future<void> listen(String ref, double seconds,
          {int at = _now - _hour, double length = 200}) =>
      db.into(db.historyEvents).insert(
        HistoryEventsCompanion.insert(
          eventUuid: 'p-${(seq++).toString().padLeft(5, '0')}',
          kind: 'play',
          entityType: 'track',
          entityRef: ref,
          occurredAt: at,
          secondsPlayed: Value(seconds),
          trackLength: Value(length),
          pendingUpload: false,
        ),
      );

  Future<HistorySnapshotToken> capture(StatsRange range) =>
      snapshots.capture(range, attribution: true);

  SnapshotPage<RankedPageEntry<E, K>, RankCursor<K>> pageOf<E, K>(
    SnapshotPageResult<RankedPageEntry<E, K>, RankCursor<K>> r,
  ) => switch (r) {
    SnapshotPage<RankedPageEntry<E, K>, RankCursor<K>>() => r,
    SnapshotExpired<RankedPageEntry<E, K>, RankCursor<K>>() =>
      fail('expected a page, got expired'),
  };

  /// Every page of [pager] from the start, as (pages of ids).
  Future<List<List<Object>>> traverse<E, K>(
    SnapshotPager<RankedPageEntry<E, K>, RankCursor<K>> pager,
    HistorySnapshotToken token,
    Object Function(E) idOf,
  ) async {
    final pages = <List<Object>>[];
    RankCursor<K>? after;
    do {
      final p = pageOf(await pager.page(token, after, rankingPageSize));
      pages.add([for (final e in p.items) idOf(e.entry.entity)]);
      // Every fixture here ranks fewer than 200 entities: 4 pages at most.
      // A keyset that stops advancing fails here, never spins.
      if (pages.length > 4) fail('paging did not end; stuck after ${p.nextCursor}');
      after = p.nextCursor;
    } while (after != null);
    return pages;
  }

  test('a page holds 50 entities', () {
    expect(rankingPageSize, 50);
  });

  group('tracks', () {
    // hi (1000 s), tq-a (100 s from two qualified 50 s listens), 120 tied
    // tracks of one qualified 100 s listen (uuid ASC decides), lo (50 s, one
    // qualified listen of a 60 s track). t-gone (no catalog row, 5000 s) is
    // unavailable history: never ranked. Ties are inserted in reverse uuid
    // order so insertion order cannot pass for rank order.
    final ties = [for (var i = 0; i < 120; i++) 'tie-${i.toString().padLeft(3, '0')}'];
    final expected = ['hi', 'tq-a', ...ties, 'lo'];

    setUp(() async {
      await seed.artist(1, 'One');
      await seed.album(1, artistId: 1);
      for (final uuid in ['hi', 'tq-a', ...ties.reversed, 'lo']) {
        await seed.track(uuid, artistId: 1, albumId: 1);
      }
      await listen('hi', 1000);
      await listen('tq-a', 50);
      await listen('tq-a', 50);
      for (final t in ties.reversed) {
        await listen(t, 100);
      }
      await listen('lo', 50, length: 60);
      await listen('t-gone', 5000);
    });

    test('more than 100 tied tracks traverse in pages of 50 with no gap and '
        'no repeat (the tie run spans three pages)', () async {
      final token = await capture(StatsRange.last7Days);
      final pages = await traverse(tracks, token, (TrackUI t) => t.uuidId);
      expect(pages.map((p) => p.length), [50, 50, 23]);
      expect(pages.expand((p) => p).toList(), expected);
    });

    test('entries carry exact seconds and qualified plays; the cursor is the '
        'last entry\'s integer microseconds, qualified plays and uuid', () async {
      final token = await capture(StatsRange.last7Days);
      final p = pageOf(await tracks.page(token, null, rankingPageSize));
      final first = p.items.first;
      expect(first.entry.entity.uuidId, 'hi');
      expect(first.entry.listeningSeconds, 1000);
      expect(first.entry.qualifiedPlays, 1);
      expect(p.items[1].entry.qualifiedPlays, 2);
      expect(first.cursor, const RankCursor<String>(
        listeningMicros: 1000000000,
        qualifiedPlays: 1,
        key: 'hi',
      ));
      expect(p.nextCursor, p.items.last.cursor);
      expect(p.nextCursor, const RankCursor<String>(
        listeningMicros: 100000000,
        qualifiedPlays: 1,
        key: 'tie-047',
      ));
    });

    test('page one starts with exactly load\'s top 10 for the same token',
        () async {
      final token = await capture(StatsRange.last7Days);
      final loaded = await stats.load(
        token.filterKey as StatsRange,
        token.boundaryLocalId,
        token.capturedNowUtcMs,
      );
      final p = pageOf(await tracks.page(token, null, rankingPageSize));
      List<(String, double, int)> rows(Iterable<RankedEntry<TrackUI>> l) => [
        for (final e in l)
          (e.entity.uuidId, e.listeningSeconds, e.qualifiedPlays),
      ];
      expect(loaded.topTracks, hasLength(10));
      expect(rows(p.items.take(10).map((e) => e.entry)), rows(loaded.topTracks));
    });

    test('a listen inserted after capture is outside the boundary: later '
        'pages ignore it and nothing expires', () async {
      final token = await capture(StatsRange.last7Days);
      final first = pageOf(await tracks.page(token, null, rankingPageSize));
      await listen('lo', 100000);
      final pages = [
        [for (final e in first.items) e.entry.entity.uuidId],
        ...(await traverseFrom(tracks, token, first.nextCursor)),
      ];
      expect(pages.expand((p) => p).toList(), expected);
    });

    test('a conflict resolution keeping the same local_id expires the next '
        'page before its ranking query runs', () async {
      await history.insertLocal(
        binding,
        historyEvent('e-keep', ref: 'hi', at: _now - 2 * _hour),
      );
      final token = await capture(StatsRange.last7Days);
      final first = pageOf(await tracks.page(token, null, rankingPageSize));
      final localId = await localIdOf(db, 'e-keep');
      await keepServerVersion(history, binding, 'e-keep', at: _now - 3 * _hour);
      expect(await localIdOf(db, 'e-keep'), localId);
      recorder
        ..selects.clear()
        ..on = true;
      final next = await tracks.page(token, first.nextCursor, rankingPageSize);
      recorder.on = false;
      expect(next, isA<SnapshotExpired<RankedPageEntry<TrackUI, String>,
          RankCursor<String>>>());
      expect(recorder.selects.where((s) => s.contains('history_events')),
          isEmpty, reason: 'expiry is decided before the keyset query');
    });

    test('a catalog attribution change expires the next page', () async {
      final token = await capture(StatsRange.last7Days);
      final first = pageOf(await tracks.page(token, null, rankingPageSize));
      await (db.update(db.trackmetadata)
            ..where((t) => t.uuidId.equals('tie-100')))
          .write(const TrackmetadataCompanion(title: Value('Renamed')));
      final next = await tracks.page(token, first.nextCursor, rankingPageSize);
      expect(next, isA<SnapshotExpired<RankedPageEntry<TrackUI, String>,
          RankCursor<String>>>());
    });

    test('an attribution change committed between the request and the read '
        'transaction expires the page', () async {
      final token = await capture(StatsRange.last7Days);
      final first = pageOf(await tracks.page(token, null, rankingPageSize));
      final release = Completer<void>();
      final renamed = Completer<void>();
      // A writer holds the database with the rename uncommitted while the
      // page is requested; the page's read transaction can only start after
      // the writer commits.
      final writer = db.transaction(() async {
        await (db.update(db.trackmetadata)
              ..where((t) => t.uuidId.equals('tie-100')))
            .write(const TrackmetadataCompanion(title: Value('Renamed')));
        renamed.complete();
        await release.future;
      });
      await renamed.future;
      final requested = tracks.page(token, first.nextCursor, rankingPageSize);
      release.complete();
      await writer;
      expect(await requested, isA<SnapshotExpired<RankedPageEntry<TrackUI,
          String>, RankCursor<String>>>());
    });

    test('a change of a column outside attribution (genre) expires nothing',
        () async {
      final token = await capture(StatsRange.last7Days);
      final first = pageOf(await tracks.page(token, null, rankingPageSize));
      await (db.update(db.trackmetadata)
            ..where((t) => t.uuidId.equals('tie-100')))
          .write(const TrackmetadataCompanion(genre: Value('Jazz')));
      expect(await tracks.page(token, first.nextCursor, rankingPageSize),
          isA<SnapshotPage<RankedPageEntry<TrackUI, String>,
              RankCursor<String>>>());
    });

    test('a range change uses a new token: each token pages its own range',
        () async {
      // 'old' listened 20 days ago: in 30 days, not in 7 days.
      await seed.track('old', artistId: 1, albumId: 1);
      await listen('old', 2000, at: _now - 20 * _day);
      final week = await capture(StatsRange.last7Days);
      final month = await capture(StatsRange.last30Days);
      expect(week, isNot(month));
      expect((await traverse(tracks, week, (TrackUI t) => t.uuidId))
          .expand((p) => p), expected);
      expect((await traverse(tracks, month, (TrackUI t) => t.uuidId))
          .expand((p) => p), ['old', ...expected]);
    });

    test('a token without the attribution counter, or captured for another '
        'surface, is refused', () async {
      final bare = await snapshots.capture(StatsRange.last7Days);
      expect(() => tracks.page(bare, null, rankingPageSize),
          throwsArgumentError);
      final other = await snapshots.capture('play', attribution: true);
      expect(() => tracks.page(other, null, rankingPageSize),
          throwsArgumentError);
    });

    test('a tombstoned track leaves the ranking of a fresh token (it joins '
        'the unavailable subtotal) and the old token expires', () async {
      final old = await capture(StatsRange.last7Days);
      await db.customUpdate(
        "DELETE FROM trackmetadata WHERE uuid_id = 'tie-000'",
        updates: {db.trackmetadata},
        updateKind: UpdateKind.delete,
      );
      expect(await tracks.page(old, null, rankingPageSize),
          isA<SnapshotExpired<RankedPageEntry<TrackUI, String>,
              RankCursor<String>>>());
      final fresh = await capture(StatsRange.last7Days);
      expect((await traverse(tracks, fresh, (TrackUI t) => t.uuidId))
          .expand((p) => p), [for (final t in expected) if (t != 'tie-000') t]);
    });

    test('the number of statements per page does not grow with the page '
        'number', () async {
      final token = await capture(StatsRange.last7Days);
      final counts = <int>[];
      RankCursor<String>? after;
      do {
        recorder
          ..selects.clear()
          ..on = true;
        final p = pageOf(await tracks.page(token, after, rankingPageSize));
        recorder.on = false;
        counts.add(recorder.selects.length);
        if (counts.length > 4) fail('paging did not end; stuck after ${p.nextCursor}');
        after = p.nextCursor;
      } while (after != null);
      expect(counts.toSet(), hasLength(1), reason: '$counts');
    });
  });
  group('artists and albums', () {
    late TopArtistsPager artists;
    late TopAlbumsPager albums;
    // 120 tied artists, each with one album and one track of one qualified
    // 100 s listen, so id ASC decides; ids are spaced so numeric and text
    // order differ (3, 10, 17, …, 836). Artist 2000 / album 3000 leads with
    // 1000 s. Albums are numbered 5 + 11·i, inserted in reverse.
    final artistIds = [for (var i = 0; i < 120; i++) 3 + 7 * i];
    final albumIds = [for (var i = 0; i < 120; i++) 5 + 11 * i];

    setUp(() async {
      artists = TopArtistsPager(snapshots, stats);
      albums = TopAlbumsPager(snapshots, stats);
      await seed.artist(2000, 'Lead');
      await seed.album(3000, artistId: 2000);
      await seed.track('lead', artistId: 2000, albumId: 3000);
      await listen('lead', 1000);
      for (var i = 119; i >= 0; i--) {
        await seed.artist(artistIds[i], 'A$i');
        await seed.album(albumIds[i], artistId: artistIds[i]);
        await seed.track('a-$i', artistId: artistIds[i], albumId: albumIds[i]);
        await listen('a-$i', 100);
      }
    });

    test('more than 100 tied artists traverse by id with no gap and no '
        'repeat', () async {
      final token = await capture(StatsRange.last7Days);
      final pages = await traverse(artists, token, (ArtistUI a) => a.id);
      expect(pages.map((p) => p.length), [50, 50, 21]);
      expect(pages.expand((p) => p).toList(), [2000, ...artistIds]);
    });

    test('more than 100 tied albums traverse by id with no gap and no '
        'repeat', () async {
      final token = await capture(StatsRange.last7Days);
      final pages = await traverse(albums, token, (AlbumUI a) => a.id);
      expect(pages.map((p) => p.length), [50, 50, 21]);
      expect(pages.expand((p) => p).toList(), [3000, ...albumIds]);
    });

    test('page one starts with exactly load\'s top 10 artists and albums',
        () async {
      final token = await capture(StatsRange.last7Days);
      final loaded = await stats.load(
        StatsRange.last7Days,
        token.boundaryLocalId,
        token.capturedNowUtcMs,
      );
      List<(int, double, int)> rows<T>(
        Iterable<RankedEntry<T>> l,
        int Function(T) id,
      ) => [for (final e in l) (id(e.entity), e.listeningSeconds, e.qualifiedPlays)];
      final ar = pageOf(await artists.page(token, null, rankingPageSize));
      final al = pageOf(await albums.page(token, null, rankingPageSize));
      expect(rows(ar.items.take(10).map((e) => e.entry), (ArtistUI a) => a.id),
          rows(loaded.topArtists, (ArtistUI a) => a.id));
      expect(rows(al.items.take(10).map((e) => e.entry), (AlbumUI a) => a.id),
          rows(loaded.topAlbums, (AlbumUI a) => a.id));
      expect(ar.nextCursor,
          RankCursor<int>(listeningMicros: 100000000, qualifiedPlays: 1,
              key: artistIds[48]));
    });

    test('a track moved to another artist expires both pagers', () async {
      final token = await capture(StatsRange.last7Days);
      final ar = pageOf(await artists.page(token, null, rankingPageSize));
      final al = pageOf(await albums.page(token, null, rankingPageSize));
      await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a-90')))
          .write(TrackmetadataCompanion(artistId: Value(artistIds[0])));
      expect(await artists.page(token, ar.nextCursor, rankingPageSize),
          isA<SnapshotExpired<RankedPageEntry<ArtistUI, int>, RankCursor<int>>>());
      expect(await albums.page(token, al.nextCursor, rankingPageSize),
          isA<SnapshotExpired<RankedPageEntry<AlbumUI, int>, RankCursor<int>>>());
    });

    test('a conflict resolution expires both pagers', () async {
      await history.insertLocal(
        binding,
        historyEvent('e-keep', ref: 'lead', at: _now - 2 * _hour),
      );
      final token = await capture(StatsRange.last7Days);
      await keepServerVersion(history, binding, 'e-keep', at: _now - 3 * _hour);
      expect(await artists.page(token, null, rankingPageSize),
          isA<SnapshotExpired<RankedPageEntry<ArtistUI, int>, RankCursor<int>>>());
      expect(await albums.page(token, null, rankingPageSize),
          isA<SnapshotExpired<RankedPageEntry<AlbumUI, int>, RankCursor<int>>>());
    });

    test('both refuse a token without the attribution counter', () async {
      final bare = await snapshots.capture(StatsRange.last7Days);
      expect(() => artists.page(bare, null, rankingPageSize),
          throwsArgumentError);
      expect(() => albums.page(bare, null, rankingPageSize),
          throwsArgumentError);
    });
  });
  group('progress guard', () {
    // A ranking fetch that ignores the cursor (a broken keyset) would hand
    // the caller the same page and cursor forever; the pager refuses any page
    // whose entries are not strictly after the requested cursor and in
    // strict rank order, with a typed error, instead of letting a caller spin.
    late List<RankedPageEntry<TrackUI, String>> ranking;

    setUp(() async {
      await seed.artist(1, 'One');
      await seed.album(1, artistId: 1);
      for (final (uuid, secs) in [('x', 300.0), ('y', 200.0), ('z', 100.0)]) {
        await seed.track(uuid, artistId: 1, albumId: 1);
        await listen(uuid, secs);
      }
      final token = await capture(StatsRange.last7Days);
      ranking = pageOf(await tracks.page(token, null, rankingPageSize)).items;
      expect([for (final e in ranking) e.entry.entity.uuidId], ['x', 'y', 'z']);
    });

    test('a fetch that ignores the cursor fails with RankingOrderError on '
        'the next page instead of repeating it', () async {
      final stuck = TopTracksPager(snapshots, _CannedStats(db, ranking));
      final token = await capture(StatsRange.last7Days);
      final p = pageOf(await stuck.page(token, null, 2));
      expect(p.nextCursor, ranking[1].cursor);
      await expectLater(stuck.page(token, p.nextCursor, 2),
          throwsA(isA<RankingOrderError>()));
    });

    test('entries out of rank order within a page fail with '
        'RankingOrderError', () async {
      final shuffled =
          TopTracksPager(snapshots, _CannedStats(db, ranking.reversed.toList()));
      final token = await capture(StatsRange.last7Days);
      await expectLater(shuffled.page(token, null, 2),
          throwsA(isA<RankingOrderError>()));
    });

    test('tied uuids order as SQLite does (UTF-8 bytes), so the guard does '
        'not refuse a correct page: U+E000 before U+1F600', () async {
      const bmp = '\u{E000}';
      const astral = '\u{1F600}';
      for (final uuid in [astral, bmp]) {
        await seed.track(uuid, artistId: 1, albumId: 1);
        await listen(uuid, 50);
      }
      final token = await capture(StatsRange.last7Days);
      final first = pageOf(await tracks.page(token, ranking[2].cursor, 1));
      expect([for (final e in first.items) e.entry.entity.uuidId], [bmp]);
      final second = pageOf(await tracks.page(token, first.nextCursor, 1));
      expect([for (final e in second.items) e.entry.entity.uuidId], [astral]);
    });

    test('a well-ordered page after the cursor passes the guard', () async {
      final token = await capture(StatsRange.last7Days);
      final p = pageOf(await tracks.page(token, ranking[1].cursor, 2));
      expect([for (final e in p.items) e.entry.entity.uuidId], ['z']);
      expect(p.nextCursor, isNull);
    });
  });
}

/// Statistics whose track ranking returns [rows] whatever the cursor.
class _CannedStats extends ListeningStatsRepository {
  _CannedStats(AppDatabase db, this.rows) : super(db, BrowseRepository(db));
  final List<RankedPageEntry<TrackUI, String>> rows;

  @override
  Future<List<RankedPageEntry<TrackUI, String>>> trackRanking(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs, {
    RankCursor<String>? after,
    required int limit,
  }) async => rows.take(limit).toList();
}

/// The remaining pages of [pager] after [after] (none when null).
Future<List<List<String>>> traverseFrom(
  TopTracksPager pager,
  HistorySnapshotToken token,
  RankCursor<String>? after,
) async {
  final pages = <List<String>>[];
  while (after != null) {
    final r = await pager.page(token, after, rankingPageSize);
    if (r is! SnapshotPage<RankedPageEntry<TrackUI, String>,
        RankCursor<String>>) {
      fail('expected a page, got expired');
    }
    pages.add([for (final e in r.items) e.entry.entity.uuidId]);
    if (pages.length > 4) fail('paging did not end; stuck after ${r.nextCursor}');
    after = r.nextCursor;
  }
  return pages;
}

Future<int> localIdOf(AppDatabase db, String uuid) async =>
    (await (db.select(db.historyEvents)..where((t) => t.eventUuid.equals(uuid)))
            .getSingle())
        .localId;
