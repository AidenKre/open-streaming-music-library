// Phase 6B.3a (SC-10): the generic history snapshot primitives.
//
//  * capture: one read transaction over MAX(history_events.local_id) and the
//    SC-11 counters; capturedNowUtcMs from the SC-20 clock (never the wall
//    clock); catalogAttributionVersion stays null until Phase 9.
//
// Writers are the real ones (HistoryRepository) on in-memory Drift.
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
}
