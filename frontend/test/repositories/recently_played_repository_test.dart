// Phase 6 §6 / 6-U06, 6-R01, 6-R02 (unit halves): the eligible, deduped
// recents query. Expected refs and orders are written out by hand from
// each test's own seed, never derived from the production CTE.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

import '../helpers/server_binding.dart';
import 'catalog_seed.dart';

/// `type:ref` of each SQL-stage row.
List<String> _keys(List<RecentRef> refs) =>
    [for (final r in refs) '${r.type.name}:${r.ref}'];

void main() {
  late AppDatabase db;
  late CatalogSeed seed;
  late RecentlyPlayedRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    seed = CatalogSeed(db);
    repo = RecentlyPlayedRepository(db, BrowseRepository(db));
    await seed.artist(1, 'Aria');
    await seed.album(1, artistId: 1, name: 'One');
  });

  tearDown(() => db.close());

  Future<List<String>> eligible({
    int limit = 20,
    bool downloadedOnly = false,
  }) async => _keys(
    await repo.eligibleRefs(limit: limit, downloadedOnly: downloadedOnly),
  );

  group('tracks, dedupe and order', () {
    setUp(() async {
      for (final u in ['t1', 't2', 't3', 't4']) {
        await seed.track(u, artistId: 1, albumId: 1);
      }
    });

    test('one entry per entity, represented by its newest click', () async {
      await seed.click('track', 't1', at: 100, eventUuid: 'e1');
      await seed.click('track', 't1', at: 300, eventUuid: 'e2');
      await seed.click('track', 't2', at: 250, eventUuid: 'e3');
      await seed.click('track', 't1', at: 200, eventUuid: 'e4');
      final refs = await repo.eligibleRefs(limit: 20);
      expect(_keys(refs), ['track:t1', 'track:t2']);
      expect(refs.first.occurredAt, 300);
      expect(refs.first.eventUuid, 'e2');
      expect(
        refs.first,
        const RecentRef(
          type: RecentEntityType.track,
          ref: 't1',
          occurredAt: 300,
          eventUuid: 'e2',
        ),
      );
    });

    test('equal timestamps order by event uuid descending, binary, '
        'regardless of insertion order', () async {
      // Binary: 'e-a' (0x61) > 'e-B' (0x42); NOCASE would flip them.
      await seed.click('track', 't1', at: 100, eventUuid: 'e-B');
      await seed.click('track', 't2', at: 100, eventUuid: 'e-a');
      await seed.click('track', 't3', at: 100, eventUuid: 'e-C');
      expect(await eligible(), ['track:t2', 'track:t3', 'track:t1']);
    });

    test('within one entity, an equal-time tie keeps the larger event uuid '
        'as the representative', () async {
      await seed.click('track', 't1', at: 100, eventUuid: 'e-x');
      await seed.click('track', 't1', at: 100, eventUuid: 'e-y');
      final refs = await repo.eligibleRefs(limit: 20);
      expect(refs.single.eventUuid, 'e-y');
    });

    test('only clicked events count', () async {
      await seed.click('track', 't1', at: 100);
      await seed.click('track', 't2', at: 900, kind: 'played');
      expect(await eligible(), ['track:t1']);
    });

    test('unknown entity types are dropped (case-sensitive)', () async {
      await seed.click('track', 't1', at: 100);
      await seed.click('Track', 't2', at: 200);
      await seed.click('playlist', 't3', at: 300);
      await seed.click('', 't4', at: 400);
      expect(await eligible(), ['track:t1']);
    });

    test('a track ref must match an existing synced track exactly', () async {
      await seed.click('track', 't1', at: 100);
      await seed.click('track', 'T1', at: 200); // case differs
      await seed.click('track', 't1 ', at: 300); // trailing space
      await seed.click('track', 'gone', at: 400); // never synced / deleted
      // A tracks row without metadata never hydrates, so it is not eligible.
      await db.customStatement(
        "INSERT INTO tracks (uuid_id, created_at, last_updated) "
        "VALUES ('bare', 1, 1)",
      );
      await seed.click('track', 'bare', at: 500);
      expect(await eligible(), ['track:t1']);
    });

    test('the limit applies after dedupe: a dominant repeat takes one slot',
        () async {
      for (var i = 0; i < 30; i++) {
        await seed.click('track', 't1', at: 1000 + i);
      }
      await seed.click('track', 't2', at: 50);
      await seed.click('track', 't3', at: 40);
      expect(await eligible(limit: 2), ['track:t1', 'track:t2']);
    });

    test('the limit applies after eligibility: invalid newest rows never '
        'starve valid older ones', () async {
      for (var i = 0; i < 25; i++) {
        await seed.track('v$i', artistId: 1, albumId: 1);
        await seed.click('track', 'v$i', at: 100 + i);
      }
      // 30 newer rows that can't resolve.
      for (var i = 0; i < 10; i++) {
        await seed.click('track', 'missing-$i', at: 1000 + i);
        await seed.click('podcast', 'v$i', at: 1100 + i);
        await seed.click('album', 'bare-$i', at: 1200 + i);
      }
      expect(await eligible(), [for (var i = 24; i >= 5; i--) 'track:v$i']);
    });
  });

  group('collection refs', () {
    const instance = 'srv-1';

    setUp(() async {
      await seedTestBinding(db, instanceId: instance, reconciled: true);
      // Artist 7 and album 7 share the number; album 7 belongs to artist 1.
      await seed.artist(7, 'Seven');
      await seed.album(7, artistId: 1, name: 'Album Seven');
      // Bait for lossy parsing: what CAST would turn a bad ref into.
      await seed.album(9223372036854775807, artistId: 1, name: 'Max');
      await seed.track('t1', artistId: 1, albumId: 1);
    });

    test('a canonical ref under the bound prefix resolves by its own type; '
        'the same number as album and artist are two entries', () async {
      await seed.click('album', '$instance:7', at: 300);
      await seed.click('artist', '$instance:7', at: 200);
      await seed.click('album', '$instance:1', at: 100);
      await seed.click('artist', '$instance:1', at: 90);
      expect(await eligible(), [
        'album:srv-1:7',
        'artist:srv-1:7',
        'album:srv-1:1',
        'artist:srv-1:1',
      ]);
    });

    test('the largest canonical id resolves', () async {
      await seed.click('album', '$instance:9223372036854775807', at: 100);
      expect(await eligible(), ['album:srv-1:9223372036854775807']);
    });

    test('malformed, foreign and bare refs never resolve, even when a lossy '
        'cast would hit an existing row', () async {
      final bad = [
        '$instance:0',
        '$instance:-1',
        '$instance:01',
        '$instance:+1',
        '$instance: 1',
        '$instance:1 ',
        '$instance:1.0',
        '$instance:1e0',
        '$instance:1a',
        '$instance:abc',
        '$instance:',
        '$instance:1:1',
        '$instance:99999999999999999999', // overflows to the Max row
        '$instance:0009223372036854775807',
        'SRV-1:1',
        'srv-10:1',
        'srv-:1',
        'other:1',
        ':1',
        '1',
        '7',
        '',
      ];
      var at = 1000;
      for (final ref in bad) {
        await seed.click('album', ref, at: at++);
        await seed.click('artist', ref, at: at++);
      }
      await seed.click('album', '$instance:1', at: 10);
      expect(await eligible(limit: 100), ['album:srv-1:1']);
    });

    test('collection refs need catalog readiness; tracks do not', () async {
      await db.delete(db.serverBinding).go();
      await seedTestBinding(db, instanceId: instance);
      await seed.click('album', '$instance:1', at: 200);
      await seed.click('track', 't1', at: 100);
      expect(await eligible(), ['track:t1']);
    });

    test('a binding without an instance id resolves no collection', () async {
      await db.delete(db.serverBinding).go();
      await seedTestBinding(db, instanceId: null, reconciled: true);
      expect((await ServerBindingRepository(db).current())?.instanceId, isNull,
          reason: 'precondition: the row has no instance id');
      // An empty instance part must not match the missing id.
      await seed.click('album', ':1', at: 300);
      await seed.click('album', '$instance:1', at: 200);
      await seed.click('track', 't1', at: 100);
      expect(await eligible(), ['track:t1']);
    });

    test('no binding row resolves no collection', () async {
      await db.delete(db.serverBinding).go();
      await seed.click('artist', '$instance:1', at: 200);
      await seed.click('track', 't1', at: 100);
      expect(await eligible(), ['track:t1']);
    });

    test('a deleted album or artist, and an album whose artist row is '
        'missing, are dropped', () async {
      await seed.album(50, artistId: 404, name: 'Orphan');
      await seed.click('album', '$instance:50', at: 400);
      await seed.click('album', '$instance:51', at: 300);
      await seed.click('artist', '$instance:52', at: 200);
      await seed.click('album', '$instance:1', at: 100);
      expect(await eligible(), ['album:srv-1:1']);
    });
  });

  group('downloadedOnly', () {
    setUp(() async {
      await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
      await seed.artist(2, 'Bram'); // partial
      await seed.artist(3, 'Cleo'); // none
      await seed.artist(4, 'Dara'); // only damaged
      await seed.album(2, artistId: 2, name: 'Partial');
      await seed.album(3, artistId: 3, name: 'Remote');
      await seed.album(4, artistId: 4, name: 'Damaged');
      await seed.album(5, artistId: 2, name: 'Full');
      await seed.track('p1', artistId: 2, albumId: 2, downloaded: true);
      await seed.track('p2', artistId: 2, albumId: 2);
      await seed.track('r1', artistId: 3, albumId: 3);
      await seed.track('d1', artistId: 4, albumId: 4, damaged: true);
      await seed.track('f1', artistId: 2, albumId: 5, downloaded: true);
      var at = 100;
      for (final (type, ref) in [
        ('track', 'p1'),
        ('track', 'p2'),
        ('track', 'd1'),
        ('album', 'srv-1:2'),
        ('album', 'srv-1:3'),
        ('album', 'srv-1:4'),
        ('album', 'srv-1:5'),
        ('artist', 'srv-1:2'),
        ('artist', 'srv-1:3'),
        ('artist', 'srv-1:4'),
      ]) {
        await seed.click(type, ref, at: at--);
      }
    });

    test('off: everything resolvable', () async {
      expect(await eligible(), hasLength(10));
    });

    test('on: usable downloads only; a collection qualifies with any usable '
        'member (partial or full), never with only damaged ones', () async {
      expect(await eligible(downloadedOnly: true), [
        'track:p1',
        'album:srv-1:2',
        'album:srv-1:5',
        'artist:srv-1:2',
      ]);
    });
  });
}
