// Phase 6B.3a (SC-10): the generic history snapshot primitives.
//
//  * capture: one read transaction over MAX(history_events.local_id) and the
//    SC-11 counters; capturedNowUtcMs from the SC-20 clock (never the wall
//    clock); catalogAttributionVersion stays null until Phase 9.
//
// Writers are the real ones (HistoryRepository) on in-memory Drift.
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';

import '../helpers/fake_clock.dart';
import '../helpers/server_binding.dart';
import 'history_snapshot_fixtures.dart';

void main() {
  late AppDatabase db;
  late HistoryRepository history;
  late String token;
  late FakeClock clock;
  late HistorySnapshotService service;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
    history = HistoryRepository(db);
    clock = FakeClock(startUtcMs: 1700000000123);
    service = HistorySnapshotService(db, clock: clock);
  });

  tearDown(() => db.close());

  group('capture', () {
    test('an empty history captures boundary 0 and version 0', () async {
      final t = await service.capture('chip-off');
      expect(t.boundaryLocalId, 0);
      expect(t.historyContentVersion, 0);
      expect(t.catalogAttributionVersion, isNull);
      expect(t.capturedNowUtcMs, 1700000000123);
      expect(t.filterKey, 'chip-off');
    });

    test('captures the newest local_id and the history_content counter',
        () async {
      await history.insertLocal(token, historyEvent('e1', at: 3000));
      await history.insertLocal(token, historyEvent('e2', at: 1000));
      await history.insertLocal(token, historyEvent('e3', at: 2000));
      await keepServerVersion(history, token, 'e1', at: 999);
      await keepServerVersion(history, token, 'e2', at: 999, revision: 2);
      clock.advance(const Duration(seconds: 5));

      final t = await service.capture(const ('downloaded', true));
      expect(t.boundaryLocalId, 3, reason: 'insertion order, not occurred_at');
      expect(t.historyContentVersion, 2);
      expect(t.catalogAttributionVersion, isNull,
          reason: 'Phase 9 fills it; Phase 6 never reads catalog_attribution');
      expect(t.capturedNowUtcMs, 1700000005123);
      expect(t.filterKey, const ('downloaded', true));
    });

    test('a pulled event with an old timestamp still moves the boundary',
        () async {
      await history.insertLocal(token, historyEvent('e1', at: 5000));
      await history.applyPage(
        token,
        requestedAfter: 0,
        page: pulledPage([serverEvent(historyEvent('old', at: 10), 1)]),
      );
      final t = await service.capture('k');
      expect(t.boundaryLocalId, 2);
    });

    test('a catalog_attribution row is not read into the token', () async {
      await db.customStatement(
          "INSERT INTO local_counters (key, value) VALUES ('catalog_attribution', 7)");
      final t = await service.capture('k');
      expect(t.catalogAttributionVersion, isNull);
      expect(t.historyContentVersion, 0);
    });

    test('a writer started during capture never yields a mixed token',
        () async {
      await history.insertLocal(token, historyEvent('e1'));
      // One writer transaction that adds a newer local_id AND bumps the
      // counter. Started right after capture begins: the token must be the
      // whole "before" view or the whole "after" view.
      final capturing = service.capture('k');
      final writing = db.transaction(() async {
        await history.insertLocal(token, historyEvent('e2'));
        await keepServerVersion(history, token, 'e1', at: 999);
      });
      final t = await capturing;
      await writing;
      final view = (t.boundaryLocalId, t.historyContentVersion);
      expect(view, anyOf(equals((1, 0)), equals((2, 1))),
          reason: 'boundary and counter come from one read transaction');
    });

    test('tokens have value equality', () async {
      final a = await service.capture('k');
      final b = await service.capture('k');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(await service.capture('other'), isNot(a));
      clock.advance(const Duration(milliseconds: 1));
      expect(await service.capture('k'), isNot(a));
      HistorySnapshotToken with_({
        int boundary = 0,
        int content = 0,
        int? catalog,
      }) => HistorySnapshotToken(
        boundaryLocalId: boundary,
        historyContentVersion: content,
        catalogAttributionVersion: catalog,
        capturedNowUtcMs: a.capturedNowUtcMs,
        filterKey: 'k',
      );
      expect(with_(), a);
      expect(with_(boundary: 1), isNot(a));
      expect(with_(content: 1), isNot(a));
      expect(with_(catalog: 0), isNot(a), reason: 'null is not 0');
    });
  });

  // Phase 9A.1b (D4, SC-10 seam): capture can also read catalog_attribution,
  // in the same statement as the boundary and history_content. Off by
  // default, so every Phase 6 caller keeps a null attribution.
  group('capture with attribution', () {
    /// A catalog write the v8 trigger counts (any writer of trackmetadata
    /// fires it; the writers themselves are proven in
    /// catalog_attribution_test.dart). Notifies drift like a real writer.
    Future<void> catalogWrite(String uuid) async {
      await db.customInsert(
        'INSERT INTO tracks (uuid_id, created_at, last_updated, revision) '
        'VALUES (?, 0, 0, 1)',
        variables: [Variable.withString(uuid)],
        updates: {db.tracks},
      );
      await db.customInsert(
        'INSERT INTO trackmetadata (uuid_id, title, has_album_art) '
        "VALUES (?, 'T', 0)",
        variables: [Variable.withString(uuid)],
        updates: {db.trackmetadata},
      );
    }

    test('an untouched catalog captures attribution version 0', () async {
      final t = await service.capture('k', attribution: true);
      expect(t.catalogAttributionVersion, 0,
          reason: 'no catalog change since the counter began');
      expect(t.boundaryLocalId, 0);
      expect(t.historyContentVersion, 0);
    });

    test('reads the counter a catalog write moved, with the rest of the '
        'token', () async {
      await history.insertLocal(token, historyEvent('e1'));
      await catalogWrite('u1');
      await catalogWrite('u2');
      await db.customStatement(
          "UPDATE local_counters SET value = 41 WHERE key = 'catalog_attribution'");
      final t = await service.capture('k', attribution: true);
      expect(t.catalogAttributionVersion, 41);
      expect(t.boundaryLocalId, 1);
      expect(t.capturedNowUtcMs, 1700000000123);
      expect(t.filterKey, 'k');
    });

    test('a catalog writer started during capture never yields a mixed token',
        () async {
      await history.insertLocal(token, historyEvent('e1'));
      final capturing = service.capture('k', attribution: true);
      final writing = db.transaction(() async {
        await history.insertLocal(token, historyEvent('e2'));
        await catalogWrite('u1');
      });
      final t = await capturing;
      await writing;
      expect((t.boundaryLocalId, t.catalogAttributionVersion),
          anyOf(equals((1, 0)), equals((2, 1))));
    });

    test('without the flag the token is the Phase 6 token, unchanged',
        () async {
      await catalogWrite('u1');
      final phase6 = await service.capture('k');
      expect(phase6.catalogAttributionVersion, isNull);
      final withAttribution = await service.capture('k', attribution: true);
      expect(withAttribution.catalogAttributionVersion, 1);
      expect(withAttribution, isNot(phase6), reason: 'null is not 1');
      expect(await service.capture('k'), phase6,
          reason: 'value equality holds for null-attribution tokens');
    });

    Future<SnapshotPageResult<int, int>> page(HistorySnapshotToken t) =>
        service.readPage<int, int>(
          t,
          limit: 1,
          fetch: (n) async => [1],
          cursorOf: (i) => i,
        );

    test('a catalog change expires an attribution token page but not a '
        'Phase 6 token page', () async {
      final phase6 = await service.capture('k');
      final phase9 = await service.capture('k', attribution: true);
      expect(await page(phase9), isA<SnapshotPage<int, int>>());
      await catalogWrite('u1');
      expect(await page(phase9), isA<SnapshotExpired<int, int>>());
      expect(await page(phase6), isA<SnapshotPage<int, int>>(),
          reason: 'a Phase 6 token does not carry the counter');
    });

    test('freshness: a catalog change is history changed for an attribution '
        'token, and leaves a Phase 6 token fresh', () async {
      final phase6 = await service.capture('k');
      final phase9 = await service.capture('k', attribution: true);
      final freshness = SnapshotFreshness(db);
      final seen6 = <SnapshotStaleness>[];
      final seen9 = <SnapshotStaleness>[];
      final s6 = freshness.watch(phase6).listen(seen6.add);
      final s9 = freshness.watch(phase9).listen(seen9.add);
      addTearDown(s6.cancel);
      addTearDown(s9.cancel);
      await pumpEventQueue();
      await catalogWrite('u1');
      await pumpEventQueue();
      expect(seen9, [SnapshotStaleness.fresh, SnapshotStaleness.historyChanged]);
      expect(seen6, [SnapshotStaleness.fresh]);
    });
  });
}
