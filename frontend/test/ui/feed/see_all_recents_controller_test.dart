// Phase 6 §3 (See all), §7 / SC-09, SC-10, SC-26 / 6-U08, 6-U09, 6-G01 …
// 6-G05 (unit halves): the See all page controller over real Drift.
//
//  * Its own `manual` Downloaded chip, seeded from Home's value; changing
//    either never changes the other.
//  * A stable snapshot: pages in manifest order; a newer click on an existing
//    entity or an old-time pulled event never reorders what is loaded; it
//    raises "New activity" and Refresh captures both.
//  * A Keep server version past page one stops the continuation with
//    "History changed" and keeps the loaded rows.
//  * Live payload/badge updates without reordering; under Downloaded a row
//    losing membership disappears and newly eligible rows wait for Refresh;
//    a deleted entity disappears and later pages fill.
//
// Expected keys come from the manifest below (newest first by hand).
import 'dart:async';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/browse_filter_controller.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/see_all_recents_controller.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/library_actions.dart';

import '../../helpers/server_binding.dart';
import '../../repositories/catalog_seed.dart';
import '../../repositories/history_snapshot_fixtures.dart'
    show pulledPage, serverEvent;
import '../fake_library_actions.dart';
import '../../helpers/test_offline.dart';

String keyOf(FeedEntity e) => (e.key as ValueKey<String>).value;

/// Track t-000 is the newest; groups of three share a timestamp and the
/// event uuid breaks the tie (higher first).
const count = 120;
String uuidAt(int i) => 't-${i.toString().padLeft(3, '0')}';
int atOf(int i) => 100000 - (i ~/ 3) * 10;
String eventOf(int i) => 'n-${(1000 - i).toString().padLeft(4, '0')}';
final manifest = [for (var i = 0; i < count; i++) 'track:${uuidAt(i)}'];

/// Downloaded tracks: every fourth.
bool downloadedAt(int i) => i % 4 == 0;

/// `entities` keys, or null while loading.
List<String>? keysOf(SeeAllRecentsControls c) => c.entities?.map(keyOf).toList();

class _RecordingFilters extends ChangeNotifier implements BrowseFilterControls {
  _RecordingFilters(this.policy, bool? initial)
    : _filters = BrowseFilters(policy: policy).userSetDownloaded(initial ?? false),
      initial = initial;
  final OfflineFilterPolicy policy;
  final bool? initial;
  BrowseFilters _filters;
  bool disposed = false;

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
  late String binding;
  late TestOffline offline;
  late ProviderContainer container;
  late FakeLibraryActions actions;
  final made = <SeeAllRecentsControls>[];

  Future<void> start({
    bool isOffline = false,
    bool history = true,
    List<Override> overrides = const [],
  }) async {
    db = AppDatabase(NativeDatabase.memory());
    seed = CatalogSeed(db);
    binding = await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    await seed.artist(1, 'Aria');
    await seed.album(1, artistId: 1, name: 'One');
    if (history) {
      for (var i = 0; i < count; i++) {
        await seed.track(uuidAt(i), artistId: 1, albumId: 1, downloaded: downloadedAt(i));
        await seed.click('track', uuidAt(i), at: 10 + i, eventUuid: 'o-${eventOf(i)}');
        await seed.click('track', uuidAt(i), at: atOf(i), eventUuid: eventOf(i));
      }
    }
    offline = TestOffline(isOffline);
    actions = FakeLibraryActions();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        offlineModeProvider.overrideWith(() => offline),
        libraryActionsProvider.overrideWithValue(actions),
        ...overrides,
      ],
    );
  }

  tearDown(() async {
    for (final c in made) {
      c.dispose();
    }
    made.clear();
    container.dispose();
    await db.close();
  });

  SeeAllRecentsControls open({bool initialDownloaded = false}) {
    final c = container.read(seeAllRecentsControllerFactoryProvider)(
      initialDownloaded: initialDownloaded,
    );
    made.add(c);
    return c;
  }

  /// Completes once [test] holds for [c] (now or after a notification).
  Future<void> until(
    SeeAllRecentsControls c,
    bool Function(SeeAllRecentsControls c) test, [
    String what = 'condition',
  ]) {
    final done = Completer<void>();
    void check() {
      if (!done.isCompleted && test(c)) done.complete();
    }

    c.addListener(check);
    check();
    return done.future
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail(
            'never $what; entities ${keysOf(c)?.length}, hasMore ${c.hasMore}, '
            'failed ${c.failed}, notice ${c.notice}',
          ),
        )
        .whenComplete(() => c.removeListener(check));
  }

  Future<void> loaded(SeeAllRecentsControls c, int n) =>
      until(c, (c) => c.entities?.length == n && !c.failed, '$n loaded');

  /// Loads every page; returns the keys.
  Future<List<String>> loadAll(SeeAllRecentsControls c) async {
    await until(c, (c) => c.entities != null, 'first page');
    while (c.hasMore) {
      final before = c.entities!.length;
      c.loadMore();
      await until(
        c,
        (c) => c.entities!.length != before || !c.hasMore || c.failed,
        'next page',
      );
    }
    return keysOf(c)!;
  }

  Future<void> deleteTrack(String uuid) async {
    await db.customUpdate(
      'DELETE FROM trackmetadata WHERE uuid_id = ?',
      variables: [Variable.withString(uuid)],
      updates: {db.trackmetadata},
    );
    await db.customUpdate(
      'DELETE FROM tracks WHERE uuid_id = ?',
      variables: [Variable.withString(uuid)],
      updates: {db.tracks},
    );
  }

  Future<void> setDownload(String uuid, {required bool on}) =>
      (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
        on
            ? TracksCompanion(filePath: Value('/local/$uuid.flac'))
            : clearedDownloadColumns,
      );

  group('chip (SC-09 manual, seeded from Home)', () {
    test('starts from the given value as a manual chip, even offline, and '
        'never follows connectivity', () async {
      await start(isOffline: true);
      final off = open();
      expect(off.filters.downloaded, isFalse);
      expect(off.filters.policy, OfflineFilterPolicy.manual);
      final on = open(initialDownloaded: true);
      expect(on.filters.downloaded, isTrue);
      offline.set(false);
      offline.set(true);
      await pumpEventQueue();
      expect(off.filters.downloaded, isFalse);
      expect(on.filters.downloaded, isTrue);
    });

    test('owns one manual filter from the factory, seeded with initial, and '
        'disposes it', () async {
      final filters = <_RecordingFilters>[];
      await start(
        overrides: [
          browseFilterControllerFactoryProvider.overrideWithValue(
            ({policy = OfflineFilterPolicy.autoApply, initial}) {
              final f = _RecordingFilters(policy, initial);
              filters.add(f);
              return f;
            },
          ),
        ],
      );
      final c = open(initialDownloaded: true);
      expect(filters, hasLength(1));
      expect(filters.single.policy, OfflineFilterPolicy.manual);
      expect(filters.single.initial, isTrue);
      c.dispose();
      made.remove(c);
      expect(filters.single.disposed, isTrue);
    });

    test('See all and Home never change each other\'s chip', () async {
      await start();
      container.listen(homeControlsProvider, (_, _) {});
      final home = container.read(homeControlsProvider);
      home.setDownloaded(true);
      final seeAll = open(initialDownloaded: home.filters.downloaded);
      expect(seeAll.filters.downloaded, isTrue);

      seeAll.setDownloaded(false);
      expect(home.filters.downloaded, isTrue);
      home.setDownloaded(false);
      home.setDownloaded(true);
      expect(seeAll.filters.downloaded, isFalse);
    });

    test('the seeded chip filters the first snapshot', () async {
      await start();
      final c = open(initialDownloaded: true);
      final keys = await loadAll(c);
      expect(keys, [
        for (var i = 0; i < count; i++)
          if (downloadedAt(i)) manifest[i],
      ]);
    });
  });

  group('paging', () {
    test('loading, then the first 50 in manifest order with more to come',
        () async {
      await start();
      final c = open();
      expect(c.entities, isNull);
      expect(c.failed, isFalse);
      await loaded(c, 50);
      expect(keysOf(c), manifest.take(50).toList());
      expect(c.hasMore, isTrue);
      expect(c.notice, SnapshotStaleness.fresh);
    });

    test('more than 100 entries over three pages: exactly the manifest, no '
        'duplicates or skips, and nothing more after the last page', () async {
      await start();
      final c = open();
      expect(await loadAll(c), manifest);
      expect(c.hasMore, isFalse);
      // Let the live watch's first re-read of the last page settle.
      await pumpEventQueue();
      var notified = 0;
      c.addListener(() => notified++);
      c.loadMore();
      await pumpEventQueue();
      expect(keysOf(c), manifest);
      expect(notified, 0);
    });

    test('no history: a settled empty snapshot', () async {
      await start(history: false);
      final c = open();
      await until(c, (c) => c.entities != null, 'settled');
      expect(c.entities, isEmpty);
      expect(c.hasMore, isFalse);
      expect(c.failed, isFalse);
    });

    test('a chip change is a new snapshot from the start', () async {
      await start();
      final c = open();
      await loaded(c, 50);
      c.loadMore();
      await loaded(c, 100);
      final epoch = c.snapshotEpoch;
      c.setDownloaded(true);
      expect(c.snapshotEpoch, isNot(epoch));
      expect(c.entities, isNull, reason: 'the old rows are not shown');
      final keys = await loadAll(c);
      expect(keys, [
        for (var i = 0; i < count; i++)
          if (downloadedAt(i)) manifest[i],
      ]);
    });
  });

  group('snapshot stability and notices', () {
    // 6-R1-02 / DEV-6-04: See all shows clicks, so only a new click is new
    // activity; listens (local or pulled) never raise the notice.
    test('a finished listen and a pulled play event raise no notice; a new '
        'click does', () async {
      await start();
      final c = open();
      await loaded(c, 50);
      final history = HistoryRepository(db);
      // What ListenRecorder writes when a listen finishes.
      await history.insertLocal(
        binding,
        HistoryEventPayload(
          eventUuid: 'listen-1',
          kind: 'play',
          entityType: 'track',
          entityRef: uuidAt(3),
          occurredAt: 999999,
          secondsPlayed: 30,
          trackLength: 200,
        ),
      );
      await history.applyPage(
        binding,
        requestedAfter: 0,
        page: pulledPage([
          serverEvent(
            HistoryEventPayload(
              eventUuid: 'pulled-play',
              kind: 'play',
              entityType: 'track',
              entityRef: uuidAt(4),
              occurredAt: 999998,
              secondsPlayed: 30,
              trackLength: 200,
            ),
            1,
          ),
        ]),
      );
      await pumpEventQueue();
      expect(c.notice, SnapshotStaleness.fresh);

      await seed.click('track', uuidAt(10), at: 999999, eventUuid: 'z-new');
      await until(c, (c) => c.notice == SnapshotStaleness.newActivity, 'notice');
    });

    test('a newer click on an existing entity and an old-time pulled event '
        'keep the order and raise New activity; Refresh captures both',
        () async {
      await start();
      await seed.track('late', artistId: 1, albumId: 1);
      final c = open();
      await loaded(c, 50);

      await seed.click('track', uuidAt(10), at: 999999, eventUuid: 'z-new');
      await HistoryRepository(db).applyPage(
        binding,
        requestedAfter: 0,
        page: pulledPage([
          serverEvent(
            HistoryEventPayload(
              eventUuid: 'z-pulled',
              kind: 'clicked',
              entityType: 'track',
              entityRef: 'late',
              occurredAt: atOf(20),
              secondsPlayed: null,
              trackLength: null,
            ),
            1,
          ),
        ]),
      );
      await until(c, (c) => c.notice == SnapshotStaleness.newActivity, 'notice');
      expect(keysOf(c), manifest.take(50).toList(), reason: 'no reorder');
      expect(await loadAll(c), manifest, reason: 'old representative kept');

      final epoch = c.snapshotEpoch;
      c.refresh();
      expect(c.snapshotEpoch, isNot(epoch));
      final fresh = await loadAll(c);
      expect(c.notice, SnapshotStaleness.fresh);
      expect(fresh.first, manifest[10]);
      expect(fresh, contains('track:late'));
      expect(fresh, hasLength(count + 1));
    });

    test('a Keep server version past page one stops the continuation with '
        'History changed and keeps the loaded rows', () async {
      await start();
      final c = open();
      await loaded(c, 50);
      c.loadMore();
      await loaded(c, 100);

      await HistoryRepository(db).keepServerVersion(
        binding,
        serverEvent(
          HistoryEventPayload(
            eventUuid: eventOf(110),
            kind: 'clicked',
            entityType: 'track',
            entityRef: uuidAt(110),
            occurredAt: 999999,
            secondsPlayed: null,
            trackLength: null,
          ),
          1,
        ),
      );
      c.loadMore();
      await until(c, (c) => !c.hasMore, 'continuation stopped');
      expect(c.notice, SnapshotStaleness.historyChanged);
      expect(keysOf(c), manifest.take(100).toList());
      expect(c.failed, isFalse);
      c.loadMore();
      await pumpEventQueue();
      expect(keysOf(c), manifest.take(100).toList());

      c.refresh();
      final fresh = await loadAll(c);
      expect(c.notice, SnapshotStaleness.fresh);
      expect(fresh.first, manifest[110]);
      expect(fresh, hasLength(count));
    });
  });

  group('live updates', () {
    test('a rename updates the loaded row in place, never the order', () async {
      await start();
      final c = open();
      await loaded(c, 50);
      await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals(uuidAt(5))))
          .write(const TrackmetadataCompanion(title: Value('Renamed')));
      await until(
        c,
        (c) => (c.entities![5] as TrackEntity).track.title == 'Renamed',
        'rename',
      );
      expect(keysOf(c), manifest.take(50).toList());
    });

    test('Downloaded: a row losing its download disappears; a newly '
        'downloaded earlier row waits for Refresh', () async {
      await start();
      final c = open(initialDownloaded: true);
      // Downloaded rows are every fourth: 0, 4, …, 116 (30, one page).
      await loaded(c, 30);
      expect(c.hasMore, isFalse);
      await setDownload(uuidAt(8), on: false);
      await until(c, (c) => !keysOf(c)!.contains(manifest[8]), 'removal');
      expect(keysOf(c)!.first, manifest[0]);
      await setDownload(uuidAt(1), on: true);
      await pumpEventQueue();
      await setDownload(uuidAt(4), on: false);
      await until(c, (c) => !keysOf(c)!.contains(manifest[4]), 'second removal');
      expect(keysOf(c), isNot(contains(manifest[1])));
      c.refresh();
      final fresh = await loadAll(c);
      expect(fresh.take(3), [manifest[0], manifest[1], manifest[12]]);
    });

    test('a deleted visible entity disappears and later pages fill', () async {
      await start();
      final c = open();
      await loaded(c, 50);
      await deleteTrack(uuidAt(3));
      await deleteTrack(uuidAt(49));
      await until(c, (c) => c.entities!.length == 48, 'removal');
      final all = await loadAll(c);
      expect(all, [
        for (var i = 0; i < count; i++)
          if (i != 3 && i != 49) manifest[i],
      ]);
    });
  });

  test('a track tap plays a single-track queue from recents', () async {
    await start();
    final c = open();
    await loaded(c, 50);
    final track = (c.entities!.first as TrackEntity).track;
    await c.playTrack(track);
    expect(actions.calls, ['playFromList ${track.uuidId} @0 recents']);
  });
}
