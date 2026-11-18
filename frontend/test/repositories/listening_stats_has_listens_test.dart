// Phase 9A.2a (spec §4 para 1; brief "three states that must never be
// confused"): `ListeningStatsRepository.hasListens(boundary)` tells "no
// listening history at all" (the empty copy) apart from "history exists but
// the chosen range has none" (zeros). It is true exactly when a row that a
// statistic could ever count exists within the insertion boundary: a
// `kind='play'`, `entity_type='track'` event with positive finite seconds,
// whatever its date (a future-dated listen is history that counts later).
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

void main() {
  late AppDatabase db;
  late ListeningStatsRepository repo;
  var n = 0;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ListeningStatsRepository(db, BrowseRepository(db));
    n = 0;
  });
  tearDown(() => db.close());

  /// Inserts one history row and returns its local id.
  Future<int> insert({
    String kind = 'play',
    String entityType = 'track',
    double? seconds = 60,
    int atMs = 1700000000000,
    bool pending = false,
  }) {
    n++;
    return db.into(db.historyEvents).insert(
      HistoryEventsCompanion.insert(
        eventUuid: 'ev-$n',
        kind: kind,
        entityType: entityType,
        entityRef: 'track-$n',
        occurredAt: atMs,
        secondsPlayed: Value(seconds),
        pendingUpload: pending,
      ),
    );
  }

  test('an empty history has no listens', () async {
    expect(await repo.hasListens(0), isFalse);
    expect(await repo.hasListens(1000), isFalse);
  });

  test('one counted play is a listen', () async {
    final id = await insert();
    expect(await repo.hasListens(id), isTrue);
  });

  test('rows a statistic never counts are not listens', () async {
    await insert(kind: 'clicked');
    await insert(entityType: 'album');
    await insert(seconds: null);
    await insert(seconds: 0);
    await insert(seconds: -5);
    final last = await insert(seconds: double.infinity);
    expect(await repo.hasListens(last), isFalse);
  });

  test('the boundary bounds the answer: a later listen is not seen',
      () async {
    final click = await insert(kind: 'clicked');
    final play = await insert();
    expect(await repo.hasListens(click), isFalse);
    expect(await repo.hasListens(play), isTrue);
  });

  test('a future-dated listen is history (it counts at its time)', () async {
    final id = await insert(atMs: DateTime.utc(2999).millisecondsSinceEpoch);
    expect(await repo.hasListens(id), isTrue);
  });

  test('a listen from any year counts, not only the current range',
      () async {
    final id = await insert(atMs: DateTime.utc(2001, 3).millisecondsSinceEpoch);
    expect(await repo.hasListens(id), isTrue);
  });

  group('pendingListens (review r1 F2)', () {
    test('counts only counted plays still waiting to upload', () async {
      await insert(pending: true);
      await insert(pending: true, atMs: DateTime.utc(2999).millisecondsSinceEpoch);
      await insert();
      await insert(kind: 'clicked', pending: true);
      await insert(seconds: 0, pending: true);
      await insert(seconds: null, pending: true);
      final last = await insert(entityType: 'album', pending: true);
      expect(await repo.pendingListens(last), 2);
    });

    test('the boundary bounds the count', () async {
      final first = await insert(pending: true);
      await insert(pending: true);
      expect(await repo.pendingListens(first), 1);
      expect(await repo.pendingListens(0), 0);
    });
  });
}
