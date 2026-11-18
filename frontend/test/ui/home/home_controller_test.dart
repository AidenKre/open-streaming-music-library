// Phase 6 §3 (Home chip, Home rail) / §6 (generation) / SC-07, SC-09,
// SC-26: the Home controller owns one `manual` Downloaded filter, maps the
// live recents to feed entities, and never lets an older subscription
// overwrite a newer filter. Real Drift where the model matters; a scripted
// repository where the test must control delivery.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/ui/browse_filter_controller.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/home/home_controller.dart';

import '../../helpers/server_binding.dart';
import '../../repositories/catalog_seed.dart';
import '../../helpers/library_seed.dart' show markDownloaded;
import '../../helpers/test_offline.dart';

/// `loading` / `failed` / `empty` / `empty filtered` / `ready k1,k2,…`.
String describe(HomeRecentsState s) => switch (s) {
  HomeRecentsLoading() => 'loading',
  HomeRecentsFailed() => 'failed',
  HomeRecentsEmpty(:final filtered) => filtered ? 'empty filtered' : 'empty',
  HomeRecentsReady(:final entities) =>
    'ready ${entities.map((e) => (e.key as ValueKey<String>).value).join(',')}',
};

TrackUI _track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Song $uuid',
  artist: 'A',
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

ResolvedRecent _recentTrack(String uuid, {int at = 1}) {
  final t = _track(uuid);
  return ResolvedRecent(
    ref: RecentRef(
      type: RecentEntityType.track,
      ref: uuid,
      occurredAt: at,
      eventUuid: 'ev-$uuid',
    ),
    entity: t,
  );
}

/// A stream whose subscription records cancellation but keeps delivering
/// whatever the test pushes: a hydration that completes after its
/// subscription was superseded.
class _LateStream extends Stream<List<ResolvedRecent>> {
  _LateStream(this.limit, this.downloadedOnly);
  final int limit;
  final bool downloadedOnly;
  void Function(List<ResolvedRecent>)? _onData;
  Function? _onError;
  bool cancelled = false;
  bool get listened => _onData != null;

  @override
  StreamSubscription<List<ResolvedRecent>> listen(
    void Function(List<ResolvedRecent>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onData = onData;
    _onError = onError;
    return _LateSubscription(this);
  }

  void emit(List<ResolvedRecent> value) => _onData?.call(value);

  void fail(Object error) {
    final handler = _onError;
    if (handler is void Function(Object, StackTrace)) {
      handler(error, StackTrace.empty);
    } else if (handler is void Function(Object)) {
      handler(error);
    }
  }
}

class _LateSubscription implements StreamSubscription<List<ResolvedRecent>> {
  _LateSubscription(this._stream);
  final _LateStream _stream;

  @override
  Future<void> cancel() async => _stream.cancelled = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Every `watchRecent` call gets its own [_LateStream], in call order.
class _ScriptedRecents implements RecentlyPlayedRepository {
  final streams = <_LateStream>[];

  @override
  Stream<List<ResolvedRecent>> watchRecent({
    int limit = 20,
    bool downloadedOnly = false,
  }) {
    final s = _LateStream(limit, downloadedOnly);
    streams.add(s);
    return s;
  }

  /// 6-R1-07: the cheap "any eligible history" probes (no hydration).
  final historyProbes = <StreamController<bool>>[];

  @override
  Stream<bool> watchHasEligibleHistory() {
    final c = StreamController<bool>();
    historyProbes.add(c);
    return c.stream;
  }

  /// The latest stream for this filter shape.
  _LateStream latest({required int limit, required bool downloadedOnly}) =>
      streams.lastWhere(
        (s) => s.limit == limit && s.downloadedOnly == downloadedOnly,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFilterControls extends ChangeNotifier
    implements BrowseFilterControls {
  _FakeFilterControls(this.policy);
  final OfflineFilterPolicy policy;
  bool disposed = false;
  BrowseFilters _filters = const BrowseFilters(
    policy: OfflineFilterPolicy.manual,
  );

  @override
  BrowseFilters get filters => _filters;

  @override
  void setDownloaded(bool value) {
    _filters = _filters.userSetDownloaded(value);
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  late AppDatabase db;
  late CatalogSeed seed;
  late TestOffline offline;
  late ProviderContainer container;

  Future<void> start({
    bool isOffline = false,
    List<Override> overrides = const [],
  }) async {
    db = AppDatabase(NativeDatabase.memory());
    seed = CatalogSeed(db);
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    offline = TestOffline(isOffline);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        offlineModeProvider.overrideWith(() => offline),
        ...overrides,
      ],
    );
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  HomeControls controls() {
    container.listen(homeControlsProvider, (_, _) {});
    return container.read(homeControlsProvider);
  }

  /// Completes with the first state (current or later) described as [want].
  Future<void> until(HomeControls c, String want) {
    final done = Completer<void>();
    void check() {
      if (!done.isCompleted && describe(c.recents) == want) done.complete();
    }

    c.addListener(check);
    check();
    return done.future
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('never "$want"; last: ${describe(c.recents)}'),
        )
        .whenComplete(() => c.removeListener(check));
  }

  group('Downloaded chip (SC-09 manual)', () {
    test('starts OFF even when offline', () async {
      await start(isOffline: true);
      final c = controls();
      expect(c.filters.downloaded, isFalse);
      expect(c.filters.policy, OfflineFilterPolicy.manual);
    });

    test('never moves on wentOffline / cameOnline', () async {
      await start();
      final c = controls();
      offline.set(true);
      await pumpEventQueue();
      expect(c.filters.downloaded, isFalse);
      c.setDownloaded(true);
      offline.set(false);
      await pumpEventQueue();
      expect(c.filters.downloaded, isTrue);
      offline.set(true);
      await pumpEventQueue();
      expect(c.filters.downloaded, isTrue);
    });

    test('setDownloaded updates the chip and notifies', () async {
      await start();
      final c = controls();
      var notified = 0;
      c.addListener(() => notified++);
      c.setDownloaded(true);
      expect(c.filters.downloaded, isTrue);
      expect(notified, greaterThan(0));
    });

    test('owns exactly one manual filter from the factory and disposes it '
        'with the scope', () async {
      final made = <_FakeFilterControls>[];
      await start(
        overrides: [
          browseFilterControllerFactoryProvider.overrideWithValue(
            ({policy = OfflineFilterPolicy.autoApply, initial}) =>
                _FakeFilterControls(policy)..also(made.add),
          ),
        ],
      );
      final c = controls();
      c.setDownloaded(true);
      expect(made, hasLength(1));
      expect(made.single.policy, OfflineFilterPolicy.manual);
      expect(c.filters.downloaded, isTrue);
      container.dispose();
      expect(made.single.disposed, isTrue);
      // tearDown disposes again; a disposed container tolerates it.
    });

    test('a rebuilt scope (logout, user switch, relaunch) starts OFF again',
        () async {
      await start();
      controls().setDownloaded(true);
      container.dispose();
      offline = TestOffline(false);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          offlineModeProvider.overrideWith(() => offline),
        ],
      );
      expect(controls().filters.downloaded, isFalse);
    });
  });

  group('recents over real Drift', () {
    setUp(() async {
      await start();
      await seed.artist(1, 'Aria');
      await seed.album(1, artistId: 1, name: 'One');
      await seed.track('a', artistId: 1, albumId: 1, downloaded: true);
      await seed.track('b', artistId: 1, albumId: 1, trackNumber: 2);
    });

    test('loading, then the newest-first entities with stable keys',
        () async {
      await seed.click('album', 'srv-1:1', at: 300);
      await seed.click('track', 'a', at: 200);
      await seed.click('artist', 'srv-1:1', at: 100);
      final c = controls();
      expect(describe(c.recents), 'loading');
      await until(c, 'ready album:1,track:a,artist:1');
      final entities = (c.recents as HomeRecentsReady).entities;
      expect(entities[0], isA<AlbumEntity>());
      expect(entities[1], isA<TrackEntity>());
      expect(entities[2], isA<ArtistEntity>());
      expect(entities[0].scope, const AlbumScope(artistId: 1, albumId: 1));
    });

    test('a new click re-orders live', () async {
      await seed.click('track', 'a', at: 200);
      final c = controls();
      await until(c, 'ready track:a');
      await seed.click('track', 'b', at: 400);
      await until(c, 'ready track:b,track:a');
    });

    test('no eligible history at all settles empty, not filtered', () async {
      await seed.click('track', 'gone', at: 500);
      await seed.click('album', 'other-server:1', at: 400);
      final c = controls();
      await until(c, 'empty');
    });

    test('chip ON shows only downloaded recents; OFF again shows all',
        () async {
      await seed.click('track', 'b', at: 400);
      await seed.click('track', 'a', at: 300);
      final c = controls();
      await until(c, 'ready track:b,track:a');
      c.setDownloaded(true);
      expect(describe(c.recents), 'loading');
      await until(c, 'ready track:a');
      c.setDownloaded(false);
      await until(c, 'ready track:b,track:a');
    });

    test('chip ON with history but nothing downloaded is filtered-empty',
        () async {
      await seed.click('track', 'b', at: 400);
      final c = controls();
      c.setDownloaded(true);
      await until(c, 'empty filtered');
    });

    test('chip ON with no eligible history at all stays plain empty',
        () async {
      final c = controls();
      c.setDownloaded(true);
      await until(c, 'empty');
    });

    test('chip ON, filtered-empty turns into a rail when a download lands',
        () async {
      await seed.click('track', 'b', at: 400);
      final c = controls();
      c.setDownloaded(true);
      await until(c, 'empty filtered');
      await markDownloaded(db, 'b');
      await until(c, 'ready track:b');
    });
  });

  group('scripted delivery', () {
    late _ScriptedRecents repo;
    setUp(() async {
      repo = _ScriptedRecents();
      await start(
        overrides: [recentlyPlayedRepositoryProvider.overrideWithValue(repo)],
      );
    });

    test('asks for the newest 20, unfiltered, while the chip is OFF',
        () async {
      controls();
      expect(repo.streams, hasLength(1));
      expect(repo.streams.single.limit, 20);
      expect(repo.streams.single.downloadedOnly, isFalse);
    });

    // 6-R1-07: chip ON opens one hydrating stream, not a second
    // `watchRecent` just to learn whether history exists.
    test('chip ON: one hydrated stream plus the cheap history probe',
        () async {
      final c = controls();
      c.setDownloaded(true);
      expect(repo.streams.map((s) => (s.limit, s.downloadedOnly)).toList(),
          [(20, false), (20, true)],
          reason: 'the OFF stream, then only the ON one');
      expect(repo.historyProbes, hasLength(1));
      repo.latest(limit: 20, downloadedOnly: true).emit(const []);
      expect(describe(c.recents), 'loading',
          reason: 'filtered-empty waits for the probe');
      repo.historyProbes.single.add(true);
      await pumpEventQueue();
      expect(describe(c.recents), 'empty filtered');
      repo.historyProbes.single.add(false);
      await pumpEventQueue();
      expect(describe(c.recents), 'empty');
    });

    // Pre-merge A6-02: a failed "is there any history?" check is unknown,
    // never "no history" (which hides the section).
    test('chip ON, nothing downloaded: a failed history probe shows failed '
        'with Retry, not a hidden section', () async {
      final c = controls();
      c.setDownloaded(true);
      repo.latest(limit: 20, downloadedOnly: true).emit(const []);
      repo.historyProbes.single.addError(StateError('db'));
      await pumpEventQueue();
      expect(describe(c.recents), 'failed');

      c.retryRecents();
      expect(describe(c.recents), 'loading');
      repo.latest(limit: 20, downloadedOnly: true).emit(const []);
      repo.historyProbes.last.add(true);
      await pumpEventQueue();
      expect(describe(c.recents), 'empty filtered');
    });

    test('chip ON: a history probe that failed before the empty list '
        'arrived still shows failed', () async {
      final c = controls();
      c.setDownloaded(true);
      repo.historyProbes.single.addError(StateError('db'));
      await pumpEventQueue();
      expect(describe(c.recents), 'loading', reason: 'the list is not in');
      repo.latest(limit: 20, downloadedOnly: true).emit(const []);
      expect(describe(c.recents), 'failed');
    });

    test('chip ON: a failed history probe never hides downloaded recents',
        () async {
      final c = controls();
      c.setDownloaded(true);
      repo.historyProbes.single.addError(StateError('db'));
      await pumpEventQueue();
      repo.latest(limit: 20, downloadedOnly: true).emit([_recentTrack('a')]);
      expect(describe(c.recents), 'ready track:a');
    });

    test('an error shows failed; Retry subscribes again', () async {
      final c = controls();
      repo.streams.single.fail(StateError('boom'));
      expect(describe(c.recents), 'failed');
      c.retryRecents();
      expect(repo.streams.first.cancelled, isTrue);
      expect(describe(c.recents), 'loading');
      repo.latest(limit: 20, downloadedOnly: false).emit([_recentTrack('a')]);
      expect(describe(c.recents), 'ready track:a');
    });

    test('a late result from the superseded filter never overwrites the '
        'newer one', () async {
      final c = controls();
      final off = repo.latest(limit: 20, downloadedOnly: false);
      c.setDownloaded(true);
      expect(off.cancelled, isTrue);
      final on = repo.latest(limit: 20, downloadedOnly: true);
      on.emit([_recentTrack('a')]);
      expect(describe(c.recents), 'ready track:a');

      // The OFF hydration completes after the flip.
      off.emit([_recentTrack('b', at: 9), _recentTrack('a')]);
      off.fail(StateError('late'));
      expect(describe(c.recents), 'ready track:a');
    });

    test('a late result after flipping back is dropped too', () async {
      final c = controls();
      c.setDownloaded(true);
      final on = repo.latest(limit: 20, downloadedOnly: true);
      c.setDownloaded(false);
      final off2 = repo.latest(limit: 20, downloadedOnly: false);
      off2.emit([_recentTrack('b')]);
      on.emit(const []);
      expect(describe(c.recents), 'ready track:b');
    });

    test('dispose cancels every subscription and later deliveries are '
        'ignored', () async {
      final c = controls();
      c.setDownloaded(true);
      var notified = 0;
      c.addListener(() => notified++);
      container.dispose();
      expect(repo.streams.every((s) => !s.listened || s.cancelled), isTrue);
      for (final s in repo.streams) {
        s.emit([_recentTrack('x')]);
      }
      expect(notified, 0);
    });
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
