// Phase 9A.1c (9B.1 review F1, inherited from 9A.1a): a play row holding an
// absurd duration must not overflow the integer-microsecond ranking sums.
// The shared play-row fragment bounds seconds once at maxListenSeconds
// (7 days); a row above it is excluded from every statistic and counted in
// the model's overlongListenCount diagnostic, never silently dropped.
// Expected values are written by hand from the rows below.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';
import 'package:frontend/repositories/suggestion_pools_repository.dart';

import 'catalog_seed.dart';

// 2026-01-03T12:00Z.
const _now = 1767441600000;
const _hour = 3600000;

void main() {
  late AppDatabase db;
  late ListeningStatsRepository repo;
  var seq = 0;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = ListeningStatsRepository(db, BrowseRepository(db));
    final seed = CatalogSeed(db);
    await seed.artist(1, 'One');
    await seed.album(1, artistId: 1);
    await seed.track('t-a', artistId: 1, albumId: 1);
    seq = 0;
  });

  tearDown(() => db.close());

  Future<void> listen(double seconds, {int at = _now - _hour, String ref = 't-a'}) =>
      db.into(db.historyEvents).insert(
        HistoryEventsCompanion.insert(
          eventUuid: 'p-${seq++}',
          kind: 'play',
          entityType: 'track',
          entityRef: ref,
          occurredAt: at,
          secondsPlayed: Value(seconds),
          trackLength: const Value(200.0),
          pendingUpload: false,
        ),
      );

  test('the bound is seven days of played audio', () {
    expect(maxListenSeconds, 7 * 24 * 3600.0);
  });

  test('two absurd rows (9.3e12 s each) no longer make every statistic '
      'throw: they are excluded and counted as overlong', () async {
    await listen(100);
    await listen(9.3e12);
    await listen(9.3e12);
    final s = await repo.load(StatsRange.last7Days, 1 << 40, _now);
    expect(s.totals.listeningSeconds, 100);
    expect(s.totals.qualifiedPlays, 1);
    expect(s.totals.activeDays, 1);
    expect(s.overlongListenCount, 2);
    expect([for (final e in s.topTracks) e.entity.uuidId], ['t-a']);
    expect(s.topTracks.single.listeningSeconds, 100);
    expect(s.topArtists.single.listeningSeconds, 100);
    expect(s.topAlbums.single.listeningSeconds, 100);
    expect(s.buckets.fold<double>(0, (a, b) => a + b.listeningSeconds), 100);
    expect(await repo.hasListens(1 << 40), isTrue);
  });

  test('exactly the bound counts; just above it is overlong', () async {
    await listen(maxListenSeconds);
    await listen(maxListenSeconds + 0.5);
    final s = await repo.load(StatsRange.last7Days, 1 << 40, _now);
    expect(s.totals.listeningSeconds, maxListenSeconds);
    expect(s.overlongListenCount, 1);
  });

  test('the diagnostic counts overlong rows of the selected range only, '
      'of unresolved tracks too, and is 0 when there are none', () async {
    await listen(50);
    // Outside the 7 days, and an unresolved track inside it.
    await listen(1e9, at: _now - 30 * 24 * _hour);
    await listen(1e9, ref: 't-gone');
    final week = await repo.load(StatsRange.last7Days, 1 << 40, _now);
    expect(week.overlongListenCount, 1);
    expect(week.unavailable.listeningSeconds, 0);
    final all = await repo.load(StatsRange.allTime, 1 << 40, _now);
    expect(all.overlongListenCount, 2);
    expect(all.totals.listeningSeconds, 50);
    await db.delete(db.historyEvents).go();
    await listen(50);
    final none = await repo.load(StatsRange.allTime, 1 << 40, _now);
    expect(none.overlongListenCount, 0);
  });

  test('an overlong row dated in the future is counted as overlong, never '
      'lost between the two diagnostics (review F1)', () async {
    await listen(50);
    await listen(1e9, at: _now + _hour);
    await listen(100, at: _now + _hour);
    final s = await repo.load(StatsRange.last7Days, 1 << 40, _now);
    expect(s.overlongListenCount, 1);
    expect(s.futureTimestampCount, 1, reason: 'the plausible future row');
    expect(s.totals.listeningSeconds, 50);
  });

  test('an overlong row is no listen anywhere the fragment is shared '
      '(suggestion pools no longer throw)', () async {
    // Two qualified listens 20 days ago make t-a a Rediscover candidate.
    await listen(100, at: _now - 20 * 24 * _hour);
    await listen(100, at: _now - 20 * 24 * _hour);
    await listen(9.3e12, at: _now - 20 * 24 * _hour);
    await listen(9.3e12, at: _now - 20 * 24 * _hour);
    final pools = await SuggestionPoolsRepository(db).load(1 << 40, _now);
    expect([for (final c in pools.rediscover) c.track.uuid], ['t-a']);
  });
}
