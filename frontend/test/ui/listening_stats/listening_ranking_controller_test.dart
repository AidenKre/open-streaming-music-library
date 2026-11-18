// Phase 9A.2b (spec §3 paras 1, 3, 5: "See all pages of 50 grouped
// entities using deterministic rank+ID cursors against the same immutable
// query snapshot; invalidate and request refresh"; SC-10; 9A.1c hand-over;
// review 9-S06 unit half, 9-U03): the "See all" ranking controller over the
// real 9A.1c pagers, with the snapshot service, statistics repository and
// freshness faked so every page is answered by the test.
//
//  * It pages the token it was given (the statistics page's snapshot), 50
//    at a time, one request at a time; ranks continue across pages.
//  * Expired: what is loaded stays, paging stops, the notice says history
//    changed; nothing reloads until Refresh, which captures a new token of
//    the same range (with the attribution counter) and starts at page 1.
//  * A failure, a `RankingOrderError` included, is an error with Retry
//    (one repeat per call), never an empty list and never an automatic
//    retry.
//  * New listens after the token: the new-activity notice (kinds {'play'}).
//  * Loaded cards whose entity no longer resolves are unavailable.
//  * A track tap is one single-track play through `LibraryActions`.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/listening_stats/listening_ranking_controller.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';

import '../fake_library_actions.dart';
import 'stats_model_fakes.dart';

typedef TrackEntry = RankedPageEntry<TrackUI, String>;
typedef TrackCursor = RankCursor<String>;

TrackUI track(String uuid, {String? title}) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: title ?? 'Song $uuid',
  artist: 'Ann',
  artistId: 1,
  albumId: 10,
  duration: 180,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

/// Ranked track entries [from]…[to] (inclusive), uuids `t-000`…, in strict
/// rank order: rank r has (2000 - r) seconds and one qualified play.
List<TrackEntry> tracks(int from, int to, {String? title}) => [
  for (var r = from; r <= to; r++)
    TrackEntry(
      RankedEntry(
        entity: track('t-${r.toString().padLeft(3, '0')}', title: title),
        listeningSeconds: (2000 - r).toDouble(),
        qualifiedPlays: 1,
      ),
      TrackCursor(
        listeningMicros: (2000 - r) * 1000000,
        qualifiedPlays: 1,
        key: 't-${r.toString().padLeft(3, '0')}',
      ),
    ),
];

SnapshotPage<TrackEntry, TrackCursor> page(List<TrackEntry> items,
        {bool more = false}) =>
    SnapshotPage(items, more ? items.last.cursor : null);

const expired = SnapshotExpired<TrackEntry, TrackCursor>();

String keyOf(StatsRankedCard c) => (c.entity.key as ValueKey<String>).value;

void main() {
  late FakeSnapshotService snapshots;
  late FakeStatsRepository repo;
  late FakeFreshness freshness;
  late FakeLibraryActions actions;
  late ProviderContainer container;
  late HistorySnapshotToken token;
  late ListeningRankingControls c;
  late int notifications;

  ListeningRankingControls open(StatsRankingKind kind) {
    final made = container.read(listeningRankingControllerFactoryProvider)(
      kind,
      token,
    );
    notifications = 0;
    made.addListener(() => notifications++);
    return made;
  }

  setUp(() {
    snapshots = FakeSnapshotService();
    repo = FakeStatsRepository();
    freshness = FakeFreshness();
    actions = FakeLibraryActions();
    container = ProviderContainer(
      overrides: [
        historySnapshotServiceProvider.overrideWithValue(snapshots),
        listeningStatsRepositoryProvider.overrideWithValue(repo),
        snapshotFreshnessProvider.overrideWithValue(freshness),
        libraryActionsProvider.overrideWithValue(actions),
      ],
    );
    token = tokenFor(StatsRange.last30Days, attribution: 5);
    c = open(StatsRankingKind.tracks);
  });

  tearDown(() {
    c.dispose();
    container.dispose();
  });

  Future<void> settle() => pumpEventQueue();

  /// Answers the last page read with [result].
  Future<void> answer(Object result) async {
    snapshots.pageReads.last.done.complete(result);
    await settle();
  }

  /// The cursor the last page read would read after (via the pager's own
  /// fetch, recorded by the fake repository).
  Future<Object?> lastAfter() async {
    await snapshots.pageReads.last.fetch(1);
    return repo.rankingCalls.last.$2;
  }

  group('paging the given snapshot', () {
    test('opens on page 1 of the given token, 50 entities per page, without '
        'capturing a new token', () async {
      expect(c.kind, StatsRankingKind.tracks);
      expect(c.range, StatsRange.last30Days, reason: 'the token\'s range');
      expect(c.cards, isNull, reason: 'loading');
      expect(c.failed, isFalse);
      expect(snapshots.captures, isEmpty);
      final read = snapshots.pageReads.single;
      expect(identical(read.token, token), isTrue);
      expect(read.limit, 50);
      expect(await lastAfter(), isNull);
    });

    test('page 1: cards in rank order, ranked 1…50, with their numbers',
        () async {
      await answer(page(tracks(1, 50), more: true));
      expect(c.cards!.map(keyOf).take(2), ['track:t-001', 'track:t-002']);
      expect(c.cards!.map((x) => x.rank), [for (var r = 1; r <= 50; r++) r]);
      expect(c.cards!.first.listeningSeconds, 1999);
      expect(c.cards!.first.qualifiedPlays, 1);
      expect(c.hasMore, isTrue);
      expect(c.expired, isFalse);
      expect(notifications, greaterThan(0));
    });

    test('loadMore reads after the last cursor, one request at a time; '
        'ranks continue; the last page ends paging', () async {
      await answer(page(tracks(1, 50), more: true));
      c.loadMore();
      c.loadMore();
      expect(snapshots.pageReads, hasLength(2), reason: 'one in flight');
      expect(identical(snapshots.pageReads.last.token, token), isTrue);
      expect(await lastAfter(), tracks(50, 50).single.cursor);
      await answer(page(tracks(51, 53)));
      expect(c.cards, hasLength(53));
      expect(c.cards!.skip(50).map((x) => x.rank), [51, 52, 53]);
      expect(c.hasMore, isFalse);
      c.loadMore();
      expect(snapshots.pageReads, hasLength(2));
    });

    test('same-title tracks stay two cards, one per uuid', () async {
      await answer(page(tracks(1, 2, title: 'Same')));
      expect(c.cards!.map(keyOf), ['track:t-001', 'track:t-002']);
      expect(c.cards!.map((x) => (x.entity as TrackEntity).track.title),
          ['Same', 'Same']);
    });

    test('an empty first page is the settled end (not loading, no more)',
        () async {
      await answer(page(const []));
      expect(c.cards, isEmpty);
      expect(c.hasMore, isFalse);
      expect(c.expired, isFalse);
    });

    test('artists page through the artist ranking', () async {
      c.dispose();
      c = open(StatsRankingKind.artists);
      await snapshots.pageReads.last.fetch(1);
      expect(repo.rankingCalls.last.$1, 'artists');
      await answer(SnapshotPage<RankedPageEntry<ArtistUI, int>,
          RankCursor<int>>([
        const RankedPageEntry(
          RankedEntry(
            entity: ArtistUI(id: 7, name: 'Ann'),
            listeningSeconds: 60,
            qualifiedPlays: 2,
          ),
          RankCursor(listeningMicros: 60000000, qualifiedPlays: 2, key: 7),
        ),
      ], null));
      expect(c.cards!.map(keyOf), ['artist:7']);
    });
  });

  group('expiry', () {
    test('an expired first page: nothing to show, says history changed, no '
        'further reads, no reload', () async {
      await answer(expired);
      expect(c.expired, isTrue);
      expect(c.cards, isEmpty);
      expect(c.hasMore, isFalse);
      expect(c.notice, SnapshotStaleness.historyChanged);
      c.loadMore();
      await settle();
      expect(snapshots.pageReads, hasLength(1));
      expect(snapshots.captures, isEmpty, reason: 'never silently reloads');
    });

    test('expiry on a later page keeps what is loaded and stops paging',
        () async {
      await answer(page(tracks(1, 50), more: true));
      c.loadMore();
      await answer(expired);
      expect(c.cards, hasLength(50));
      expect(c.cards!.first.rank, 1);
      expect(c.expired, isTrue);
      expect(c.hasMore, isFalse);
      expect(c.notice, SnapshotStaleness.historyChanged);
      c.loadMore();
      expect(snapshots.pageReads, hasLength(2));
    });

    test('Refresh captures a new token of the same range with the '
        'attribution counter and starts again at page 1', () async {
      await answer(expired);
      final epoch = c.snapshotEpoch;
      c.refresh();
      expect(c.cards, isNull);
      expect(c.expired, isFalse);
      expect(c.notice, SnapshotStaleness.fresh);
      expect(c.snapshotEpoch, isNot(epoch));
      final cap = snapshots.captures.single;
      expect(cap.filterKey, StatsRange.last30Days);
      expect(cap.attribution, isTrue);
      final fresh = tokenFor(StatsRange.last30Days, boundary: 99,
          attribution: 6);
      cap.done.complete(fresh);
      await settle();
      expect(snapshots.pageReads, hasLength(2));
      expect(identical(snapshots.pageReads.last.token, fresh), isTrue);
      expect(await lastAfter(), isNull);
      await answer(page(tracks(1, 3)));
      expect(c.cards!.map((x) => x.rank), [1, 2, 3]);
    });

    test('a page of the old snapshot answering after Refresh is dropped',
        () async {
      await answer(page(tracks(1, 50), more: true));
      c.loadMore();
      final old = snapshots.pageReads.last;
      c.refresh();
      old.done.complete(page(tracks(51, 60)));
      await settle();
      expect(c.cards, isNull);
    });
  });

  group('failures', () {
    test('a failed first page is an error, not an empty list; Retry repeats '
        'it once', () async {
      snapshots.pageReads.last.done.completeError(StateError('db'));
      await settle();
      expect(c.failed, isTrue);
      expect(c.cards, isNull);
      c.retry();
      expect(c.failed, isFalse);
      expect(snapshots.pageReads, hasLength(2));
      expect(identical(snapshots.pageReads.last.token, token), isTrue);
      expect(await lastAfter(), isNull);
      c.retry();
      expect(snapshots.pageReads, hasLength(2), reason: 'not failed now');
    });

    test('a failed later page keeps the loaded cards; Retry repeats the '
        'same cursor', () async {
      await answer(page(tracks(1, 50), more: true));
      c.loadMore();
      snapshots.pageReads.last.done.completeError(StateError('db'));
      await settle();
      expect(c.failed, isTrue);
      expect(c.cards, hasLength(50));
      c.loadMore();
      expect(snapshots.pageReads, hasLength(2), reason: 'Retry, not loadMore');
      c.retry();
      expect(snapshots.pageReads, hasLength(3));
      expect(await lastAfter(), tracks(50, 50).single.cursor);
    });

    test('a ranking-order error is an error with Retry, never an empty list '
        'and never retried by itself', () async {
      await answer(page(tracks(1, 50), more: true));
      c.loadMore();
      // The next page does not advance past rank 50: the pager refuses it.
      await answer(page(tracks(40, 45)));
      expect(c.failed, isTrue);
      expect(c.cards, hasLength(50));
      expect(c.hasMore, isTrue, reason: 'the rest is still unread');
      await settle();
      expect(snapshots.pageReads, hasLength(2));
    });

    test('a ranking-order error on page 1 is an error, not an empty list',
        () async {
      await answer(page([...tracks(2, 2), ...tracks(1, 1)]));
      expect(c.failed, isTrue);
      expect(c.cards, isNull);
    });

    test('a failed capture on Refresh is an error; Retry captures again',
        () async {
      await answer(expired);
      c.refresh();
      snapshots.captures.single.done.completeError(StateError('db'));
      await settle();
      expect(c.failed, isTrue);
      c.retry();
      expect(snapshots.captures, hasLength(2));
    });
  });

  group('freshness', () {
    test('watches the token for new listens only', () async {
      await answer(page(tracks(1, 3)));
      final w = freshness.watches.single;
      expect(identical(w.token, token), isTrue);
      expect(w.kinds, {'play'});
      w.emit(SnapshotStaleness.newActivity);
      await settle();
      expect(c.notice, SnapshotStaleness.newActivity);
      expect(c.cards, hasLength(3), reason: 'nothing reorders');
      expect(snapshots.pageReads, hasLength(1));
    });

    test('a history change reported by the watch shows the notice; Refresh '
        'cancels the watch', () async {
      await answer(page(tracks(1, 3)));
      final w = freshness.watches.single;
      w.emit(SnapshotStaleness.historyChanged);
      await settle();
      expect(c.notice, SnapshotStaleness.historyChanged);
      c.refresh();
      expect(w.cancelled, isTrue);
    });
  });

  group('unavailable cards', () {
    test('review r1 F1: a card known to be unavailable stays unavailable '
        'across loadMore until the new watch emits; new cards are not '
        'unavailable meanwhile', () async {
      await answer(page(tracks(1, 50), more: true));
      repo.currentWatches.single.emit(CurrentStatsEntities(
        tracks: {
          for (final e in tracks(2, 50))
            e.entry.entity.uuidId: e.entry.entity,
        },
        artists: const {},
        albums: const {},
      ));
      await settle();
      expect(c.cards!.first.unavailable, isTrue);
      c.loadMore();
      await answer(page(tracks(51, 52)));
      expect(repo.currentWatches, hasLength(2));
      expect(c.cards!.first.unavailable, isTrue,
          reason: 'what is known stays shown until the new watch says more');
      expect(c.cards!.skip(1).any((x) => x.unavailable), isFalse);
      expect(c.cards!.map((x) => x.rank),
          [for (var r = 1; r <= 52; r++) r]);
    });

    test('the loaded ids are watched; one that no longer resolves becomes '
        'unavailable with its rank and numbers', () async {
      await answer(page(tracks(1, 2)));
      final w = repo.currentWatches.single;
      expect(w.trackUuids, ['t-001', 't-002']);
      w.emit(CurrentStatsEntities(
        tracks: {'t-002': track('t-002')},
        artists: const {},
        albums: const {},
      ));
      await settle();
      expect(c.cards!.map((x) => x.unavailable), [true, false]);
      expect(c.cards!.first.rank, 1);
      expect(c.cards!.first.listeningSeconds, 1999);
    });

    test('a further page re-watches every loaded id; the old watch is '
        'cancelled', () async {
      await answer(page(tracks(1, 50), more: true));
      c.loadMore();
      await answer(page(tracks(51, 52)));
      expect(repo.currentWatches, hasLength(2));
      expect(repo.currentWatches.first.cancelled, isTrue);
      expect(repo.currentWatches.last.trackUuids, hasLength(52));
    });
  });

  group('taps and history', () {
    test('a track tap plays that one track through LibraryActions', () async {
      await answer(page(tracks(1, 2)));
      final t = (c.cards![1].entity as TrackEntity).track;
      expect(await c.playTrack(t), isA<Accepted>());
      expect(actions.calls, ['playFromList t-002 @0 listening_stats']);
    });

    test('paging, expiry and Refresh request no playback', () async {
      await answer(page(tracks(1, 50), more: true));
      c.loadMore();
      await answer(expired);
      c.refresh();
      snapshots.captures.single.done.complete(
          tokenFor(StatsRange.last30Days, attribution: 6));
      await settle();
      await answer(page(tracks(1, 2)));
      expect(actions.calls, isEmpty);
    });
  });

  test('review r1 F5: Retry after dispose does nothing', () async {
    snapshots.pageReads.last.done.completeError(StateError('db'));
    await settle();
    expect(c.failed, isTrue);
    c.dispose();
    expect(() => c.retry(), returnsNormally);
    expect(snapshots.pageReads, hasLength(1));
    c = open(StatsRankingKind.tracks); // for tearDown
  });

  test('dispose cancels the watches; a late page is ignored', () async {
    await answer(page(tracks(1, 50), more: true));
    c.loadMore();
    final pending = snapshots.pageReads.last;
    final w = freshness.watches.single;
    final cw = repo.currentWatches.single;
    c.dispose();
    expect(w.cancelled, isTrue);
    expect(cw.cancelled, isTrue);
    final before = notifications;
    pending.done.complete(page(tracks(51, 52)));
    await settle();
    expect(notifications, before);
    c = open(StatsRankingKind.tracks); // for tearDown
  });
}
