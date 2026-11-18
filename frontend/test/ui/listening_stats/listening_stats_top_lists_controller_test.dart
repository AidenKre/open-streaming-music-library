// Phase 9A.2b (spec §4 paras 2–3, §3 para 3; SC-05, SC-06, SC-10, SC-12,
// SC-26; review 9-U03, 9-U11): the statistics controller's top lists.
//
//  * The top lists come from the one `load` the page made: cards in snapshot
//    order, ranked 1…n, with the snapshot's listening time and qualified
//    plays. Same-title tracks stay distinct by uuid.
//  * The shown ids are watched once through `watchCurrent` (SC-12
//    resolvers): a renamed entity updates in place, one that no longer
//    resolves is unavailable with its numbers kept. Before the watch emits,
//    or after it fails, nothing is unavailable (unknown is not unavailable).
//  * The snapshot token is exposed for See all (the same snapshot).
//  * A track tap is one `LibraryActions.playFromList([track], 0)` with the
//    statistics queue source: the one path to `PlaybackRequests.submit`.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';

import '../fake_library_actions.dart';
import 'stats_model_fakes.dart';

TrackUI track(String uuid, String title, {int artistId = 1}) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: title,
  artist: 'Ann',
  artistId: artistId,
  albumId: 10,
  duration: 180,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

const ann = ArtistUI(id: 1, name: 'Ann');
const bea = ArtistUI(id: 2, name: 'Bea');
const one = AlbumUI(id: 10, artistId: 1, name: 'One');

/// A 30-day snapshot whose top lists are written by hand: two same-title
/// tracks (uuid order decides nothing here: the order is the snapshot's).
ListeningStats withTops(StatsRange range, {int now = 1800000000000}) =>
    ListeningStats(
      range: range,
      window: range.resolve(now),
      boundaryLocalId: 42,
      totals: ListeningTotals(
        listeningSeconds: 900,
        qualifiedPlays: 6,
        uniqueTracks: 2,
        activeDays: 2,
      ),
      unavailable: const ListeningSubtotal(
        listeningSeconds: 0,
        qualifiedPlays: 0,
      ),
      futureTimestampCount: 0,
      overlongListenCount: 0,
      buckets: const [],
      chartCapped: false,
      topTracks: [
        RankedEntry(
          entity: track('t-b', 'Same', artistId: 2),
          listeningSeconds: 600.5,
          qualifiedPlays: 4,
        ),
        RankedEntry(
          entity: track('t-a', 'Same'),
          listeningSeconds: 299.5,
          qualifiedPlays: 2,
        ),
      ],
      topArtists: const [
        RankedEntry(entity: bea, listeningSeconds: 600.5, qualifiedPlays: 4),
        RankedEntry(entity: ann, listeningSeconds: 299.5, qualifiedPlays: 2),
      ],
      topAlbums: const [
        RankedEntry(entity: one, listeningSeconds: 900, qualifiedPlays: 6),
      ],
    );

String keyOf(StatsRankedCard card) =>
    (card.entity.key as ValueKey<String>).value;

void main() {
  late FakeSnapshotService snapshots;
  late FakeStatsRepository repo;
  late FakeFreshness freshness;
  late FakeLibraryActions actions;
  late ProviderContainer container;
  late ListeningStatsControls c;
  late int notifications;

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
    c = container.read(listeningStatsControllerFactoryProvider)();
    notifications = 0;
    c.addListener(() => notifications++);
  });

  tearDown(() {
    c.dispose();
    container.dispose();
  });

  Future<void> settle() => pumpEventQueue();

  /// Completes capture [i] with a token and the load with [stats].
  Future<HistorySnapshotToken> ready(
    int i,
    ListeningStats Function(StatsRange) stats,
  ) async {
    final cap = snapshots.captures[i];
    final range = cap.filterKey as StatsRange;
    final token = tokenFor(range);
    cap.done.complete(token);
    await settle();
    repo.loads.last.done.complete(stats(range));
    repo.hasListensCalls.last.done.complete(true);
    await settle();
    return token;
  }

  CurrentStatsEntities current({
    Map<String, TrackUI> tracks = const {},
    Map<int, ArtistUI> artists = const {},
    Map<int, AlbumUI> albums = const {},
  }) => CurrentStatsEntities(tracks: tracks, artists: artists, albums: albums);

  /// Everything still resolves, unchanged.
  CurrentStatsEntities allResolve() => current(
    tracks: {
      't-a': track('t-a', 'Same'),
      't-b': track('t-b', 'Same', artistId: 2),
    },
    artists: {1: ann, 2: bea},
    albums: {10: one},
  );

  test('while loading there are no top lists and no token', () {
    expect(c.state, isA<StatsLoading>());
    expect(c.topLists, isNull);
    expect(c.token, isNull);
  });

  test('ready: the snapshot\'s three lists, ranked 1…n with its numbers; '
      'same-title tracks stay distinct; the token is the captured one',
      () async {
    final token = await ready(0, withTops);
    final lists = c.topLists!;
    expect(lists.tracks.map(keyOf), ['track:t-b', 'track:t-a']);
    expect(lists.tracks.map((x) => x.rank), [1, 2]);
    expect(lists.tracks.map((x) => x.listeningSeconds), [600.5, 299.5]);
    expect(lists.tracks.map((x) => x.qualifiedPlays), [4, 2]);
    expect(lists.artists.map(keyOf), ['artist:2', 'artist:1']);
    expect(lists.artists.map((x) => x.rank), [1, 2]);
    expect(lists.albums.map(keyOf), ['album:10']);
    expect(lists.albums.single.listeningSeconds, 900);
    expect(lists.albums.single.qualifiedPlays, 6);
    expect([
      ...lists.tracks,
      ...lists.artists,
      ...lists.albums,
    ].any((x) => x.unavailable), isFalse);
    expect(lists.hasUnavailable, isFalse);
    expect(identical(c.token, token), isTrue);
  });

  test('the shown ids are watched once; no second load', () async {
    await ready(0, withTops);
    expect(repo.loads, hasLength(1));
    expect(repo.currentWatches, hasLength(1));
    final w = repo.currentWatches.single;
    expect(w.trackUuids, ['t-b', 't-a']);
    expect(w.artistIds, [2, 1]);
    expect(w.albumIds, [10]);
  });

  test('empty top lists: nothing to watch', () async {
    await ready(0, (r) => statsFor(r));
    expect(c.topLists!.tracks, isEmpty);
    expect(repo.currentWatches, isEmpty);
  });

  test('a shown track that no longer resolves is unavailable and keeps its '
      'rank and numbers; the others stay available', () async {
    await ready(0, withTops);
    final before = notifications;
    final all = allResolve();
    repo.currentWatches.single.emit(current(
      tracks: {'t-b': all.tracks['t-b']!},
      artists: all.artists,
      albums: all.albums,
    ));
    await settle();
    expect(notifications, greaterThan(before));
    final tracks = c.topLists!.tracks;
    expect(tracks.map(keyOf), ['track:t-b', 'track:t-a']);
    expect(tracks.map((x) => x.unavailable), [false, true]);
    expect(tracks[1].rank, 2);
    expect(tracks[1].listeningSeconds, 299.5);
    expect(tracks[1].qualifiedPlays, 2);
    expect((tracks[1].entity as TrackEntity).track.title, 'Same',
        reason: 'the snapshot\'s read model is kept for the label');
    expect(c.topLists!.hasUnavailable, isTrue);
  });

  test('an album or artist that no longer resolves is unavailable', () async {
    await ready(0, withTops);
    final all = allResolve();
    repo.currentWatches.single.emit(current(
      tracks: all.tracks,
      artists: {2: bea},
      albums: const {},
    ));
    await settle();
    expect(c.topLists!.artists.map((x) => x.unavailable), [false, true]);
    expect(c.topLists!.albums.single.unavailable, isTrue);
    expect(c.topLists!.hasUnavailable, isTrue);
  });

  test('a rename updates the card in place; order and numbers unchanged',
      () async {
    await ready(0, withTops);
    final all = allResolve();
    repo.currentWatches.single.emit(current(
      tracks: {...all.tracks, 't-a': track('t-a', 'Renamed')},
      artists: {...all.artists, 1: const ArtistUI(id: 1, name: 'Anna')},
      albums: all.albums,
    ));
    await settle();
    final tracks = c.topLists!.tracks;
    expect(tracks.map(keyOf), ['track:t-b', 'track:t-a']);
    expect((tracks[1].entity as TrackEntity).track.title, 'Renamed');
    expect(tracks[1].rank, 2);
    expect(tracks[1].listeningSeconds, 299.5);
    expect((c.topLists!.artists[1].entity as ArtistEntity).artist.name, 'Anna');
    expect(c.topLists!.hasUnavailable, isFalse);
  });

  test('a failed watch leaves the cards as they were (unknown is not '
      'unavailable)', () async {
    await ready(0, withTops);
    repo.currentWatches.single.fail(StateError('db closed'));
    await settle();
    expect(c.topLists!.hasUnavailable, isFalse);
    expect(c.topLists!.tracks.map(keyOf), ['track:t-b', 'track:t-a']);
    expect(c.state, isA<StatsReady>());
  });

  // DR-332-STATS-B-01: the fake delivers only while listened to, as a real
  // cancelled subscription does; this proves the watch is cancelled.
  test('refresh cancels the watch and clears lists and token; the cancelled '
      'watch delivers nothing', () async {
    await ready(0, withTops);
    final old = repo.currentWatches.single;
    c.refresh();
    expect(old.cancelled, isTrue);
    expect(c.topLists, isNull);
    expect(c.token, isNull);
    old.emit(current());
    await settle();
    expect(c.topLists, isNull);
    final token = await ready(1, withTops);
    expect(identical(c.token, token), isTrue);
    expect(c.topLists!.hasUnavailable, isFalse);
    expect(repo.currentWatches, hasLength(2));
  });

  test('a range change cancels the watch', () async {
    await ready(0, withTops);
    c.setRange(StatsRange.last30Days); // not the default (7 days)
    expect(repo.currentWatches.single.cancelled, isTrue);
    expect(c.topLists, isNull);
  });

  test('dispose cancels the watch', () async {
    await ready(0, withTops);
    final w = repo.currentWatches.single;
    c.dispose();
    expect(w.cancelled, isTrue);
  });

  test('a track tap plays that single track through LibraryActions with '
      'the statistics queue source, once', () async {
    await ready(0, withTops);
    expect(actions.calls, isEmpty, reason: 'opening requests nothing');
    final t = (c.topLists!.tracks[1].entity as TrackEntity).track;
    expect(await c.playTrack(t), isA<Accepted>());
    expect(actions.calls, ['playFromList t-a @0 listening_stats']);
  });

  test('opening, refresh and a range change request no playback', () async {
    await ready(0, withTops);
    c.refresh();
    await ready(1, withTops);
    c.setRange(StatsRange.allTime);
    await ready(2, withTops);
    expect(actions.calls, isEmpty);
  });
}
