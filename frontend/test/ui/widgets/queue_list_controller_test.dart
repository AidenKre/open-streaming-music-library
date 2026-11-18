import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:frontend/ui/widgets/queue_list_controller.dart';

import '../fake_player_controls.dart';
import '../../helpers/server_binding.dart';
import '../../helpers/library_seed.dart' show SeedTrack, seedLibrary;
import '../../helpers/test_offline.dart';

/// The full player's queue list paging, now in a controller (real in-memory
/// queue tables; only the player input is faked).
void main() {
  late AppDatabase db;
  late QueueRepository repo;
  late FakePlayerControls player;
  late TestOffline offline;
  late ProviderContainer c;
  late QueueListControls list;

  Future<int> session(int n, {Set<int> downloaded = const {}}) async {
    await seedLibrary(db, [
      for (var i = 0; i < n; i++)
        SeedTrack(
          uuid: 't${i.toString().padLeft(3, '0')}',
          title: 'Track $i',
          artistId: 1,
          artist: 'A',
          albumId: 1,
          album: 'X',
          trackNumber: i + 1,
          downloaded: downloaded.contains(i),
        ),
    ]);
    return repo.createSessionFromExplicitList(
      sourceType: 'test',
      trackUuids: [for (var i = 0; i < n; i++) 't${i.toString().padLeft(3, '0')}'],
    );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    repo = QueueRepository(db);
    player = FakePlayerControls();
    offline = TestOffline(false);
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        queueRepositoryProvider.overrideWithValue(repo),
        playerControlsProvider.overrideWithValue(player),
        offlineModeProvider.overrideWith(() => offline),
      ],
    );
    c.read(offlineModeProvider);
    list = c.read(queueListControllerFactoryProvider)();
  });

  tearDown(() async {
    list.dispose();
    c.dispose();
    await db.close();
  });

  test('a first look plans an initial load around the current item', () async {
    final s = await session(300);
    expect(
      list.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 100, totalCount: 300),
      QueueReloadKind.initial,
    );
    await list.loadInitial(
      sessionId: s, expectedQueueVersion: 1, currentPlayPosition: 100, totalCount: 300,
    );
    expect(list.startPlayPosition, 60); // 40 before the current item
    expect(list.rows, hasLength(101)); // 40 before + current + 60 after
    expect(list.rows.first.entry.track.uuidId, 't060');
    expect(list.hasMoreBefore, isTrue);
    expect(list.hasMoreAfter, isTrue);
    expect(list.shouldScrollToCurrent, isTrue);
    // Nothing changed: no new load.
    expect(
      list.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 100, totalCount: 300),
      QueueReloadKind.none,
    );
  });

  test('paging after and before grows the window contiguously', () async {
    final s = await session(300);
    list.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 100, totalCount: 300);
    await list.loadInitial(
      sessionId: s, expectedQueueVersion: 1, currentPlayPosition: 100, totalCount: 300,
    );
    await list.loadAfter(totalCount: 300);
    expect(list.rows, hasLength(181));
    expect(list.rows.last.entry.track.uuidId, 't240');
    final prepended = await list.loadBefore(totalCount: 300);
    expect(prepended, 60);
    expect(list.startPlayPosition, 0);
    expect(list.hasMoreBefore, isFalse);
    expect(list.rows.first.entry.track.uuidId, 't000');
  });

  test('reloadVisible re-anchors after an edit before the anchor', () async {
    final s = await session(300);
    list.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 100, totalCount: 300);
    await list.loadInitial(
      sessionId: s, expectedQueueVersion: 1, currentPlayPosition: 100, totalCount: 300,
    );
    // Window starts at 60; anchor on local row 30 = play position 90 (t090).
    expect(list.rows[30].entry.track.uuidId, 't090');
    // Remove an item BEFORE the anchor (position 70): t090 moves to 89.
    final removed = (await repo.getPlaybackEntries(s, startPlayPosition: 70, limit: 1)).single;
    await repo.removeItem(s, removed.itemId);
    expect(
      list.plan(sessionId: s, queueVersion: 2, currentPlayPosition: 100, totalCount: 299),
      QueueReloadKind.visible,
    );
    final newIndex = await list.reloadVisible(
      sessionId: s, expectedQueueVersion: 2, currentPlayPosition: 99,
      totalCount: 299, anchorLocalIndex: 30,
    );
    expect(list.startPlayPosition, 59, reason: 'window shifts with the anchor');
    expect(newIndex, 30);
    expect(list.rows[newIndex!].entry.track.uuidId, 't090');
  });

  test('reloadVisible reports a removed anchor as null', () async {
    final s = await session(300);
    list.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 100, totalCount: 300);
    await list.loadInitial(
      sessionId: s, expectedQueueVersion: 1, currentPlayPosition: 100, totalCount: 300,
    );
    final anchor = list.rows[30].entry;
    await repo.removeItem(s, anchor.itemId);
    list.plan(sessionId: s, queueVersion: 2, currentPlayPosition: 100, totalCount: 299);
    final newIndex = await list.reloadVisible(
      sessionId: s, expectedQueueVersion: 2, currentPlayPosition: 99,
      totalCount: 299, anchorLocalIndex: 30,
    );
    expect(newIndex, isNull);
    expect(list.rows.any((r) => r.entry.itemId == anchor.itemId), isFalse);
  });

  test('loadBefore at the start of the queue loads nothing', () async {
    final s = await session(10);
    list.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 0, totalCount: 10);
    await list.loadInitial(
      sessionId: s, expectedQueueVersion: 1, currentPlayPosition: 0, totalCount: 10,
    );
    expect(list.hasMoreBefore, isFalse);
    expect(await list.loadBefore(totalCount: 10), 0);
    expect(list.startPlayPosition, 0);
  });

  test('a load for an outdated queue version is dropped', () async {
    final s = await session(10);
    list.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 0, totalCount: 10);
    // The queue changes before the planned load runs.
    list.plan(sessionId: s, queueVersion: 2, currentPlayPosition: 0, totalCount: 10);
    await list.loadInitial(
      sessionId: s, expectedQueueVersion: 1, currentPlayPosition: 0, totalCount: 10,
    );
    expect(list.rows, isEmpty);
  });

  test('row availability comes from PlaybackAvailability (offline)', () async {
    final s = await session(2, downloaded: {0});
    list.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 0, totalCount: 2);
    await list.loadInitial(
      sessionId: s, expectedQueueVersion: 1, currentPlayPosition: 0, totalCount: 2,
    );
    expect(list.rows.map((r) => r.availability.canPlay), [true, true]);
    offline.set(true);
    expect(list.rows.map((r) => r.availability), [
      PlaybackAvailability.of(offline: true, downloaded: 1, total: 1),
      PlaybackAvailability.of(offline: true, downloaded: 0, total: 1),
    ]);
  });

  test('a failing row action is logged, not an unhandled error', () async {
    final failing = QueueListController(
      repository: repo,
      player: _ThrowingPlayer(),
      isOffline: () => false,
    );
    addTearDown(failing.dispose);
    failing.tapRow(1);
    failing.remove(2);
    await Future<void>.delayed(Duration.zero);
  });

  test('row tap and remove go to PlayerControls', () async {
    list.tapRow(7);
    list.remove(9);
    expect(player.calls, ['skipTo 7', 'remove 9']);
  });

  test('a failed initial load does not automatically retry on every rebuild',
      () async {
    final failing = QueueListController(
      repository: _FailingQueueRepository(db),
      player: player,
      isOffline: () => false,
    );
    addTearDown(failing.dispose);
    expect(failing.plan(sessionId: 1, queueVersion: 1,
        currentPlayPosition: 0, totalCount: 1), QueueReloadKind.initial);
    await failing.loadInitial(sessionId: 1, expectedQueueVersion: 1,
        currentPlayPosition: 0, totalCount: 1);
    expect(failing.error, isA<StateError>());
    expect(failing.isInitialLoad, isFalse);
    // FullPlayer calls plan() on each notification. A failure must remain
    // settled until an explicit retry or a changed queue, not start a
    // fetch -> notify -> fetch loop at the display refresh rate.
    expect(failing.plan(sessionId: 1, queueVersion: 1,
        currentPlayPosition: 0, totalCount: 1), QueueReloadKind.none);
    expect(failing.plan(sessionId: 1, queueVersion: 2,
        currentPlayPosition: 0, totalCount: 2), QueueReloadKind.initial,
        reason: 'a changed queue can recover without a manual retry');
  });

  // Pre-merge D4-01: the error of one failed page read went away only with
  // the next initial or visible load.
  for (final before in [false, true]) {
    final which = before ? 'earlier' : 'later';
    test('a read of $which rows that fails and then succeeds clears the '
        'error', () async {
      final flaky = _FailNextPageRepository(db);
      final l = QueueListController(
          repository: flaky, player: player, isOffline: () => false);
      addTearDown(l.dispose);
      final s = await session(300);
      l.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 100,
          totalCount: 300);
      await l.loadInitial(sessionId: s, expectedQueueVersion: 1,
          currentPlayPosition: 100, totalCount: 300);
      expect(l.rows, hasLength(101));
      Future<void> page() async => before
          ? await l.loadBefore(totalCount: 300)
          : await l.loadAfter(totalCount: 300);

      flaky.failNextPage = true;
      await page();
      expect(l.error, isA<StateError>());
      expect(l.failedPage, before ? QueuePage.before : QueuePage.after,
          reason: 'Retry can repeat this read in place');
      expect(l.rows, hasLength(101), reason: 'the rows stay');

      await page();
      expect(l.rows.length, greaterThan(101), reason: 'the page loaded');
      expect(l.error, isNull);
      expect(l.failedPage, isNull);
    });
  }

  test('a failed visible reload is not a failed page: its error stays when '
      'more rows load, until a reload succeeds', () async {
    final flaky = _FailNextPageRepository(db);
    final l = QueueListController(
        repository: flaky, player: player, isOffline: () => false);
    addTearDown(l.dispose);
    final s = await session(300);
    l.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 100,
        totalCount: 300);
    await l.loadInitial(sessionId: s, expectedQueueVersion: 1,
        currentPlayPosition: 100, totalCount: 300);
    l.plan(sessionId: s, queueVersion: 2, currentPlayPosition: 100,
        totalCount: 300);
    flaky.failNextPage = true;
    await l.reloadVisible(sessionId: s, expectedQueueVersion: 2,
        currentPlayPosition: 100, totalCount: 300, anchorLocalIndex: 30);
    expect(l.error, isA<StateError>());
    expect(l.failedPage, isNull);

    await l.loadAfter(totalCount: 300);
    expect(l.rows.length, greaterThan(101), reason: 'the page loaded');
    expect(l.error, isA<StateError>(),
        reason: 'the rows on screen were not re-read yet');

    await l.loadInitial(sessionId: s, expectedQueueVersion: 2,
        currentPlayPosition: 100, totalCount: 300);
    expect(l.error, isNull);
  });

  // Section 6 #7 (U20-FE-QUEUE-B-11): a slow read cannot overwrite a newer
  // one. A skip can move the current item out of the window at an
  // unchanged queue version while a visible reload is still reading.
  test('a visible reload that finishes after a newer initial load does not '
      'overwrite it', () async {
    final gated = _GatedPageRepository(db);
    final gatedList = QueueListController(
        repository: gated, player: player, isOffline: () => false);
    addTearDown(gatedList.dispose);
    final s = await session(300);
    gatedList.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 100,
        totalCount: 300);
    await gatedList.loadInitial(sessionId: s, expectedQueueVersion: 1,
        currentPlayPosition: 100, totalCount: 300);
    expect(gatedList.startPlayPosition, 60);

    // A queue edit: the visible window is re-read; its page read is slow.
    expect(gatedList.plan(sessionId: s, queueVersion: 2,
        currentPlayPosition: 100, totalCount: 300), QueueReloadKind.visible);
    gated.holdNextPage = Completer<void>();
    final slow = gatedList.reloadVisible(sessionId: s, expectedQueueVersion: 2,
        currentPlayPosition: 100, totalCount: 300, anchorLocalIndex: 30);
    await gated.pageHeld.future;

    // Meanwhile playback moves far ahead: a newer initial load.
    expect(gatedList.plan(sessionId: s, queueVersion: 2,
        currentPlayPosition: 250, totalCount: 300), QueueReloadKind.initial);
    await gatedList.loadInitial(sessionId: s, expectedQueueVersion: 2,
        currentPlayPosition: 250, totalCount: 300);
    expect(gatedList.startPlayPosition, 210);

    var notified = 0;
    gatedList.addListener(() => notified++);
    gated.holdNextPage!.complete();
    expect(await slow, isNull, reason: 'the slow reload was superseded');
    expect(notified, greaterThan(0),
        reason: 'its flag clears and the view plans again');
    expect(gatedList.startPlayPosition, 210);
    expect(gatedList.rows.first.entry.track.uuidId, 't210');
    expect(gatedList.rows.map((r) => r.entry.playPosition),
        contains(250), reason: 'the current item stays in the window');
    expect(gatedList.isViewportReload, isFalse);
  });

  test('a page read that finishes after a newer initial load does not '
      'extend it', () async {
    final gated = _GatedPageRepository(db);
    final gatedList = QueueListController(
        repository: gated, player: player, isOffline: () => false);
    addTearDown(gatedList.dispose);
    final s = await session(300);
    gatedList.plan(sessionId: s, queueVersion: 1, currentPlayPosition: 100,
        totalCount: 300);
    await gatedList.loadInitial(sessionId: s, expectedQueueVersion: 1,
        currentPlayPosition: 100, totalCount: 300);
    gated.holdNextPage = Completer<void>();
    final slow = gatedList.loadAfter(totalCount: 300);
    await gated.pageHeld.future;
    expect(gatedList.plan(sessionId: s, queueVersion: 1,
        currentPlayPosition: 250, totalCount: 300), QueueReloadKind.initial);
    await gatedList.loadInitial(sessionId: s, expectedQueueVersion: 1,
        currentPlayPosition: 250, totalCount: 300);
    gated.holdNextPage!.complete();
    await slow;
    expect(gatedList.startPlayPosition, 210);
    expect(gatedList.rows.map((r) => r.entry.playPosition),
        [for (var p = 210; p < 300; p++) p],
        reason: 'one contiguous window, the newer one');
  });
}

/// Fails the next page read once, when asked to.
class _FailNextPageRepository extends QueueRepository {
  _FailNextPageRepository(super.db);
  bool failNextPage = false;

  @override
  Future<List<QueueTrackEntry>> getSessionTracksPage(int sessionId, {
    required int startPlayPosition,
    required int limit,
  }) {
    if (failNextPage) {
      failNextPage = false;
      return Future.error(StateError('temporary read failure'));
    }
    return super.getSessionTracksPage(sessionId,
        startPlayPosition: startPlayPosition, limit: limit);
  }
}

/// Holds the next page read until the test releases it.
class _GatedPageRepository extends QueueRepository {
  _GatedPageRepository(super.db);

  Completer<void>? holdNextPage;
  final pageHeld = Completer<void>();

  @override
  Future<List<QueueTrackEntry>> getSessionTracksPage(int sessionId, {
    required int startPlayPosition,
    required int limit,
  }) async {
    final rows = await super.getSessionTracksPage(sessionId,
        startPlayPosition: startPlayPosition, limit: limit);
    final hold = holdNextPage;
    if (hold != null && !pageHeld.isCompleted) {
      pageHeld.complete();
      await hold.future;
    }
    return rows;
  }
}

class _FailingQueueRepository extends QueueRepository {
  _FailingQueueRepository(super.db);

  @override
  Future<List<QueueTrackEntry>> getSessionTracksPage(int sessionId, {
    required int startPlayPosition,
    required int limit,
  }) async => throw StateError('queue read failed');
}

class _ThrowingPlayer extends FakePlayerControls {
  @override
  Future<void> skipToItem(int itemId) => Future.error(StateError('engine'));
  @override
  Future<void> removeFromQueue(int itemId) => Future.error(StateError('db'));
}
