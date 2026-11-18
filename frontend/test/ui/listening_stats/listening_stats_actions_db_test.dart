// Phase 9A.2b end to end over real Drift (exit proof "tap spies: exactly one
// `PlaybackRequests.submit` path, and no history created by the statistics
// side"; spec §4 para 2; SC-05, SC-10, SC-27; review 9-U03, 9-U11, 9-S06
// and 9-S07 unit halves). Real statistics and See all controllers, real
// pagers, `LibraryActions`, `PlaybackRequests` and click recorder; only the
// audio player is faked.
//
//  * Opening, Refresh, a range change, See all paging through more than
//    100 tied tracks and an expiry write no history row and leave the
//    history counter alone.
//  * A top-list track tap and a See all track tap each start a single-track
//    queue and record exactly one track click (the single emit site).
//  * Same-title tracks are two ranked entries, by uuid.
//  * Offline, the statistics load from local history, and the shared
//    offline gate refuses a remote-only track with no click.
import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/listening_stats/listening_ranking_controller.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/server_binding.dart';
import '../../repositories/catalog_seed.dart';
import '../../helpers/test_offline.dart';

const _now = 1800000000000;
const _hour = 3600000;

/// The audio player, faked: every activation succeeds.
class _Player extends QueuePlayer {
  final activated = <int>[];

  @override
  AudioState build() => const AudioState();

  @override
  Future<ActivationResult> activatePreparedSession(
    int sessionId,
    PlaybackTarget target, {
    required bool autoPlay,
    required int requestRevision,
  }) async {
    activated.add(sessionId);
    return ActivationResult.accepted;
  }

  @override
  Future<void> reportIssues(Iterable<Object?> issues,
      {bool publish = true}) async {}
}

String _key(StatsRankedCard c) => (c.entity.key as ValueKey<String>).value;

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _Player player;
  late CatalogSeed seed;
  late TestOffline offline;
  var seq = 0;

  Future<void> listen(String ref, double seconds) =>
      db.into(db.historyEvents).insert(
        HistoryEventsCompanion.insert(
          eventUuid: 'p-${(seq++).toString().padLeft(5, '0')}',
          kind: 'play',
          entityType: 'track',
          entityRef: ref,
          occurredAt: _now - _hour,
          secondsPlayed: Value(seconds),
          trackLength: const Value(200),
          pendingUpload: false,
        ),
      );

  setUp(() async {
    seq = 0;
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    seed = CatalogSeed(db);
    // One transaction: ~244 single inserts, one commit.
    await db.transaction(() async {
      await seed.artist(1, 'Ann');
      await seed.artist(2, 'Bea');
      await seed.album(10, artistId: 1, name: 'One');
      await seed.album(20, artistId: 2, name: 'Two');
      // Two leaders with the same title, then 120 tied tracks (100 s each).
      await seed.track('same-a', artistId: 1, albumId: 10, title: 'Same',
          downloaded: true);
      await seed.track('same-b', artistId: 2, albumId: 20, title: 'Same');
      await listen('same-a', 500);
      await listen('same-b', 400);
      for (var i = 0; i < 120; i++) {
        final uuid = 'tie-${i.toString().padLeft(3, '0')}';
        await seed.track(uuid, artistId: 1, albumId: 10, trackNumber: i + 2);
        await listen(uuid, 100);
      }
    });
    player = _Player();
    offline = TestOffline(false);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      queuePlayerProvider.overrideWith(() => player),
      offlineModeProvider.overrideWith(() => offline),
      clockProvider.overrideWithValue(FakeClock(startUtcMs: _now)),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Rows of history and the history-content counter, to compare.
  Future<(int, int?)> historyState() async {
    await pumpEventQueue();
    final rows = await db.select(db.historyEvents).get();
    final counter = await db
        .customSelect("SELECT value FROM local_counters "
            "WHERE key = 'history_content'")
        .getSingleOrNull();
    return (rows.length, counter?.read<int>('value'));
  }

  Future<List<(String, String)>> clicks() async {
    await pumpEventQueue();
    final rows = await (db.select(db.historyEvents)
          ..where((e) => e.kind.equals('clicked'))
          ..orderBy([(e) => OrderingTerm(expression: e.localId)]))
        .get();
    return [for (final r in rows) (r.entityType, r.entityRef)];
  }

  Future<List<String>> activatedQueue() async {
    final rows = await (db.select(db.queueSessionItems)
          ..where((i) => i.sessionId.equals(player.activated.last))
          ..orderBy([(i) => OrderingTerm(expression: i.position)]))
        .get();
    return [for (final r in rows) r.uuidId];
  }

  /// Waits until [check] holds on [l], or fails with [what].
  Future<void> until(Listenable l, bool Function() check, String what) {
    if (check()) return Future.value();
    final done = Completer<void>();
    void probe() {
      if (!done.isCompleted && check()) done.complete();
    }

    l.addListener(probe);
    return done.future
        .timeout(const Duration(seconds: 10), onTimeout: () => fail(what))
        .whenComplete(() => l.removeListener(probe));
  }

  Future<ListeningStatsControls> openStats() async {
    final c = container.read(listeningStatsControllerFactoryProvider)();
    addTearDown(c.dispose);
    await until(c, () => c.state is StatsReady && c.topLists != null,
        'stats never ready');
    return c;
  }

  ListeningRankingControls openRanking(StatsRankingKind kind,
      ListeningStatsControls stats) {
    final r = container.read(listeningRankingControllerFactoryProvider)(
      kind,
      stats.token!,
    );
    addTearDown(r.dispose);
    return r;
  }

  /// Pages [r] to its end (bounded), returning every card key.
  Future<List<String>> pageAll(ListeningRankingControls r) async {
    await until(r, () => r.cards != null || r.failed, 'no first page');
    var guard = 0;
    while (r.hasMore && !r.failed && !r.expired) {
      if (++guard > 5) fail('paging did not end');
      final before = r.cards!.length;
      r.loadMore();
      await until(r, () => r.cards!.length > before || r.failed || r.expired,
          'no further page');
    }
    expect(r.failed, isFalse);
    return [for (final c in r.cards!) _key(c)];
  }

  test('opening, Refresh, a range change and paging >100 tied tracks write '
      'no history and leave the history counter alone', () async {
    final before = await historyState();
    final stats = await openStats();
    stats.refresh();
    await until(stats, () => stats.state is StatsReady, 'refresh');
    stats.setRange(StatsRange.allTime);
    await until(stats, () => stats.state is StatsReady, 'range');
    final ranking = openRanking(StatsRankingKind.tracks, stats);
    final keys = await pageAll(ranking);
    expect(keys, hasLength(122));
    expect(keys.toSet(), hasLength(122), reason: 'no repeat');
    expect(keys.take(2), ['track:same-a', 'track:same-b']);
    expect(keys.skip(2), [
      for (var i = 0; i < 120; i++) 'track:tie-${i.toString().padLeft(3, '0')}',
    ], reason: 'ties by uuid, complete, no gap');
    expect([for (final c in ranking.cards!) c.rank],
        [for (var r = 1; r <= 122; r++) r]);
    expect(await historyState(), before);
    expect(player.activated, isEmpty);
  });

  test('page 1 of See all starts with the top list it came from', () async {
    final stats = await openStats();
    final ranking = openRanking(StatsRankingKind.tracks, stats);
    await until(ranking, () => ranking.cards != null, 'no first page');
    expect(ranking.cards!.take(10).map(_key),
        stats.topLists!.tracks.map(_key));
  });

  test('a rename after the snapshot expires See all: the page keeps what it '
      'shows and offers Refresh; no history is written', () async {
    final stats = await openStats();
    final ranking = openRanking(StatsRankingKind.tracks, stats);
    await until(ranking, () => ranking.cards != null, 'no first page');
    final shown = ranking.cards!.map(_key).toList();
    final before = await historyState();
    await (db.update(db.trackmetadata)
          ..where((t) => t.uuidId.equals('tie-000')))
        .write(const TrackmetadataCompanion(title: Value('Renamed')));
    ranking.loadMore();
    await until(ranking, () => ranking.expired, 'never expired');
    expect(ranking.cards!.map(_key), shown);
    expect(ranking.notice, SnapshotStaleness.historyChanged);
    expect(await historyState(), before);
  });

  test('a top-list track tap and a See all track tap each start a '
      'single-track queue with exactly one track click', () async {
    final stats = await openStats();
    final top = (stats.topLists!.tracks[1].entity as TrackEntity).track;
    expect(top.uuidId, 'same-b');
    expect(await stats.playTrack(top), isA<Accepted>());
    expect(await clicks(), [('track', 'same-b')]);
    expect(await activatedQueue(), ['same-b']);

    final ranking = openRanking(StatsRankingKind.tracks, stats);
    await until(ranking, () => ranking.cards != null, 'no first page');
    final tie = (ranking.cards![2].entity as TrackEntity).track;
    expect(await ranking.playTrack(tie), isA<Accepted>());
    expect(await clicks(), [('track', 'same-b'), ('track', tie.uuidId)]);
    expect(await activatedQueue(), [tie.uuidId]);
    expect(player.activated, hasLength(2));
  });

  test('same-title tracks are two ranked entries, by uuid', () async {
    final stats = await openStats();
    final tracks = stats.topLists!.tracks;
    expect(tracks.take(2).map(_key), ['track:same-a', 'track:same-b']);
    expect(tracks.take(2).map((c) => (c.entity as TrackEntity).track.title),
        ['Same', 'Same']);
  });

  test('offline: the statistics load from local history', () async {
    offline = TestOffline(true);
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      queuePlayerProvider.overrideWith(() => player),
      offlineModeProvider.overrideWith(() => offline),
      clockProvider.overrideWithValue(FakeClock(startUtcMs: _now)),
    ]);
    final stats = await openStats();
    final ready = stats.state as StatsReady;
    expect(ready.hasHistory, isTrue);
    expect(ready.stats.totals.listeningSeconds, 500 + 400 + 120 * 100);
    expect(stats.topLists!.tracks.first.unavailable, isFalse);
    // A remote-only track is refused by the shared offline gate: nothing
    // queued, no click.
    final b = (stats.topLists!.tracks[1].entity as TrackEntity).track;
    expect(b.uuidId, 'same-b');
    expect(await stats.playTrack(b), isA<RejectedUnplayableOffline>());
    expect(await clicks(), isEmpty);
    expect(player.activated, isEmpty);
  });
}
