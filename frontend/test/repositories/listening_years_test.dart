// Phase 9C.1 S2 (spec §6 "choose any UTC year with data or current year"):
// the UTC years that hold a counted listen. Expected years come from the
// recap fixture (make_recap_fixture.py) or are written out by hand.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

import 'listening_stats_workbook.dart';

const _fixture = 'test/fixtures/annual_recap/recap_fixture.json';

int utc(int y, [int m = 1, int d = 1]) =>
    DateTime.utc(y, m, d).millisecondsSinceEpoch;

void main() {
  late AppDatabase db;
  late ListeningStatsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ListeningStatsRepository(db, BrowseRepository(db));
  });

  tearDown(() => db.close());

  group('recap fixture', () {
    final fixture = Workbook.load(_fixture);
    final c = fixture.cases.first;

    setUp(() => fixture.seed(db));

    test('years with a counted listen, newest first', () async {
      expect(
        await repo.listeningYears(c.boundary!, c.capturedNowMs),
        (fixture.json['yearsWithListening']! as List).cast<int>(),
      );
    });

    test('listens at or after now do not make a year', () async {
      // At 2025-06-01 only 2024's and 2025's earlier listens exist.
      expect(
        await repo.listeningYears(c.boundary!, utc(2025, 6)),
        [2025, 2024],
      );
      // At exactly 2025-01-01T00:00Z the first 2025 listen is "now": future.
      expect(await repo.listeningYears(c.boundary!, utc(2025)), [2024]);
    });

    test('rows above the boundary do not make a year', () async {
      // Boundary 13 ends before 2024's listen (local_id 14) and 2026's.
      expect(await repo.listeningYears(13, c.capturedNowMs), [2025]);
    });
  });

  test('clicks, other entity types and non-positive or unknown seconds '
      'make no year', () async {
    var id = 0;
    Future<void> row(
      int at, {
      String kind = 'play',
      String type = 'track',
      double? seconds = 60,
    }) => db.into(db.historyEvents).insert(
      HistoryEventsCompanion.insert(
        eventUuid: 'e${id++}',
        kind: kind,
        entityType: type,
        entityRef: 't',
        occurredAt: at,
        secondsPlayed: Value(seconds),
        pendingUpload: false,
      ),
    );
    await row(utc(2019, 5), kind: 'clicked');
    await row(utc(2020, 5), type: 'album');
    await row(utc(2021, 5), seconds: null);
    await row(utc(2022, 5), seconds: 0);
    await row(utc(2023, 5), seconds: -1);
    await row(utc(2018, 5), seconds: double.infinity);
    expect(await repo.listeningYears(id, utc(2026)), isEmpty);
    await row(utc(2017, 12, 31), seconds: 0.5);
    expect(await repo.listeningYears(id, utc(2026)), [2017]);
  });

  test('an empty history has no years', () async {
    expect(await repo.listeningYears(0, utc(2026)), isEmpty);
  });
}
