// Phase 6 §6 / 6-U07 (readsFrom), D10: the live Home stream re-evaluates
// on every table eligibility or hydration reads, through the app's own
// writers, without a new click.
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

import '../helpers/server_binding.dart';
import 'catalog_seed.dart';

/// `type:id:label:art` per card, plus a track's download state as `1/1`
/// (downloaded) or `0/1`: what a card shows.
String _card(ResolvedRecent r) => switch (r.entity) {
  TrackUI(:final uuidId, :final title, :final coverArtId, :final isDownloaded) =>
    'track:$uuidId:$title:$coverArtId:${isDownloaded ? 1 : 0}/1',
  AlbumUI(:final id, :final name, :final coverArtId) =>
    'album:$id:$name:$coverArtId',
  ArtistUI(:final id, :final name, :final coverArtId) =>
    'artist:$id:$name:$coverArtId',
  _ => 'unexpected',
};

/// One subscription; every emission is kept so a test can wait for the
/// next state matching its expectation.
class _Recorder {
  _Recorder(Stream<List<ResolvedRecent>> stream) {
    _sub = stream.listen((v) {
      emissions.add(v.map(_card).toList());
      _check();
    }, onError: (Object e) => error = e);
  }

  late final StreamSubscription<List<ResolvedRecent>> _sub;
  final emissions = <List<String>>[];
  Object? error;
  ({bool Function(List<String>) test, Completer<List<String>> done})? _wait;

  void _check() {
    final w = _wait;
    if (w != null && emissions.isNotEmpty && w.test(emissions.last)) {
      _wait = null;
      w.done.complete(emissions.last);
    }
  }

  /// Completes with the first emission (current or later) equal to [want].
  Future<List<String>> until(List<String> want) {
    final c = Completer<List<String>>();
    _wait = (test: (v) => listEquals(v, want), done: c);
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

bool listEquals(List<String> a, List<String> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

void main() {
  late AppDatabase db;
  late CatalogSeed seed;
  late RecentlyPlayedRepository repo;
  late String token;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    seed = CatalogSeed(db);
    repo = RecentlyPlayedRepository(db, BrowseRepository(db));
    token = await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    await seed.artist(1, 'Aria');
    await seed.album(1, artistId: 1, name: 'One');
    await seed.track('a', artistId: 1, albumId: 1, title: 'Song A', art: 5);
    await seed.track('b', artistId: 1, albumId: 1, trackNumber: 2);
    await seed.click('album', 'srv-1:1', at: 300);
    await seed.click('track', 'a', at: 200);
  });

  tearDown(() => db.close());

  const initial = ['album:1:One:5', 'track:a:Song A:5:0/1'];

  test('emits the current recents, then a new click', () async {
    final rec = _Recorder(repo.watchRecent());
    await rec.until(initial);
    await seed.click('track', 'b', at: 400);
    await rec.until(['track:b:Track b:null:0/1', ...initial]);
    await rec.cancel();
  });

  test('download completion and removal (tracks) re-emit, and drive '
      'downloaded-only membership', () async {
    final all = _Recorder(repo.watchRecent());
    final local = _Recorder(repo.watchRecent(downloadedOnly: true));
    await all.until(initial);
    await local.until(const []);

    // The download commit writes the file columns on `tracks`.
    await (db.update(db.tracks)..where((t) => t.uuidId.equals('a'))).write(
      const TracksCompanion(filePath: Value('/local/a.flac')),
    );
    await all.until(['album:1:One:5', 'track:a:Song A:5:1/1']);
    await local.until(['album:1:One:5', 'track:a:Song A:5:1/1']);

    // The shared clear path used by delete/reset.
    await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
        .write(clearedDownloadColumns);
    await all.until(initial);
    await local.until(const []);
    await all.cancel();
    await local.cancel();
  });

  test('a metadata rename and an art change (trackmetadata) re-emit '
      'without a click', () async {
    final rec = _Recorder(repo.watchRecent());
    await rec.until(initial);
    // The edit path keeps the FTS index current, so index the seed first
    // (sync does this for real catalogs).
    await db.rebuildFtsIndexes();
    await db.applyOptimisticTrackEdit('a', {'title': 'Renamed'});
    await rec.until(['album:1:One:5', 'track:a:Renamed:5:0/1']);
    await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
        .write(const TrackmetadataCompanion(coverArtId: Value(9)));
    await rec.until(['album:1:One:9', 'track:a:Renamed:9:0/1']);
    await rec.cancel();
  });

  test('album and artist rows (albums, artists) re-emit', () async {
    await seed.click('artist', 'srv-1:1', at: 100);
    final rec = _Recorder(repo.watchRecent());
    await rec.until([...initial, 'artist:1:Aria:5']);
    await (db.update(db.albums)..where((a) => a.id.equals(1))).write(
      const AlbumsCompanion(name: Value('Uno')),
    );
    await (db.update(db.artists)..where((a) => a.id.equals(1))).write(
      const ArtistsCompanion(name: Value('Arya')),
    );
    await rec.until([
      'album:1:Uno:5',
      'track:a:Song A:5:0/1',
      'artist:1:Arya:5',
    ]);
    await rec.cancel();
  });

  test('a deleted member track disappears and the album card updates',
      () async {
    final rec = _Recorder(repo.watchRecent());
    await rec.until(initial);
    await db.transaction(() async {
      await (db.delete(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
          .go();
      await (db.delete(db.tracks)..where((t) => t.uuidId.equals('a'))).go();
    });
    await rec.until(['album:1:One:null']);
    await rec.cancel();
  });

  test('a readiness flip (server_binding) hides and restores collection '
      'recents', () async {
    final binding = ServerBindingRepository(db);
    final rec = _Recorder(repo.watchRecent());
    await rec.until(initial);
    await binding.clearCatalogReconciled(token);
    await rec.until(['track:a:Song A:5:0/1']);
    await binding.runFenced(token, binding.markCatalogReconciledInTransaction);
    await rec.until(initial);
    await rec.cancel();
  });

  test('a burst of writes settles on the latest state', () async {
    final rec = _Recorder(repo.watchRecent(limit: 1));
    await rec.until(['album:1:One:5']);
    for (var i = 0; i < 10; i++) {
      unawaited(seed.click('track', i.isEven ? 'a' : 'b', at: 1000 + i));
    }
    await rec.until(['track:b:Track b:null:0/1']);
    await pumpEventQueue();
    expect(rec.emissions.last, ['track:b:Track b:null:0/1']);
    await rec.cancel();
  });

  test('the provider builds the repository from the scope\'s database', () {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final a = container.read(recentlyPlayedRepositoryProvider);
    expect(a, isA<RecentlyPlayedRepository>());
    // A second scope gets its own instance: nothing process-global.
    final other = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(other.dispose);
    expect(identical(other.read(recentlyPlayedRepositoryProvider), a), isFalse);
  });
}
