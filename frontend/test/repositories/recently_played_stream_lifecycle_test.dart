// 6B.1 review r1 (findings 1, 2, 4): the live recents stream honours
// pause, coalesces bursts into one follow-up read, forwards errors and
// recovers, and starts no read after cancel.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';

import 'catalog_seed.dart';

/// Counts reads (each read hydrates tracks once) and can make a read fail.
class _ProbeBrowse extends BrowseRepository {
  _ProbeBrowse(super.db);

  int reads = 0;
  Object? failWith;

  @override
  Future<List<TrackUI>> getTracksByUuids(List<String> uuids) async {
    reads++;
    final f = failWith;
    if (f != null) throw f;
    return super.getTracksByUuids(uuids);
  }
}

void main() {
  late AppDatabase db;
  late CatalogSeed seed;
  late _ProbeBrowse browse;
  late RecentlyPlayedRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    seed = CatalogSeed(db);
    browse = _ProbeBrowse(db);
    repo = RecentlyPlayedRepository(db, browse);
    await seed.artist(1, 'Aria');
    await seed.album(1, artistId: 1, name: 'One');
    await seed.track('a', artistId: 1, albumId: 1);
    await seed.track('b', artistId: 1, albumId: 1);
    await seed.click('track', 'a', at: 100);
  });

  tearDown(() => db.close());

  List<String> uuids(List<ResolvedRecent> rs) =>
      [for (final r in rs) (r.entity as TrackUI).uuidId];

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
  }

  test('while paused, writes run no read; resume reads once and emits the '
      'latest state only', () async {
    final got = <List<String>>[];
    final sub = repo.watchRecent().listen((v) => got.add(uuids(v)));
    await settle();
    expect(got, [
      ['a'],
    ]);
    final readsBefore = browse.reads;

    sub.pause();
    for (var i = 0; i < 5; i++) {
      await seed.click('track', i.isEven ? 'b' : 'a', at: 200 + i);
    }
    await settle();
    expect(browse.reads, readsBefore, reason: 'no read while paused');

    sub.resume();
    await settle();
    expect(browse.reads, readsBefore + 1);
    expect(got, [
      ['a'],
      ['b', 'a'],
    ]);
    await sub.cancel();
  });

  test('a burst of writes coalesces: reads do not grow with the writes, '
      'and the last emission is the latest state', () async {
    final got = <List<String>>[];
    final sub = repo.watchRecent().listen((v) => got.add(uuids(v)));
    await settle();
    final readsBefore = browse.reads;

    // Ten writes queued at once: the first update starts a read; the rest
    // land while it is in flight and fold into one follow-up read.
    await Future.wait([
      for (var i = 0; i < 10; i++)
        seed.click('track', i.isEven ? 'a' : 'b', at: 300 + i),
    ]);
    await settle();
    expect(browse.reads - readsBefore, lessThanOrEqualTo(3));
    expect(got.last, ['b', 'a']);
    await sub.cancel();
  });

  test('a failed read reaches onError and the next write recovers',
      () async {
    final got = <List<String>>[];
    final errors = <Object>[];
    final sub = repo.watchRecent().listen(
      (v) => got.add(uuids(v)),
      onError: errors.add,
    );
    await settle();
    browse.failWith = StateError('boom');
    await seed.click('track', 'b', at: 200);
    await settle();
    expect(errors, [isA<StateError>()]);
    browse.failWith = null;
    await seed.click('track', 'a', at: 300);
    await settle();
    expect(got.last, ['a', 'b']);
    await sub.cancel();
  });

  test('after cancel, writes start no read', () async {
    final sub = repo.watchRecent().listen((_) {});
    await settle();
    await sub.cancel();
    final readsBefore = browse.reads;
    await seed.click('track', 'b', at: 200);
    await settle();
    expect(browse.reads, readsBefore);
  });
}
