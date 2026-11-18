// Phase 6 §7 / 6-U08, 6-G03, 6-G04 (unit halves): See all's loaded rows
// update live (payloads, download badges) without reordering. The stream
// re-hydrates exactly the refs it was given, in their given order: deleted
// entities drop out, under Downloaded a row losing membership drops out and
// stays out, and nothing outside the list is ever inserted (newly eligible
// rows wait for an explicit Refresh).
import 'dart:async';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/repositories/recents_snapshot_pager.dart';

import '../helpers/fake_clock.dart';
import '../helpers/server_binding.dart';
import 'catalog_seed.dart';

/// `type:id:label:downloaded/total`: what a card shows.
String card(ResolvedRecent r) => switch (r.entity) {
  TrackUI(:final uuidId, :final title) =>
    'track:$uuidId:$title:${r.downloaded}/${r.total}',
  AlbumUI(:final id, :final name) => 'album:$id:$name:${r.downloaded}/${r.total}',
  ArtistUI(:final id, :final name) =>
    'artist:$id:$name:${r.downloaded}/${r.total}',
  _ => 'unexpected',
};

RecentRef ref(RecentEntityType type, String ref, int at) => RecentRef(
  type: type,
  ref: ref,
  occurredAt: at,
  eventUuid: 'ev-$ref',
);

class Recorder {
  Recorder(Stream<List<ResolvedRecent>> stream) {
    _sub = stream.listen((v) {
      emissions.add(v.map(card).toList());
      _check();
    }, onError: (Object e) => error = e);
  }

  late final StreamSubscription<List<ResolvedRecent>> _sub;
  final emissions = <List<String>>[];
  Object? error;
  ({List<String> want, Completer<void> done})? _wait;

  void _check() {
    final w = _wait;
    if (w != null && emissions.isNotEmpty && _same(emissions.last, w.want)) {
      _wait = null;
      w.done.complete();
    }
  }

  static bool _same(List<String> a, List<String> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  Future<void> until(List<String> want) {
    final c = Completer<void>();
    _wait = (want: want, done: c);
    _check();
    return c.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'never emitted $want; last: '
        '${emissions.isEmpty ? 'none' : emissions.last}; error: $error',
      ),
    );
  }

  Future<void> cancel() => _sub.cancel();
}

void main() {
  late AppDatabase db;
  late CatalogSeed seed;
  late RecentlyPlayedRepository repo;

  // Loaded snapshot order (deliberately not the current history order).
  final loaded = [
    ref(RecentEntityType.track, 'b', 500),
    ref(RecentEntityType.album, 'srv-1:1', 400),
    ref(RecentEntityType.track, 'a', 300),
    ref(RecentEntityType.artist, 'srv-1:2', 200),
  ];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    seed = CatalogSeed(db);
    repo = RecentlyPlayedRepository(db, BrowseRepository(db));
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    await seed.artist(1, 'Aria');
    await seed.artist(2, 'Bram');
    await seed.album(1, artistId: 1, name: 'One');
    await seed.album(2, artistId: 2, name: 'Two');
    await seed.track('a', artistId: 1, albumId: 1, title: 'Song A', downloaded: true);
    await seed.track('b', artistId: 2, albumId: 2, title: 'Song B', downloaded: true);
    await seed.track('c', artistId: 2, albumId: 2, title: 'Song C');
    // History whose current order differs from the loaded snapshot.
    await seed.click('track', 'a', at: 900);
    await seed.click('artist', 'srv-1:2', at: 800);
    await seed.click('track', 'c', at: 700);
  });

  tearDown(() => db.close());

  Future<void> setDownload(String uuid, {required bool on}) =>
      (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
        on
            ? TracksCompanion(filePath: Value('/local/$uuid.flac'))
            : clearedDownloadColumns,
      );

  const all = [
    'track:b:Song B:1/1',
    'album:1:One:1/1',
    'track:a:Song A:1/1',
    'artist:2:Bram:1/2',
  ];

  test('hydrates exactly the given refs in the given order', () async {
    final rec = Recorder(repo.watchResolved(loaded));
    await rec.until(all);
    expect(rec.error, isNull);
    await rec.cancel();
  });

  test('a rename and a download change update payloads in place, never the '
      'order, and never insert other history', () async {
    final rec = Recorder(repo.watchResolved(loaded));
    await rec.until(all);
    await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
        .write(const TrackmetadataCompanion(title: Value('Renamed')));
    await rec.until([all[0], all[1], 'track:a:Renamed:1/1', all[3]]);
    await setDownload('c', on: true);
    await rec.until([all[0], all[1], 'track:a:Renamed:1/1', 'artist:2:Bram:2/2']);
    await seed.click('track', 'c', at: 9999);
    await pumpEventQueue();
    expect(rec.emissions.last, [
      all[0],
      all[1],
      'track:a:Renamed:1/1',
      'artist:2:Bram:2/2',
    ]);
    await rec.cancel();
  });

  test('a deleted entity drops out; the rest keep their order', () async {
    final rec = Recorder(repo.watchResolved(loaded));
    await rec.until(all);
    await db.customUpdate(
      "DELETE FROM trackmetadata WHERE uuid_id = 'b'",
      updates: {db.trackmetadata},
    );
    await db.customUpdate(
      "DELETE FROM tracks WHERE uuid_id = 'b'",
      updates: {db.tracks},
    );
    await rec.until([all[1], all[2], 'artist:2:Bram:0/1']);
    await rec.cancel();
  });

  test('Downloaded: a row losing its download drops out and stays out after '
      'it is downloaded again; a newly downloaded entity is never inserted',
      () async {
    final rec = Recorder(repo.watchResolved(loaded, downloadedOnly: true));
    await rec.until(all);
    await setDownload('a', on: false);
    // Track a and album 1 (its only member) lose membership.
    await rec.until([all[0], all[3]]);
    await setDownload('a', on: true);
    await setDownload('c', on: true);
    await rec.until([all[0], 'artist:2:Bram:2/2']);
    await pumpEventQueue();
    expect(rec.emissions.last, [all[0], 'artist:2:Bram:2/2']);
    await rec.cancel();
  });

  test('a ref that does not resolve at the start is never shown', () async {
    final rec = Recorder(
      repo.watchResolved([
        ref(RecentEntityType.track, 'missing', 600),
        ref(RecentEntityType.album, 'other:1', 550),
        ...loaded,
      ]),
    );
    await rec.until(all);
    await rec.cancel();
  });

  test('cancel stops every later read', () async {
    final rec = Recorder(repo.watchResolved(loaded));
    await rec.until(all);
    await rec.cancel();
    final count = rec.emissions.length;
    await setDownload('a', on: false);
    await pumpEventQueue();
    expect(rec.emissions, hasLength(count));
    expect(rec.error, isNull);
  });

  test('the pager watches the loaded refs under the token\'s chip', () async {
    final pager = RecentsSnapshotPager(
      HistorySnapshotService(db, clock: FakeClock()),
      repo,
      SnapshotFreshness(db),
    );
    final on = await pager.capture(downloadedOnly: true);
    final rec = Recorder(pager.watchLoaded(on, loaded));
    await rec.until(all);
    await setDownload('b', on: false);
    // Track b and artist 2 (b was its only downloaded member) drop out.
    await rec.until([all[1], all[2]]);
    await rec.cancel();

    final off = await pager.capture(downloadedOnly: false);
    final rec2 = Recorder(pager.watchLoaded(off, loaded));
    await rec2.until([
      'track:b:Song B:0/1',
      all[1],
      all[2],
      'artist:2:Bram:0/2',
    ]);
    await rec2.cancel();
  });

  // 6-R1-06: one eligibility rule. The loaded rows keep exactly the refs the
  // recents query itself would return, under each filter and readiness.
  group('parity with the recents query', () {
    /// Every clicked entity in history, newest first, as a ref list.
    Future<List<RecentRef>> everyClickedRef() async {
      final rows = await (db.select(db.historyEvents)
            ..where((e) => e.kind.equals('clicked'))
            ..orderBy([(e) => OrderingTerm.desc(e.occurredAt)]))
          .get();
      final seen = <String>{};
      return [
        for (final r in rows)
          if (RecentEntityType.values.any((t) => t.name == r.entityType) &&
              seen.add('${r.entityType}|${r.entityRef}'))
            RecentRef(
              type: RecentEntityType.values.byName(r.entityType),
              ref: r.entityRef,
              occurredAt: r.occurredAt,
              eventUuid: r.eventUuid,
            ),
      ];
    }

    Future<void> seedMixedHistory() async {
      await seed.click('track', 'b', at: 990);
      await seed.click('album', 'srv-1:1', at: 980);
      await seed.click('album', 'srv-1:2', at: 970);
      await seed.click('artist', 'srv-1:1', at: 960);
      // Never eligible: deleted, foreign, non-canonical, bare, unknown id.
      await seed.click('track', 'missing', at: 950);
      await seed.click('album', 'other:1', at: 940);
      await seed.click('album', 'srv-1:01', at: 930);
      await seed.click('artist', '2', at: 920);
      await seed.click('artist', 'srv-1:99', at: 910);
    }

    for (final downloadedOnly in [false, true]) {
      for (final reconciled in [true, false]) {
        test('downloadedOnly: $downloadedOnly, reconciled: $reconciled',
            () async {
          await seedMixedHistory();
          if (!reconciled) {
            await db.customStatement(
                'UPDATE server_binding SET catalog_reconciled_at_binding = 0');
          }
          final expected = [
            for (final r in await repo.page(
                boundaryLocalId: 1 << 40,
                limit: 100,
                downloadedOnly: downloadedOnly))
              card(r),
          ];
          final rec = Recorder(repo.watchResolved(await everyClickedRef(),
              downloadedOnly: downloadedOnly));
          await rec.until(expected);
          expect(rec.emissions.first, expected);
          await rec.cancel();
        });
      }
    }
  });
}
