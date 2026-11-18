// Phase 9A.1c (spec §3 "Performance fixture"; review 9-U07 and §3; plan D5,
// decision O14): the statistics and ranking pagers on the seeded 100,000-event
// / 10,000-track fixture. Asserted: the fixture is the recorded one (counts,
// checksum), every statistic equals the fixture's own oracle, the pagers
// traverse a whole ranking with no gap or repeat, every history read searches
// the index (no full scan) and the number of statements does not grow with
// history. Timings and EXPLAIN plans are printed as evidence only (O14: this
// machine's timings vary tenfold under load); no test asserts a wall-clock
// time. The fixture is generated once per file from its seed (no committed
// binary).
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_rank_pagers.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

import '../helpers/fake_clock.dart';
import 'stats_perf_fixture.dart';

/// Records the SELECTs (with arguments) reaching SQLite while [on].
class _Recorder extends QueryInterceptor {
  final selects = <({String sql, List<Object?> args})>[];

  /// Elapsed ms per recorded SELECT, in order (evidence only).
  final elapsedMs = <int>[];
  bool on = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (!on) return super.runSelect(executor, statement, args);
    selects.add((sql: statement, args: args));
    final sw = Stopwatch()..start();
    final rows = await super.runSelect(executor, statement, args);
    elapsedMs.add(sw.elapsedMilliseconds);
    return rows;
  }
}

// Recorded from the first generation (2026-11-12); a different value means
// the generator or its seed changed, and the evidence no longer applies.
const _recordedChecksum =
    'c90c3e1021a6a1a84a0947718c3d5439791286dd81781e619848d9a9762d73c9';
const _recordedKinds = {
  'play/track': 95959,
  'clicked/track': 1982,
  'scrobble_v2/track': 1030,
  'play/album': 1029,
};

/// The oracle's selected values per range: (listening µs, qualified plays,
/// unique tracks, active days, future rows, overlong rows, ranked tracks,
/// top track).
const _recordedOracle = <String, (int, int, int, int, int, int, int, String)>{
  '30 days': (511849834000, 2406, 1708, 31, 509, 8, 1765, 'pt-00000'),
  'this UTC year': (5379516699000, 24997, 7581, 316, 509, 45, 7692, 'pt-00000'),
  'all time': (18811211563000, 87044, 9905, 1096, 509, 112, 9847, 'pt-00000'),
};

final _evidence = Platform.environment['OSML_PERF_EVIDENCE'] == '1';

void main() {
  late PerfFixture fixture;
  late AppDatabase db;
  late _Recorder recorder;
  late HistorySnapshotService snapshots;
  late ListeningStatsRepository stats;
  late TopTracksPager tracks;
  late TopArtistsPager artists;
  late TopAlbumsPager albums;

  setUpAll(() async {
    final sw = Stopwatch()..start();
    fixture = PerfFixture.generate();
    final generated = sw.elapsedMilliseconds;
    recorder = _Recorder();
    db = AppDatabase(NativeDatabase.memory().interceptWith(recorder));
    await fixture.seed(db);
    // ignore: avoid_print
    print('PERF fixture: generated in $generated ms, seeded in '
        '${sw.elapsedMilliseconds - generated} ms');
    snapshots = HistorySnapshotService(db, clock: FakeClock(startUtcMs: perfNowMs));
    stats = ListeningStatsRepository(db, BrowseRepository(db));
    tracks = TopTracksPager(snapshots, stats);
    artists = TopArtistsPager(snapshots, stats);
    albums = TopAlbumsPager(snapshots, stats);
  });

  tearDownAll(() => db.close());

  final ranges = <String, StatsRange>{
    '30 days': StatsRange.last30Days,
    'this UTC year': StatsRange.thisUtcYear,
    'all time': StatsRange.allTime,
  };

  // The windows written out by hand (spec §2), not read from
  // StatsRange.resolve: now is 2026-11-12T12:00Z.
  ({int? start, int end}) windowOf(StatsRange r) => switch (r) {
    StatsRange.last30Days => (start: perfNowMs - 30 * 86400000, end: perfNowMs),
    StatsRange.thisUtcYear => (start: 1767225600000, end: 1798761600000),
    StatsRange.allTime => (start: null, end: perfNowMs),
    _ => throw ArgumentError(r),
  };

  test('the fixture is the recorded one', () async {
    expect(fixture.events, hasLength(perfEventCount));
    expect(fixture.tracks, hasLength(perfTrackCount));
    final kinds = <String, int>{};
    for (final e in fixture.events) {
      final k = '${e.kind}/${e.type}';
      kinds[k] = (kinds[k] ?? 0) + 1;
    }
    // ignore: avoid_print
    print('PERF counts $kinds checksum ${fixture.checksum()}');
    final oracle = {
      for (final MapEntry(key: name, value: range) in ranges.entries)
        name: () {
          final w = windowOf(range);
          final o = fixture.oracle(startMs: w.start, endMs: w.end);
          return (o.listeningMicros, o.qualifiedPlays, o.uniqueTracks,
              o.activeDays, o.futureCount, o.overlongCount, o.tracks.length,
              o.tracks.first.$1);
        }(),
    };
    // ignore: avoid_print
    print('PERF oracle $oracle');
    expect(kinds, _recordedKinds);
    expect(fixture.checksum(), _recordedChecksum);
    expect(oracle, _recordedOracle);
    final rows = await db
        .customSelect('SELECT COUNT(*) AS n FROM history_events')
        .getSingle();
    expect(rows.read<int>('n'), perfEventCount);
  });

  for (final MapEntry(key: name, value: range) in ranges.entries) {
    test('$name: every statistic equals the oracle', () async {
      final w = windowOf(range);
      final want = fixture.oracle(startMs: w.start, endMs: w.end);
      final token = await snapshots.capture(range, attribution: true);
      final s = await stats.load(range, token.boundaryLocalId, perfNowMs);
      expect(s.totals.listeningSeconds,
          closeTo(want.listeningMicros / 1e6, 1e-3));
      expect(s.totals.qualifiedPlays, want.qualifiedPlays);
      expect(s.totals.uniqueTracks, want.uniqueTracks);
      expect(s.totals.activeDays, want.activeDays);
      expect(s.unavailable.listeningSeconds,
          closeTo(want.unavailableMicros / 1e6, 1e-3));
      expect(s.unavailable.qualifiedPlays, want.unavailableQualified);
      expect(s.futureTimestampCount, want.futureCount);
      expect(s.overlongListenCount, want.overlongCount);
      expect(
        [for (final e in s.topTracks) (e.entity.uuidId, e.qualifiedPlays)],
        [for (final t in want.tracks.take(10)) (t.$1, t.$3)],
      );
      expect(
        [for (final e in s.topArtists) (e.entity.id, e.qualifiedPlays)],
        [for (final t in want.artists.take(10)) (t.$1, t.$3)],
      );
      expect(
        [for (final e in s.topAlbums) (e.entity.id, e.qualifiedPlays)],
        [for (final t in want.albums.take(10)) (t.$1, t.$3)],
      );
    });
  }

  Future<List<RankedPageEntry<E, K>>> traverse<E, K>(
    SnapshotPager<RankedPageEntry<E, K>, RankCursor<K>> pager,
    HistorySnapshotToken token,
  ) async {
    final all = <RankedPageEntry<E, K>>[];
    RankCursor<K>? after;
    do {
      final r = await pager.page(token, after, rankingPageSize);
      if (r is! SnapshotPage<RankedPageEntry<E, K>, RankCursor<K>>) {
        fail('expired');
      }
      all.addAll(r.items);
      // The fixture ranks at most 10,000 entities: 200 pages of 50. A keyset
      // that stops advancing fails here, never spins.
      if (all.length > perfTrackCount) {
        fail('paging did not end; stuck after ${r.nextCursor}');
      }
      after = r.nextCursor;
    } while (after != null);
    return all;
  }

  test('30 days: the three pagers traverse whole rankings equal to the '
      'oracle, with no gap and no repeat', () async {
    final w = windowOf(StatsRange.last30Days);
    final want = fixture.oracle(startMs: w.start, endMs: w.end);
    final token =
        await snapshots.capture(StatsRange.last30Days, attribution: true);
    final t = await traverse(tracks, token);
    expect([for (final e in t) (e.cursor.key, e.cursor.listeningMicros,
        e.cursor.qualifiedPlays)], want.tracks);
    final ar = await traverse(artists, token);
    expect([for (final e in ar) (e.cursor.key, e.cursor.listeningMicros,
        e.cursor.qualifiedPlays)], want.artists);
    final al = await traverse(albums, token);
    expect([for (final e in al) (e.cursor.key, e.cursor.listeningMicros,
        e.cursor.qualifiedPlays)], want.albums);
  });

  test('all time: pages deep into the track ranking match the oracle',
      () async {
    final want = fixture.oracle(startMs: null, endMs: perfNowMs);
    final token = await snapshots.capture(StatsRange.allTime, attribution: true);
    // Jump straight to rank 5000 with the oracle's own cursor.
    final at = want.tracks[4999];
    final r = await tracks.page(
      token,
      RankCursor(listeningMicros: at.$2, qualifiedPlays: at.$3, key: at.$1),
      rankingPageSize,
    );
    final page = r as SnapshotPage<RankedPageEntry<dynamic, String>,
        RankCursor<String>>;
    expect([for (final e in page.items) e.cursor.key],
        [for (final t in want.tracks.skip(5000).take(50)) t.$1]);
  });

  Future<List<({String sql, List<Object?> args})>> record(
    Future<void> Function() run,
  ) async {
    recorder
      ..selects.clear()
      ..elapsedMs.clear()
      ..on = true;
    await run();
    recorder.on = false;
    return List.of(recorder.selects);
  }

  Future<List<String>> planOf(({String sql, List<Object?> args}) s) async => [
    for (final r in await db
        .customSelect(
          'EXPLAIN QUERY PLAN ${s.sql}',
          variables: [for (final a in s.args) Variable(a)],
        )
        .get())
      r.read<String>('detail'),
  ];

  test('every statistics and page statement searches history_events through '
      'its index; none scans it; statement counts are fixed', () async {
    final token = await snapshots.capture(StatsRange.allTime, attribution: true);
    final runs = <String, Future<void> Function()>{
      for (final MapEntry(key: name, value: range) in ranges.entries)
        'load $name': () => stats.load(range, token.boundaryLocalId, perfNowMs),
      'tracks page 1': () => tracks.page(token, null, rankingPageSize),
      'artists page 1': () => artists.page(token, null, rankingPageSize),
      'albums page 1': () => albums.page(token, null, rankingPageSize),
    };
    final counts = <String, int>{};
    for (final MapEntry(key: name, value: run) in runs.entries) {
      final statements = await record(run);
      counts[name] = statements.length;
      for (final s in statements.where((s) => s.sql.contains('history_events'))) {
        final plan = await planOf(s);
        // ignore: avoid_print
        print('PLAN [$name] ${s.sql}\n  ${plan.join('\n  ')}');
        expect(plan.where((d) => d.startsWith('SCAN history_events')), isEmpty,
            reason: '$name: no full scan of history_events\n$plan');
        expect(
          plan.any((d) => d.contains('history_events') &&
              d.contains('USING INDEX idx_history_events_kind_occurred')),
          isTrue,
          reason: '$name: history read through the kind index\n$plan',
        );
      }
    }
    // ignore: avoid_print
    print('PERF statements $counts');
    // load: the same statements for every range; a page: one counter check,
    // one ranking query and one hydration, whatever the history size.
    expect({for (final r in ranges.keys) counts['load $r']}, hasLength(1));
    for (final p in ['tracks', 'artists', 'albums']) {
      expect(counts['$p page 1'], 3, reason: p);
    }
  });

  // Evidence only, opt-in so the ordinary suite stays fast:
  //   OSML_PERF_EVIDENCE=1 flutter test --timeout 120s \
  //     test/repositories/stats_perf_test.dart
  test('timings (evidence only, never asserted)', skip: _evidence ? false :
      'set OSML_PERF_EVIDENCE=1 to print timings', () async {
    final token = await snapshots.capture(StatsRange.allTime, attribution: true);
    Future<int> time(Future<void> Function() run) async {
      // Median of three runs.
      final ms = <int>[];
      for (var i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        await run();
        ms.add(sw.elapsedMilliseconds);
      }
      ms.sort();
      return ms[1];
    }

    Future<Map<String, int>> timeAll() async {
      final results = <String, int>{};
      for (final MapEntry(key: name, value: range) in ranges.entries) {
        results['load $name'] = await time(
            () => stats.load(range, token.boundaryLocalId, perfNowMs));
      }
      results['tracks page 1 (all time)'] =
          await time(() => tracks.page(token, null, rankingPageSize));
      results['artists page 1 (all time)'] =
          await time(() => artists.page(token, null, rankingPageSize));
      results['albums page 1 (all time)'] =
          await time(() => albums.page(token, null, rankingPageSize));
      return results;
    }

    // ignore: avoid_print
    print('PERF timings (median of 3, ms) ${await timeAll()}');
    // D5: the spec's candidate index, measured on this fixture (created here
    // only, then dropped; the schema does not have it).
    await db.customStatement(
        'CREATE INDEX probe_spec_idx ON history_events '
        '(kind, entity_type, occurred_at, entity_ref)');
    // ignore: avoid_print
    print('PERF timings with the spec index (median of 3, ms) '
        '${await timeAll()}');
    for (final s in (await record(() => stats.load(
            StatsRange.last30Days, token.boundaryLocalId, perfNowMs)))
        .where((s) => s.sql.contains('history_events'))) {
      // ignore: avoid_print
      print('PLAN with spec index ${s.sql.substring(0, 60)}\n  '
          '${(await planOf(s)).join('\n  ')}');
    }
    await db.customStatement('DROP INDEX probe_spec_idx');
    // Per statement of one all-time load and one 30-day load.
    for (final range in [StatsRange.allTime, StatsRange.last30Days]) {
      final statements = await record(
          () => stats.load(range, token.boundaryLocalId, perfNowMs));
      for (var i = 0; i < statements.length; i++) {
        final sql = statements[i].sql;
        // ignore: avoid_print
        print('PERF stmt [$range] ${recorder.elapsedMs[i]} ms: '
            '${sql.length > 90 ? sql.substring(0, 90) : sql}');
      }
    }
  });
}
