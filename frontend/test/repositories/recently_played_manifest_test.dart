// Exit proof for 6B.1 (Phase 6 §8, review §3 fixture manifest; 6-U06,
// 6-R01, 6-R02 unit halves). The manifest below lists every entity's
// newest click by hand; the expected orders are literal lists written from
// it, not computed by anything resembling the production query.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';

import '../helpers/server_binding.dart';
import 'catalog_seed.dart';

const _instance = 'srv-1';

/// Catalog. Album n belongs to artist n.
///  album 1: t01 (downloaded), t02          -> partial
///  album 2: t03 (downloaded)               -> full
///  album 3: t04, t05                       -> never downloaded
///  album 4: t06 (damaged only)             -> no usable download
///  album 5: t07, t08 (downloaded)          -> partial
///  album 6: t09, t10                       -> never downloaded
///  album 7: t11 (downloaded)               -> full
///  album 8 / artist 8: never clicked.
const _albumTracks = {
  1: ['t01', 't02'],
  2: ['t03'],
  3: ['t04', 't05'],
  4: ['t06'],
  5: ['t07', 't08'],
  6: ['t09', 't10'],
  7: ['t11'],
  8: ['t12'],
};
const _downloaded = {'t01', 't03', 't08', 't11'};
const _damaged = {'t06'};

/// Every valid entity's NEWEST click: (type, id, time, event uuid).
/// Ties: album 7 / artist 7 at 890 (same number, different types) and
/// t08 / t09 at 750, ordered by event uuid descending.
const _newest = [
  ('track', 't01', 900, 'm-0900'),
  ('album', '7', 890, 'm-0890-a'),
  ('artist', '7', 890, 'm-0890-b'),
  ('track', 't02', 880, 'm-0880'),
  ('album', '1', 870, 'm-0870'),
  ('artist', '2', 860, 'm-0860'),
  ('track', 't03', 850, 'm-0850'),
  ('album', '2', 840, 'm-0840'),
  ('track', 't04', 830, 'm-0830'),
  ('artist', '1', 820, 'm-0820'),
  ('track', 't05', 810, 'm-0810'),
  ('album', '3', 800, 'm-0800'),
  ('track', 't06', 790, 'm-0790'),
  ('artist', '3', 780, 'm-0780'),
  ('track', 't07', 770, 'm-0770'),
  ('album', '4', 760, 'm-0760'),
  ('track', 't08', 750, 'm-0750-x'),
  ('track', 't09', 750, 'm-0750-y'),
  ('artist', '4', 740, 'm-0740'),
  ('album', '5', 730, 'm-0730'),
  ('track', 't10', 720, 'm-0720'),
  ('artist', '5', 710, 'm-0710'),
  ('album', '6', 700, 'm-0700'),
  ('track', 't11', 690, 'm-0690'),
  ('artist', '6', 680, 'm-0680'),
];

/// The full expected order, written out from [_newest].
const _expectedAll = [
  'track:t01',
  'artist:7',
  'album:7',
  'track:t02',
  'album:1',
  'artist:2',
  'track:t03',
  'album:2',
  'track:t04',
  'artist:1',
  'track:t05',
  'album:3',
  'track:t06',
  'artist:3',
  'track:t07',
  'album:4',
  'track:t09',
  'track:t08',
  'artist:4',
  'album:5',
  'track:t10',
  'artist:5',
  'album:6',
  'track:t11',
  'artist:6',
];

/// Downloaded only: tracks with a usable file, collections with any.
const _expectedDownloaded = [
  'track:t01',
  'artist:7',
  'album:7',
  'album:1',
  'artist:2',
  'track:t03',
  'album:2',
  'artist:1',
  'track:t08',
  'album:5',
  'artist:5',
  'track:t11',
];

/// Rows newer than every valid click that must never surface.
const _invalidNewest = [
  ('playlist', 't01'),
  ('Track', 't01'),
  ('track', 'gone-1'),
  ('track', 'T01'),
  ('album', '$_instance:404'),
  ('artist', '$_instance:404'),
  ('album', '$_instance:0'),
  ('album', '$_instance:-1'),
  ('album', '$_instance:01'),
  ('artist', '$_instance:01'),
  ('album', '$_instance:abc'),
  ('artist', '$_instance:2x'),
  ('album', '$_instance:99999999999999999999'),
  ('album', '$_instance:'),
  ('album', '1'),
  ('artist', '7'),
  ('album', 'other:1'),
  ('artist', 'other:7'),
  ('album', 't01'),
  ('track', '$_instance:1'),
];

String _key(ResolvedRecent r) => switch (r.entity) {
  TrackUI(:final uuidId) => 'track:$uuidId',
  AlbumUI(:final id) => 'album:$id',
  ArtistUI(:final id) => 'artist:$id',
  _ => 'unexpected',
};

void main() {
  late AppDatabase db;
  late RecentlyPlayedRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final seed = CatalogSeed(db);
    repo = RecentlyPlayedRepository(db, BrowseRepository(db));
    await seedTestBinding(db, instanceId: _instance, reconciled: true);
    for (final MapEntry(key: n, value: uuids) in _albumTracks.entries) {
      await seed.artist(n, 'Artist $n');
      await seed.album(n, artistId: n, name: 'Album $n', year: 2000 + n);
      for (final (i, u) in uuids.indexed) {
        await seed.track(
          u,
          artistId: n,
          albumId: n,
          trackNumber: i + 1,
          downloaded: _downloaded.contains(u),
          damaged: _damaged.contains(u),
        );
      }
    }

    String ref(String type, String id) =>
        type == 'track' ? id : '$_instance:$id';

    // Dozens of older repeats: every entity twice more, and the newest
    // track 30 more times, all older than any entity's newest click.
    var old = 1;
    for (final (type, id, _, _) in _newest) {
      await seed.click(type, ref(type, id), at: old++);
      await seed.click(type, ref(type, id), at: old++);
    }
    for (var i = 0; i < 30; i++) {
      await seed.click('track', 't02', at: 200 + i);
    }
    // The newest clicks, inserted in reverse so local_id order disagrees
    // with recency.
    for (final (type, id, at, uuid) in _newest.reversed) {
      await seed.click(type, ref(type, id), at: at, eventUuid: uuid);
    }
    // Invalid, unknown and deleted refs occupy the newest timestamps.
    var at = 2000;
    for (final (type, r) in _invalidNewest) {
      await seed.click(type, r, at: at++);
    }
  });

  tearDown(() => db.close());

  test('Home: exactly the first 20 of the manifest order', () async {
    final got = await repo.watchRecent().first;
    expect(got.map(_key).toList(), _expectedAll.take(20).toList());
    // Representatives are the newest clicks, not the repeats.
    expect(got.first.ref.occurredAt, 900);
    expect(got[3].ref.occurredAt, 880); // t02 despite 30 later-inserted rows
  });

  test('Home, downloaded only: the downloaded subset in manifest order',
      () async {
    final got = await repo.watchRecent(downloadedOnly: true).first;
    expect(got.map(_key).toList(), _expectedDownloaded);
  });

  test('paged traversal reaches exactly the full manifest, no duplicates or '
      'skips across tie edges', () async {
    final boundary = (await db
            .customSelect('SELECT MAX(local_id) AS m FROM history_events')
            .getSingle())
        .read<int>('m');
    final seen = <String>[];
    RecentRef? after;
    for (var i = 0; i < 10; i++) {
      final page = await repo.page(
        boundaryLocalId: boundary,
        after: after,
        limit: 3,
      );
      if (page.isEmpty) break;
      seen.addAll(page.map(_key));
      after = page.last.ref;
    }
    expect(seen, _expectedAll);
  });

  test('same number as album and artist resolves to the right type each',
      () async {
    final got = await repo.watchRecent().first;
    final album7 = got[2].entity as AlbumUI;
    final artist7 = got[1].entity as ArtistUI;
    expect((album7.id, album7.name), (7, 'Album 7'));
    expect((artist7.id, artist7.name), (7, 'Artist 7'));
  });
}
