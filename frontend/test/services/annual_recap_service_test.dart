// Phase 9C.1 S3 (spec §6 paragraphs 1–2; review 9-U06 model half): the
// recap is read from ONE statistics load under ONE snapshot token. Expected
// values come from the independent recap fixture
// (test/fixtures/annual_recap/make_recap_fixture.py), never from the code.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';
import 'package:frontend/services/annual_recap_service.dart';

import '../helpers/fake_clock.dart';
import '../repositories/listening_stats_workbook.dart';

const _fixture = 'test/fixtures/annual_recap/recap_fixture.json';

String monthLabel(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
    .toIso8601String()
    .substring(0, 7);

/// Records every `load` and forwards it.
class CountingStatsRepository extends ListeningStatsRepository {
  CountingStatsRepository(super.db, super.browse);
  final loads = <(StatsRange, int, int)>[];

  @override
  Future<ListeningStats> load(StatsRange range, int boundary, int now) {
    loads.add((range, boundary, now));
    return super.load(range, boundary, now);
  }
}

/// A statistics repository whose year list cannot be read.
class _FailingYearsRepository extends ListeningStatsRepository {
  _FailingYearsRepository(super.db, super.browse);

  @override
  Future<List<int>> listeningYears(int boundary, int now) =>
      throw StateError('years unreadable');
}

void main() {
  final fixture = Workbook.load(_fixture);
  late AppDatabase db;
  late CountingStatsRepository stats;
  late FakeClock clock;
  late AnnualRecapService service;

  HistorySnapshotToken tokenFor(WorkbookCase c) => HistorySnapshotToken(
    boundaryLocalId: c.boundary!,
    historyContentVersion: 0,
    capturedNowUtcMs: c.capturedNowMs,
    filterKey: annualRecapFilterKey,
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await fixture.seed(db);
    stats = CountingStatsRepository(db, BrowseRepository(db));
    clock = FakeClock(startUtcMs: fixture.cases.first.capturedNowMs);
    service = AnnualRecapService(
      stats,
      HistorySnapshotService(db, clock: clock),
    );
  });

  tearDown(() => db.close());

  for (final c in fixture.cases) {
    final e = c.expected;
    final year = c.json['year']! as int;

    test('${c.name}: the fixture\'s recap', () async {
      final token = tokenFor(c);
      final recap = await service.load(year, token);

      expect(recap.year, year);
      expect(recap.isYearSoFar, e['yearSoFar']);
      expect(recap.window.startUtcMs, e['startMs']);
      expect(recap.window.endUtcMs, e['endMs']);
      expect(recap.window.countedEndUtcMs, e['countedEndMs']);
      expect(recap.generatedAtUtcMs, e['generatedMs']);
      expect(recap.token, token);

      expect(recap.totals.listeningSeconds, e['listeningSeconds']);
      expect(recap.totals.qualifiedPlays, e['qualifiedPlays']);
      expect(recap.totals.uniqueTracks, e['uniqueTracks']);
      expect(recap.totals.activeDays, e['activeDays']);
      final u = e['unavailable']! as Map;
      expect(recap.unavailable.listeningSeconds, u['listeningSeconds']);
      expect(recap.unavailable.qualifiedPlays, u['qualifiedPlays']);

      expect(
        [
          for (final m in recap.months)
            (monthLabel(m.startUtcMs), m.listeningSeconds),
        ],
        [
          for (final m in (e['months']! as List).cast<Map>())
            (m['month'], m['seconds']),
        ],
      );
      expect(
        recap.busiestMonth == null
            ? null
            : monthLabel(recap.busiestMonth!.startUtcMs),
        e['busiestMonth'],
      );

      List<(Object, double, int)> ranked(String key) => [
        for (final r in (e[key]! as List).cast<Map>())
          (
            r['id'] as Object,
            (r['seconds'] as num).toDouble(),
            r['qualifiedPlays'] as int,
          ),
      ];
      expect(
        [
          for (final t in recap.topTracks)
            (t.entity.uuidId, t.listeningSeconds, t.qualifiedPlays),
        ],
        ranked('topTracks'),
      );
      expect(
        [
          for (final a in recap.topArtists)
            (a.entity.id, a.listeningSeconds, a.qualifiedPlays),
        ],
        ranked('topArtists'),
      );
      expect(
        [
          for (final a in recap.topAlbums)
            (a.entity.id, a.listeningSeconds, a.qualifiedPlays),
        ],
        ranked('topAlbums'),
      );
    });

    test('${c.name}: exactly one load, of the year, under the token',
        () async {
      await service.load(year, tokenFor(c));
      expect(stats.loads, [
        (StatsRange.year(year), c.boundary!, c.capturedNowMs),
      ]);
    });
  }

  test('2025: the busiest-month tie goes to March, the top-five tie to t-e',
      () async {
    // Spelled out from the fixture's notes so a regenerated fixture that
    // lost the ties fails here.
    final c = fixture.cases.firstWhere((c) => c.json['year'] == 2025);
    final recap = await service.load(2025, tokenFor(c));
    final march = recap.months[2].listeningSeconds;
    final july = recap.months[6].listeningSeconds;
    expect(march, july);
    expect(monthLabel(recap.busiestMonth!.startUtcMs), '2025-03');
    expect(recap.topTracks.last.entity.uuidId, 't-e');
    expect(recap.topTracks.last.listeningSeconds, 250.0);
  });

  group('snapshot', () {
    test('one token: the history boundary and the clock\'s now', () async {
      clock.advance(const Duration(minutes: 1));
      final token = (await service.snapshot()).recap.token;
      expect(token.boundaryLocalId, fixture.maxLocalId);
      expect(token.capturedNowUtcMs, clock.nowUtcMs());
      expect(token.filterKey, annualRecapFilterKey);
    });

    test('a given year: that year\'s recap and the years to choose from',
        () async {
      final snap = await service.snapshot(year: 2025);
      expect(snap.recap.year, 2025);
      expect(snap.recap.token.boundaryLocalId, fixture.maxLocalId);
      expect(
        snap.years,
        (fixture.json['yearsWithListening']! as List).cast<int>(),
      );
    });

    test('a failing years read gives null years; the recap still returns',
        () async {
      final failing = AnnualRecapService(
        _FailingYearsRepository(db, BrowseRepository(db)),
        HistorySnapshotService(db, clock: clock),
      );
      final snap = await failing.snapshot(year: 2025);
      expect(snap.years, isNull);
      expect(snap.recap.year, 2025);
    });
  });

  group('years to choose from', () {
    test('the years with listening and the current UTC year, newest first',
        () async {
      final c = fixture.cases.first;
      expect(
        await service.years(tokenFor(c)),
        (fixture.json['yearsWithListening']! as List).cast<int>(),
      );
    });

    test('the current UTC year is offered even without listening', () async {
      final c = fixture.cases.first;
      final token = HistorySnapshotToken(
        boundaryLocalId: c.boundary!,
        historyContentVersion: 0,
        capturedNowUtcMs: DateTime.utc(2028, 2).millisecondsSinceEpoch,
        filterKey: annualRecapFilterKey,
      );
      expect(await service.years(token), [2028, 2026, 2025, 2024]);
    });

    test('an empty history offers only the current year', () async {
      final token = HistorySnapshotToken(
        boundaryLocalId: 0,
        historyContentVersion: 0,
        capturedNowUtcMs: DateTime.utc(2026, 3, 15).millisecondsSinceEpoch,
        filterKey: annualRecapFilterKey,
      );
      expect(await service.years(token), [2026]);
    });
  });
}
