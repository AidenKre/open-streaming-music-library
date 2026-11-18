// Phase 6 §7 / SC-10 / 6-U08, 6-G01, 6-G02, 6-G04, 6-G05 (unit halves):
// See all's RecentsSnapshotPager over 6B.1's keyset `page`.
//
//  * The snapshot boundary (MAX local_id at capture) is applied BEFORE the
//    dedupe: a later click on an existing entity keeps its old representative
//    in its old position, and a late old-time event never appears.
//  * 50 per page (fetch 51), cursor = last returned ref, no dup/skip over
//    more than 100 deduped entries with tied timestamps.
//  * The content counter is validated inside each page read: a Keep server
//    version past page one expires the continuation.
//
// Expected order comes from the manifest below, built newest-first by hand,
// never from the production query.
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/repositories/recents_snapshot_pager.dart';

import '../helpers/fake_clock.dart';
import '../helpers/server_binding.dart';
import 'catalog_seed.dart';
import 'history_snapshot_fixtures.dart' show pulledPage, serverEvent;

/// `type:id` of each hydrated entity, read from the entity itself.
String keyOf(ResolvedRecent r) => switch (r.entity) {
  TrackUI(:final uuidId) => 'track:$uuidId',
  AlbumUI(:final id) => 'album:$id',
  ArtistUI(:final id) => 'artist:$id',
  _ => 'unexpected:${r.entity.runtimeType}',
};

/// One manifest entity: its newest clicked event before any test write.
class Entry {
  Entry(this.index);
  final int index;

  /// Every 10th entity starting at 3 is an album, at 7 an artist (album k and
  /// artist k share the numeric id k), the rest are tracks.
  String get type => switch (index % 10) {
    3 => 'album',
    7 => 'artist',
    _ => 'track',
  };
  int get collectionId => index ~/ 10 + 1;
  String get trackUuid => 't-${index.toString().padLeft(3, '0')}';
  String get ref => type == 'track' ? trackUuid : 'srv-1:$collectionId';
  String get key => type == 'track' ? 'track:$trackUuid' : '$type:$collectionId';

  /// Groups of four share one timestamp; within a group the event uuid
  /// decides (higher first), so the tie order is explicit.
  int get at => 100000 - (index ~/ 4) * 10;
  String get eventUuid => 'n-${(1000 - index).toString().padLeft(4, '0')}';

  /// Downloaded under the chip: every third track, plus album 1 / artist 1
  /// (whose members are the downloaded tracks).
  bool get downloaded => switch (type) {
    'track' => index % 3 == 0,
    _ => collectionId == 1,
  };
}

const entityCount = 130;
final manifest = [for (var i = 0; i < entityCount; i++) Entry(i)];

/// Records what the pager asks the repository for.
class RecordingRecents extends RecentlyPlayedRepository {
  RecordingRecents(AppDatabase db) : super(db, BrowseRepository(db));

  final calls =
      <({int boundary, RecentRef? after, int limit, bool downloadedOnly})>[];

  @override
  Future<List<ResolvedRecent>> page({
    required int boundaryLocalId,
    RecentRef? after,
    required int limit,
    bool downloadedOnly = false,
  }) {
    calls.add((
      boundary: boundaryLocalId,
      after: after,
      limit: limit,
      downloadedOnly: downloadedOnly,
    ));
    return super.page(
      boundaryLocalId: boundaryLocalId,
      after: after,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
  }
}

void main() {
  late AppDatabase db;
  late CatalogSeed seed;
  late String binding;
  late HistoryRepository history;
  late RecordingRecents recents;
  late RecentsSnapshotPager pager;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    seed = CatalogSeed(db);
    binding = await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    history = HistoryRepository(db);
    recents = RecordingRecents(db);
    pager = RecentsSnapshotPager(
      HistorySnapshotService(db, clock: FakeClock()),
      recents,
      SnapshotFreshness(db),
    );

    final collections = entityCount ~/ 10 + 1;
    for (var k = 1; k <= collections; k++) {
      await seed.artist(k, 'Artist $k');
      await seed.album(k, artistId: k, name: 'Album $k');
      if (k != 1) await seed.track('m-$k', artistId: k, albumId: k);
    }
    for (final e in manifest.where((e) => e.type == 'track')) {
      await seed.track(
        e.trackUuid,
        artistId: 1,
        albumId: 1,
        downloaded: e.downloaded,
      );
    }
    // Rows that must never surface, newest of all.
    await seed.click('playlist', 'p-1', at: 900000, eventUuid: 'x-1');
    await seed.click('album', 'other:1', at: 900000, eventUuid: 'x-2');
    await seed.click('track', 'gone', at: 900000, eventUuid: 'x-3');
    // Each entity's newest click plus an older repeat; half the repeats are
    // inserted after the newest, so insertion order cannot decide.
    for (final e in manifest) {
      if (e.index.isOdd) {
        await seed.click(e.type, e.ref, at: e.at, eventUuid: e.eventUuid);
        await seed.click(e.type, e.ref, at: 10 + e.index, eventUuid: 'o-${e.eventUuid}');
      } else {
        await seed.click(e.type, e.ref, at: 10 + e.index, eventUuid: 'o-${e.eventUuid}');
        await seed.click(e.type, e.ref, at: e.at, eventUuid: e.eventUuid);
      }
    }
  });

  tearDown(() => db.close());

  SnapshotPage<ResolvedRecent, RecentRef> pageOf(
    SnapshotPageResult<ResolvedRecent, RecentRef> r,
  ) => switch (r) {
    SnapshotPage<ResolvedRecent, RecentRef>() => r,
    SnapshotExpired<ResolvedRecent, RecentRef>() => fail('expected a page'),
  };

  Future<int> maxLocalId() async => (await db
          .customSelect('SELECT MAX(local_id) AS m FROM history_events')
          .getSingle())
      .read<int>('m');

  /// Every page from the start (or from [after]); fails on expiry.
  Future<List<SnapshotPage<ResolvedRecent, RecentRef>>> traverse(
    HistorySnapshotToken token, {
    RecentRef? after,
  }) async {
    final pages = <SnapshotPage<ResolvedRecent, RecentRef>>[];
    var cursor = after;
    do {
      final p = pageOf(await pager.page(token, cursor, 50));
      pages.add(p);
      cursor = p.nextCursor;
    } while (cursor != null);
    return pages;
  }

  List<String> keys(Iterable<SnapshotPage<ResolvedRecent, RecentRef>> pages) =>
      [for (final p in pages) ...p.items.map(keyOf)];

  test('capture: the token carries the chip as a value-equal filter key and '
      'the current insertion boundary', () async {
    final on = await pager.capture(downloadedOnly: true);
    final off = await pager.capture(downloadedOnly: false);
    expect(on.filterKey, (downloadedOnly: true));
    expect(off.filterKey, (downloadedOnly: false));
    expect(on.boundaryLocalId, await maxLocalId());
    expect(on.catalogAttributionVersion, isNull);
  });

  test('more than 100 deduped entries over three pages with tied timestamps: '
      'exactly the manifest order, no duplicates or skips', () async {
    final token = await pager.capture(downloadedOnly: false);
    final pages = await traverse(token);

    expect([for (final p in pages) p.items.length], [50, 50, 30]);
    expect([for (final p in pages) p.hasMore], [true, true, false]);
    expect(pages[0].nextCursor, pages[0].items.last.ref);
    expect(pages[1].nextCursor, pages[1].items.last.ref);
    expect(keys(pages), [for (final e in manifest) e.key]);
    // Each representative is the entity's newest event, not a repeat.
    final all = [for (final p in pages) ...p.items];
    expect(
      [for (final r in all) (r.ref.occurredAt, r.ref.eventUuid)],
      [for (final e in manifest) (e.at, e.eventUuid)],
    );
  });

  test('asks the repository for 51 rows with the token boundary, the chip and '
      'the last returned ref as the cursor', () async {
    final token = await pager.capture(downloadedOnly: false);
    final pages = await traverse(token);
    expect(recents.calls, hasLength(3));
    expect([for (final c in recents.calls) c.limit], [51, 51, 51]);
    expect(
      [for (final c in recents.calls) c.boundary],
      everyElement(token.boundaryLocalId),
    );
    expect([for (final c in recents.calls) c.after], [
      null,
      pages[0].items.last.ref,
      pages[1].items.last.ref,
    ]);
    expect([for (final c in recents.calls) c.downloadedOnly], everyElement(false));
  });

  test('the boundary applies before the dedupe: a newer click on an existing '
      'entity and an old-time pulled event during paging change nothing', () async {
    final token = await pager.capture(downloadedOnly: false);
    final first = pageOf(await pager.page(token, null, 50));

    // A newer click on entity 70 (on page two), a local old-time click for a
    // never-clicked track, and an old-time pulled event for another one.
    final moved = manifest[70];
    await seed.click(moved.type, moved.ref, at: 999999, eventUuid: 'z-new');
    await seed.track('late-local', artistId: 1, albumId: 1);
    await seed.track('late-pulled', artistId: 1, albumId: 1);
    await seed.click('track', 'late-local', at: manifest[60].at, eventUuid: 'z-local');
    await history.applyPage(
      binding,
      requestedAfter: 0,
      page: pulledPage([
        serverEvent(
          HistoryEventPayload(
            eventUuid: 'z-pulled',
            kind: 'clicked',
            entityType: 'track',
            entityRef: 'late-pulled',
            occurredAt: manifest[80].at,
            secondsPlayed: null,
            trackLength: null,
          ),
          1,
        ),
      ]),
    );

    final rest = await traverse(token, after: first.nextCursor);
    expect(keys([first, ...rest]), [for (final e in manifest) e.key]);
    final kept = rest
        .expand((p) => p.items)
        .singleWhere((r) => keyOf(r) == moved.key);
    expect(kept.ref.occurredAt, moved.at, reason: 'the old representative');
    expect(kept.ref.eventUuid, moved.eventUuid);

    // A new snapshot sees both.
    final fresh = keys(await traverse(await pager.capture(downloadedOnly: false)));
    expect(fresh.first, moved.key);
    expect(fresh, containsAll(['track:late-local', 'track:late-pulled']));
    expect(fresh, hasLength(entityCount + 2));
  });

  test('downloadedOnly comes from the token: only entities with a usable '
      'download, in manifest order, over every page', () async {
    final token = await pager.capture(downloadedOnly: true);
    final pages = await traverse(token);
    expect(keys(pages), [
      for (final e in manifest)
        if (e.downloaded) e.key,
    ]);
    expect([for (final c in recents.calls) c.downloadedOnly], everyElement(true));
  });

  test('a Keep server version past page one expires the continuation; a new '
      'snapshot shows the new order', () async {
    final token = await pager.capture(downloadedOnly: false);
    final first = pageOf(await pager.page(token, null, 50));
    expect(first.hasMore, isTrue);

    // Rewrite entity 80's newest event to an old time (a Phase 5 conflict).
    final changed = manifest[80];
    await history.keepServerVersion(
      binding,
      serverEvent(
        HistoryEventPayload(
          eventUuid: changed.eventUuid,
          kind: 'clicked',
          entityType: changed.type,
          entityRef: changed.ref,
          occurredAt: 5,
          secondsPlayed: null,
          trackLength: null,
        ),
        1,
      ),
    );
    final callsBefore = recents.calls.length;

    final next = await pager.page(token, first.nextCursor, 50);
    expect(next, isA<SnapshotExpired<ResolvedRecent, RecentRef>>());
    expect(recents.calls.length, callsBefore, reason: 'no rows were read');
    expect(
      await pager.page(token, null, 50),
      isA<SnapshotExpired<ResolvedRecent, RecentRef>>(),
      reason: 'the whole token is stale, not just the cursor',
    );

    final fresh = keys(await traverse(await pager.capture(downloadedOnly: false)));
    // Its older repeat (at 10 + index) is now its newest event.
    expect(fresh.last, changed.key);
    expect(fresh, hasLength(entityCount));
  });

  test('entities deleted at a page edge neither duplicate nor skip the rest',
      () async {
    final token = await pager.capture(downloadedOnly: false);
    final first = pageOf(await pager.page(token, null, 50));
    // The last returned entity and the first of the next page go away.
    for (final uuid in [manifest[49].trackUuid, manifest[50].trackUuid]) {
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
    final rest = await traverse(token, after: first.nextCursor);
    expect(keys(rest), [for (final e in manifest.skip(51)) e.key]);
    expect(rest.first.items, hasLength(50), reason: 'later rows fill the page');
  });
}
