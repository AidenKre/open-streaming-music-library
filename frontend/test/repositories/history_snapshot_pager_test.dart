// Phase 6B.3a (SC-10): snapshot page reads, through a toy consumer pager.
//
//  * readPage runs the whole page in ONE Drift transaction that first
//    re-reads the counters the token carries; a mismatch is SnapshotExpired
//    and the fetch does not run.
//  * fetch limit+1, return limit; the cursor is the last returned item's key,
//    null on the last page.
//  * Expired exactly for the carried counters: history_content always,
//    catalog_attribution only when the token carries it. A newer local_id is
//    not expiry (the boundary hides it; freshness reports it).
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';

import '../helpers/fake_clock.dart';
import '../helpers/server_binding.dart';
import 'history_snapshot_fixtures.dart';
import 'toy_listen_pager.dart';

void main() {
  late AppDatabase db;
  late HistoryRepository history;
  late String token;
  late HistorySnapshotService service;
  late ToyListenPager pager;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
    history = HistoryRepository(db);
    service = HistorySnapshotService(db, clock: FakeClock());
    pager = ToyListenPager(db, service);
  });

  tearDown(() => db.close());

  Future<void> seed(Map<String, int> uuidToTime, {String kind = 'play'}) async {
    for (final e in uuidToTime.entries) {
      await history.insertLocal(token, historyEvent(e.key, kind: kind, at: e.value));
    }
  }

  SnapshotPage<ListenItem, ListenKey> pageOf(
    SnapshotPageResult<ListenItem, ListenKey> r,
  ) => switch (r) {
    SnapshotPage<ListenItem, ListenKey>() => r,
    SnapshotExpired<ListenItem, ListenKey>() => fail('expected a page, got expired'),
  };

  List<String> uuids(SnapshotPage<ListenItem, ListenKey> p) =>
      [for (final i in p.items) i.eventUuid];

  /// Every page from the start; fails on expiry.
  Future<List<List<String>>> traverse(HistorySnapshotToken t, int limit) async {
    final pages = <List<String>>[];
    ListenKey? after;
    do {
      final p = pageOf(await pager.page(t, after, limit));
      pages.add(uuids(p));
      after = p.nextCursor;
    } while (after != null);
    return pages;
  }

  group('paging', () {
    test('an empty snapshot is one settled empty page', () async {
      final t = await service.capture('play');
      final p = pageOf(await pager.page(t, null, 50));
      expect(p.items, isEmpty);
      expect(p.nextCursor, isNull);
      expect(p.hasMore, isFalse);
    });

    test('fetches limit+1, returns limit, cursor = last returned key', () async {
      await seed({'a': 50, 'b': 40, 'c': 30, 'd': 20, 'e': 10});
      final t = await service.capture('play');
      final p = pageOf(await pager.page(t, null, 2));
      expect(uuids(p), ['a', 'b']);
      expect(p.hasMore, isTrue);
      expect(p.nextCursor, (occurredAt: 40, eventUuid: 'b'));
      expect(pager.fetchLimits, [3]);
    });

    test('an exactly full last page has no cursor', () async {
      await seed({'a': 40, 'b': 30, 'c': 20, 'd': 10});
      final t = await service.capture('play');
      expect(await traverse(t, 2), [
        ['a', 'b'],
        ['c', 'd'],
      ]);
    });

    test('ties on occurred_at traverse in manifest order without dup or skip',
        () async {
      // Manifest order (occurred_at DESC, event_uuid DESC), written by hand.
      await seed({
        'm': 100, 'k': 300, 'z': 100, 'b': 300, 'q': 200,
        'a': 100, 'x': 200, 'c': 300, 'n': 50,
      });
      await seed({'other': 999}, kind: 'clicked');
      final t = await service.capture('play');
      final pages = await traverse(t, 2);
      expect(pages, [
        ['k', 'c'],
        ['b', 'x'],
        ['q', 'z'],
        ['m', 'a'],
        ['n'],
      ]);
    });

    test('events inserted after capture stay outside the snapshot', () async {
      await seed({'a': 50, 'b': 40, 'c': 30});
      final t = await service.capture('play');
      final first = pageOf(await pager.page(t, null, 2));
      // A newer event and an old-timestamp pulled event, both after capture.
      await seed({'new': 60, 'late-old': 35});
      await history.applyPage(
        token,
        requestedAfter: 0,
        page: pulledPage([serverEvent(historyEvent('pulled', at: 5), 1)]),
      );
      final second = pageOf(await pager.page(t, first.nextCursor, 2));
      expect(uuids(first), ['a', 'b']);
      expect(uuids(second), ['c']);
      expect(second.hasMore, isFalse);
    });

    test('a non-positive limit is an argument error', () async {
      final t = await service.capture('play');
      expect(() => pager.page(t, null, 0), throwsArgumentError);
      expect(pager.fetches, 0);
    });

    test('a writer during the fetch is not seen: the page is one transaction',
        () async {
      await seed({'a': 50, 'b': 40});
      final t = await service.capture('play');
      final reached = Completer<void>();
      final release = Completer<void>();
      Future<int> timeOfA() async => (await db
              .customSelect(
                  "SELECT occurred_at FROM history_events WHERE event_uuid = 'a'")
              .getSingle())
          .read<int>('occurred_at');
      final reads = <int>[];
      final reading = service.readPage<int, int>(
        t,
        limit: 5,
        cursorOf: (i) => i,
        fetch: (_) async {
          reads.add(await timeOfA());
          reached.complete();
          await release.future;
          reads.add(await timeOfA());
          return reads;
        },
      );
      await reached.future;
      // Keep server version rewrites a's time in place.
      final writing = keepServerVersion(history, token, 'a', at: 1);
      release.complete();
      final r = await reading;
      await writing;
      expect(r, isA<SnapshotPage<int, int>>());
      expect(reads, [50, 50], reason: 'the writer waits for the page read');
      expect(await timeOfA(), 1, reason: 'the writer ran afterwards');
    });

    test('a writer right after the counter check cannot slip into the page',
        () async {
      await seed({'a': 50, 'b': 40});
      final t = await service.capture('play');
      // Started together: the counter re-read and the fetch share one
      // transaction, so the outcome is the old page or expiry, never the
      // rewritten payload under a valid token.
      final reading = pager.page(t, null, 5);
      final writing = keepServerVersion(history, token, 'a', at: 45);
      final r = await reading;
      await writing;
      switch (r) {
        case SnapshotPage<ListenItem, ListenKey>(:final items):
          expect(items.map((i) => '$i'), ['a@50', 'b@40']);
        case SnapshotExpired<ListenItem, ListenKey>():
          break;
      }
    });
  });

  group('expiry', () {
    test('Keep server version before the first page expires the snapshot',
        () async {
      await seed({'a': 50, 'b': 40});
      final t = await service.capture('play');
      await keepServerVersion(history, token, 'b', at: 60);
      expect(await pager.page(t, null, 5),
          isA<SnapshotExpired<ListenItem, ListenKey>>());
      expect(pager.fetches, 0, reason: 'an expired page runs no fetch');
    });

    test('Keep server version past page one stops the continuation', () async {
      await seed({'a': 50, 'b': 40, 'c': 30, 'd': 20});
      final t = await service.capture('play');
      final first = pageOf(await pager.page(t, null, 2));
      await keepServerVersion(history, token, 'd', at: 60);
      expect(await pager.page(t, first.nextCursor, 2),
          isA<SnapshotExpired<ListenItem, ListenKey>>());
      // A fresh capture pages the new order.
      expect(await traverse(await service.capture('play'), 2), [
        ['d', 'a'],
        ['b', 'c'],
      ]);
    });

    test('a no-op Keep server version (same payload) does not expire',
        () async {
      await seed({'a': 50});
      final t = await service.capture('play');
      await history.keepServerVersion(
          token, serverEvent(historyEvent('a', at: 50), 1));
      expect(await pager.page(t, null, 5),
          isA<SnapshotPage<ListenItem, ListenKey>>());
    });

    test('writes that change no carried counter do not expire', () async {
      await seed({'a': 50, 'b': 40});
      final t = await service.capture('play');
      await seed({'c': 60});
      await history.applyAck(token, ['a'], ['a']);
      await history.applyPage(
        token,
        requestedAfter: 0,
        page: pulledPage([serverEvent(historyEvent('p', at: 5), 1)]),
      );
      await history.recordFailure(token, 'b', reason: 'rejected');
      await SyncCursorStore(db).write(SyncStream.catalog, 42);
      // The token carries no catalog_attribution version: its counter is
      // not one of this snapshot's counters.
      await db.customStatement(
          "INSERT INTO local_counters (key, value) VALUES ('catalog_attribution', 9)");
      final p = pageOf(await pager.page(t, null, 5));
      expect(uuids(p), ['a', 'b']);
    });

    test('a carried catalogAttributionVersion is validated too', () async {
      await seed({'a': 50});
      await db.customStatement(
          "INSERT INTO local_counters (key, value) VALUES ('catalog_attribution', 3)");
      final captured = await service.capture('play');
      final t = HistorySnapshotToken(
        boundaryLocalId: captured.boundaryLocalId,
        historyContentVersion: captured.historyContentVersion,
        catalogAttributionVersion: 3,
        capturedNowUtcMs: captured.capturedNowUtcMs,
        filterKey: 'play',
      );
      expect(await pager.page(t, null, 5),
          isA<SnapshotPage<ListenItem, ListenKey>>());
      await db.customStatement(
          "UPDATE local_counters SET value = 4 WHERE key = 'catalog_attribution'");
      expect(await pager.page(t, null, 5),
          isA<SnapshotExpired<ListenItem, ListenKey>>());
    });

    test('a carried catalogAttributionVersion of 0 matches an absent counter',
        () async {
      await seed({'a': 50});
      final captured = await service.capture('play');
      final t = HistorySnapshotToken(
        boundaryLocalId: captured.boundaryLocalId,
        historyContentVersion: captured.historyContentVersion,
        catalogAttributionVersion: 0,
        capturedNowUtcMs: captured.capturedNowUtcMs,
        filterKey: 'play',
      );
      expect(await pager.page(t, null, 5),
          isA<SnapshotPage<ListenItem, ListenKey>>());
    });
  });
}
