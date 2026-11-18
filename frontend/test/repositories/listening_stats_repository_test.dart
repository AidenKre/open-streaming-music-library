// Phase 9A.1 (spec §2, §3; review 9-U01, 9-U02, 9-U03): the listening
// statistics repository against the independent fixture workbook. Every
// expected value comes from workbook.json (make_workbook.py, written from the
// §2 definitions), never from the repository's SQL.
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

import '../helpers/server_binding.dart';
import 'catalog_seed.dart';
import 'history_snapshot_fixtures.dart';
import 'listening_stats_workbook.dart';

const _eps = 1e-6;

/// Rounds to the workbook's comparison precision (1 µs).
Object _close(double v) => (v * 1e6).round();

/// `YYYY-MM-DD` (day) or `YYYY-MM` (month) of a UTC bucket start.
String _label(int ms, StatsBucketUnit unit) {
  final iso = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
      .toIso8601String();
  return unit == StatsBucketUnit.day ? iso.substring(0, 10) : iso.substring(0, 7);
}

void main() {
  final workbook = Workbook.load();

  group('workbook', () {
    late AppDatabase db;
    late ListeningStatsRepository repo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await workbook.seed(db);
      repo = ListeningStatsRepository(db, BrowseRepository(db));
    });

    tearDown(() => db.close());

    Future<ListeningStats> loadCase(WorkbookCase c) => repo.load(
      c.range,
      c.boundary ?? workbook.maxLocalId,
      c.capturedNowMs,
    );

    for (final c in workbook.cases) {
      group(c.name, () {
        test('totals, unavailable subtotal and future diagnostic', () async {
          final s = await loadCase(c);
          expect(s.range, c.range);
          expect(s.capturedNowUtcMs, c.capturedNowMs);
          expect(s.boundaryLocalId, c.boundary ?? workbook.maxLocalId);
          expect(s.totals.listeningSeconds, closeTo(c.listeningSeconds, _eps));
          expect(s.totals.qualifiedPlays, c.qualifiedPlays);
          expect(s.totals.uniqueTracks, c.uniqueTracks);
          expect(s.totals.activeDays, c.activeDays);
          expect(
            s.unavailable.listeningSeconds,
            closeTo(c.unavailableSeconds, _eps),
          );
          expect(s.unavailable.qualifiedPlays, c.unavailableQualified);
          expect(s.futureTimestampCount, c.futureTimestampCount);
        });

        test('buckets: zero-filled, by start, all-time chart capped', () async {
          final s = await loadCase(c);
          expect(s.bucketUnit.name, c.bucketUnit);
          expect(s.chartCapped, c.chartCapped);
          expect(
            [for (final b in s.buckets) _label(b.startUtcMs, s.bucketUnit)],
            [for (final b in c.buckets) b.$1],
          );
          for (var i = 0; i < s.buckets.length; i++) {
            expect(
              s.buckets[i].listeningSeconds,
              closeTo(c.buckets[i].$2, _eps),
              reason: c.buckets[i].$1,
            );
            if (i > 0) {
              expect(s.buckets[i].startUtcMs, s.buckets[i - 1].endUtcMs);
            }
          }
          if (!c.chartCapped) {
            final sum = s.buckets.fold<double>(
              0,
              (a, b) => a + b.listeningSeconds,
            );
            expect(sum, closeTo(c.listeningSeconds, _eps),
                reason: 'an uncapped chart holds every counted second');
          }
        });

        test('top tracks: ranked, ties by uuid, unavailable excluded, '
            'hydrated through SC-12', () async {
          final s = await loadCase(c);
          final want = c.ranked('topTracks');
          expect(
            [for (final e in s.topTracks) e.entity.uuidId],
            [for (final w in want) w.$1],
          );
          for (var i = 0; i < want.length; i++) {
            expect(s.topTracks[i].listeningSeconds, closeTo(want[i].$2, _eps));
            expect(s.topTracks[i].qualifiedPlays, want[i].$3);
            expect(
              s.topTracks[i].entity.title,
              workbook.trackTitle(want[i].$1 as String),
              reason: 'hydrated with current metadata',
            );
          }
        });

        test('top artists and albums by current catalog parents', () async {
          final s = await loadCase(c);
          for (final (key, got) in [
            ('topArtists', [
              for (final e in s.topArtists)
                (e.entity.id, e.listeningSeconds, e.qualifiedPlays),
            ]),
            ('topAlbums', [
              for (final e in s.topAlbums)
                (e.entity.id, e.listeningSeconds, e.qualifiedPlays),
            ]),
          ]) {
            final want = c.ranked(key);
            expect([for (final g in got) g.$1], [for (final w in want) w.$1],
                reason: key);
            for (var i = 0; i < want.length; i++) {
              expect(got[i].$2, closeTo(want[i].$2, _eps), reason: key);
              expect(got[i].$3, want[i].$3, reason: key);
            }
          }
        });
      });
    }
  });

  group('ranking precision (review F1)', () {
    late AppDatabase db;
    late ListeningStatsRepository repo;
    // 2026-01-03T12:00Z.
    const now = 1767441600000;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = ListeningStatsRepository(db, BrowseRepository(db));
      final seed = CatalogSeed(db);
      await seed.artist(1, 'One');
      await seed.artist(2, 'Two');
      await seed.album(1, artistId: 1);
      await seed.album(2, artistId: 2);
      // Same recorded time (0.3 s, as Phase 5 writes micros / 1e6), split
      // into 0.1 + 0.2 for t-x but one listen for t-a: a tie, so uuid ASC
      // (and id ASC for parents) decides, not a last-bit double difference.
      await seed.track('t-a', artistId: 1, albumId: 1);
      await seed.track('t-x', artistId: 2, albumId: 2);
      var id = 0;
      for (final (ref, secs) in [('t-x', 0.1), ('t-x', 0.2), ('t-a', 0.3)]) {
        await db.into(db.historyEvents).insert(
          HistoryEventsCompanion.insert(
            eventUuid: 'p-${id++}',
            kind: 'play',
            entityType: 'track',
            entityRef: ref,
            occurredAt: now - 3600000,
            secondsPlayed: Value(secs),
            trackLength: const Value(200.0),
            pendingUpload: false,
          ),
        );
      }
    });

    tearDown(() => db.close());

    test('equal microsecond totals tie, whatever the summation order',
        () async {
      final s = await repo.load(StatsRange.last7Days, 1 << 40, now);
      expect([for (final e in s.topTracks) e.entity.uuidId], ['t-a', 't-x']);
      expect([for (final e in s.topArtists) e.entity.id], [1, 2]);
      expect([for (final e in s.topAlbums) e.entity.id], [1, 2]);
      for (final e in s.topTracks) {
        expect(e.listeningSeconds, closeTo(0.3, _eps));
      }
    });
  });

  group('one snapshot', () {
    late AppDatabase db;
    late _GatedSelects gate;
    late ListeningStatsRepository repo;
    final seven = workbook.cases.firstWhere((c) => c.name == '7 days');

    setUp(() async {
      gate = _GatedSelects();
      db = AppDatabase(NativeDatabase.memory().interceptWith(gate));
      await workbook.seed(db);
      repo = ListeningStatsRepository(db, BrowseRepository(db));
    });

    tearDown(() => db.close());

    // Pause load before each of its later SELECTs in turn (review F3), so a
    // split into several transactions is caught wherever the split falls.
    for (var at = 2; at <= 10; at++) {
    test('writers during load cannot mix totals, chart and lists '
        '(paused at SELECT $at)', () async {
      gate.armAt(gate.selects + at);
      final loading = repo.load(
        seven.range,
        workbook.maxLocalId,
        seven.capturedNowMs,
      );
      // Past load's last SELECT the gate is never reached: writers then run
      // after load, which proves nothing but must still agree.
      await Future.any([gate.reached.future, loading]);
      // A tombstone of t-b (top track), a rewritten payload of t-c and a new
      // listen, all while load is paused.
      final writing = () async {
        await db.customUpdate(
          "DELETE FROM trackmetadata WHERE uuid_id = 't-b'",
          updates: {db.trackmetadata},
          updateKind: UpdateKind.delete,
        );
        await db.customUpdate(
          'UPDATE history_events SET seconds_played = 9000 '
          "WHERE event_uuid = 'e-rewind'",
          updates: {db.historyEvents},
          updateKind: UpdateKind.update,
        );
        await db.customInsert(
          'INSERT INTO history_events (event_uuid, kind, entity_type, '
          'entity_ref, occurred_at, seconds_played, track_length, '
          "pending_upload) VALUES ('e-new', 'play', 'track', 't-e', ?, "
          '5000, 200, 1)',
          variables: [Variable.withInt(seven.capturedNowMs - 60000)],
          updates: {db.historyEvents},
        );
      }();
      gate.release();
      final s = await loading;
      await writing;

      expect(s.totals.listeningSeconds, closeTo(seven.listeningSeconds, _eps));
      expect(s.unavailable.listeningSeconds,
          closeTo(seven.unavailableSeconds, _eps));
      expect(
        s.buckets.fold<double>(0, (a, b) => a + b.listeningSeconds),
        closeTo(seven.listeningSeconds, _eps),
      );
      final want = seven.ranked('topTracks');
      expect(
        [for (final e in s.topTracks) e.entity.uuidId],
        [for (final w in want) w.$1],
      );
      for (var i = 0; i < want.length; i++) {
        expect(s.topTracks[i].listeningSeconds, closeTo(want[i].$2, _eps));
      }
      expect(
        [for (final e in s.topArtists) (e.entity.id, _close(e.listeningSeconds))],
        [for (final w in seven.ranked('topArtists')) (w.$1, _close(w.$2))],
      );
      expect(
        [for (final e in s.topAlbums) (e.entity.id, _close(e.listeningSeconds))],
        [for (final w in seven.ranked('topAlbums')) (w.$1, _close(w.$2))],
      );
      // The writers did run, after load.
      final after = await repo.load(
        seven.range,
        workbook.maxLocalId,
        seven.capturedNowMs,
      );
      expect(after.topTracks.map((e) => e.entity.uuidId), isNot(contains('t-b')));
    });
    }
  });

  group('attribution follows the current catalog', () {
    late AppDatabase db;
    late ListeningStatsRepository repo;
    final year = workbook.cases.firstWhere((c) => c.name == 'chosen year 2025');

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await workbook.seed(db);
      repo = ListeningStatsRepository(db, BrowseRepository(db));
    });

    tearDown(() => db.close());

    Future<ListeningStats> load() =>
        repo.load(year.range, workbook.maxLocalId, year.capturedNowMs);

    double secondsOf<T>(List<RankedEntry<T>> list, bool Function(T) where) =>
        list.where((e) => where(e.entity)).fold(
          0.0,
          (a, e) => a + e.listeningSeconds,
        );

    test('a track arriving by catalog sync moves its time from unavailable '
        'into the rankings; the overall total is unchanged', () async {
      final before = await load();
      // t-never: one 35 s listen of unknown length on 2025-12-31.
      await CatalogSeed(db).track('t-never', artistId: 2, albumId: 20);
      final after = await load();
      expect(after.totals.listeningSeconds,
          closeTo(before.totals.listeningSeconds, _eps));
      expect(after.totals.qualifiedPlays, before.totals.qualifiedPlays);
      expect(after.unavailable.listeningSeconds,
          closeTo(before.unavailable.listeningSeconds - 35, _eps));
      expect(after.unavailable.qualifiedPlays,
          before.unavailable.qualifiedPlays - 1);
      expect(secondsOf(after.topArtists, (a) => a.id == 2),
          closeTo(secondsOf(before.topArtists, (a) => a.id == 2) + 35, _eps));
      expect(secondsOf(after.topAlbums, (a) => a.id == 20),
          closeTo(secondsOf(before.topAlbums, (a) => a.id == 20) + 35, _eps));
    });

    test('a moved track counts under its current album and artist', () async {
      final before = await load();
      final tA = before.topTracks.firstWhere((e) => e.entity.uuidId == 't-a');
      // t-a moves from artist 1 / album 10 to artist 2 / album 20.
      await db.customUpdate(
        "UPDATE trackmetadata SET artist_id = 2, album_id = 20 "
        "WHERE uuid_id = 't-a'",
        updates: {db.trackmetadata},
        updateKind: UpdateKind.update,
      );
      final after = await load();
      expect(after.totals.listeningSeconds,
          closeTo(before.totals.listeningSeconds, _eps));
      expect(secondsOf(after.topAlbums, (a) => a.id == 20),
          closeTo(secondsOf(before.topAlbums, (a) => a.id == 20) +
              tA.listeningSeconds, _eps));
      expect(secondsOf(after.topAlbums, (a) => a.id == 10),
          closeTo(secondsOf(before.topAlbums, (a) => a.id == 10) -
              tA.listeningSeconds, _eps));
      expect(secondsOf(after.topArtists, (a) => a.id == 1),
          closeTo(secondsOf(before.topArtists, (a) => a.id == 1) -
              tA.listeningSeconds, _eps));
    });

    test('a tombstoned track leaves the rankings and joins the unavailable '
        'subtotal; never dropped, never zero', () async {
      final before = await load();
      final tC = before.topTracks.firstWhere((e) => e.entity.uuidId == 't-c');
      await db.customUpdate(
        "DELETE FROM trackmetadata WHERE uuid_id = 't-c'",
        updates: {db.trackmetadata},
        updateKind: UpdateKind.delete,
      );
      await db.customUpdate(
        "DELETE FROM tracks WHERE uuid_id = 't-c'",
        updates: {db.tracks},
        updateKind: UpdateKind.delete,
      );
      final after = await load();
      expect(after.totals.listeningSeconds,
          closeTo(before.totals.listeningSeconds, _eps));
      expect(after.totals.uniqueTracks, before.totals.uniqueTracks);
      expect(after.unavailable.listeningSeconds,
          closeTo(before.unavailable.listeningSeconds + tC.listeningSeconds,
              _eps));
      expect(after.unavailable.qualifiedPlays,
          before.unavailable.qualifiedPlays + tC.qualifiedPlays);
      expect(after.topTracks.map((e) => e.entity.uuidId), isNot(contains('t-c')));
      expect(secondsOf(after.topArtists, (a) => a.id == 2),
          closeTo(secondsOf(before.topArtists, (a) => a.id == 2) -
              tC.listeningSeconds, _eps));
    });
  });

  group('what counts as a listen (O4)', () {
    late AppDatabase db;
    late HistoryRepository history;
    late ListeningStatsRepository repo;
    late String token;

    // 2026-01-03T12:00Z; every event below is safely inside 7 days.
    const now = 1767441600000;
    const at = now - 3600000;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      token = await seedTestBinding(db);
      history = HistoryRepository(db);
      repo = ListeningStatsRepository(db, BrowseRepository(db));
    });

    tearDown(() => db.close());

    Future<ListeningTotals> totals() async =>
        (await repo.load(StatsRange.last7Days, 1 << 40, now)).totals;

    test('a pending local listen counts once; its ACK and its pulled echo '
        'add nothing', () async {
      final e = historyEvent('e1', at: at, ref: 'track-x'); // 30 s of 200 s
      await history.insertLocal(token, e);
      final before = await totals();
      expect(before.listeningSeconds, closeTo(30, _eps));
      expect(before.qualifiedPlays, 1);

      await history.applyAck(token, ['e1'], ['e1']);
      await history.applyPage(
        token,
        requestedAfter: 0,
        page: pulledPage([serverEvent(e, 1)]),
      );
      final after = await totals();
      expect(after.listeningSeconds, closeTo(30, _eps));
      expect(after.qualifiedPlays, 1);
      expect(after.uniqueTracks, 1);
    });

    test('a pulled event from another device counts like a local one',
        () async {
      await history.insertLocal(
        token,
        historyEvent('local', at: at, ref: 'track-x'),
      );
      await history.applyPage(
        token,
        requestedAfter: 0,
        page: pulledPage([
          serverEvent(historyEvent('other-device', at: at, ref: 'track-x'), 1),
        ]),
      );
      final t = await totals();
      expect(t.listeningSeconds, closeTo(60, _eps));
      expect(t.qualifiedPlays, 2);
      expect(t.uniqueTracks, 1);
      expect(t.activeDays, 1);
    });

    test('active and finalizing drafts do not count; finalization counts '
        'once', () async {
      const uuid = '11111111-1111-4111-8111-111111111111';
      final play = historyEvent(uuid, at: at, ref: 'track-x');
      await history.checkpointDraft(
        token,
        ListenDraft(
          listenUuid: uuid,
          queueSessionId: 1,
          queueItemId: 2,
          trackUuid: 'track-x',
          startedAt: at,
          durationSeconds: 200,
          accumulatedMicros: 30000000,
          lastCheckpointAt: at + 30000,
        ),
      );
      expect((await totals()).listeningSeconds, 0, reason: 'accumulating');
      await history.freezeDraft(token, uuid, play);
      expect((await totals()).listeningSeconds, 0, reason: 'finalizing');
      await history.finalizeDraft(token, play);
      await history.finalizeDraft(token, play); // crash replay: idempotent
      final t = await totals();
      expect(t.listeningSeconds, closeTo(30, _eps));
      expect(t.qualifiedPlays, 1);
    });

    test('clicks are not listens', () async {
      await history.insertLocal(
        token,
        historyEvent('c1', kind: 'clicked', at: at, ref: 'track-x'),
      );
      final t = await totals();
      expect(t.listeningSeconds, 0);
      expect(t.qualifiedPlays, 0);
      expect(t.activeDays, 0);
    });

    test('an empty history is real zeros', () async {
      final s = await repo.load(StatsRange.allTime, 0, now);
      expect(s.totals.listeningSeconds, 0);
      expect(s.totals.qualifiedPlays, 0);
      expect(s.totals.uniqueTracks, 0);
      expect(s.totals.activeDays, 0);
      expect(s.unavailable.listeningSeconds, 0);
      expect(s.futureTimestampCount, 0);
    });
  });
}

/// Pauses the [armAt]-th SELECT reaching SQLite until [release].
class _GatedSelects extends QueryInterceptor {
  int selects = 0;
  int? _at;
  final reached = Completer<void>();
  final _release = Completer<void>();

  void armAt(int n) => _at = n;
  void release() => _release.complete();

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    selects++;
    if (selects == _at) {
      reached.complete();
      await _release.future;
    }
    return super.runSelect(executor, statement, args);
  }
}
