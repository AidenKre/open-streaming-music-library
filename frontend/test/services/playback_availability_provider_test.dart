import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download_providers.dart';

import '../ui/browse_harness.dart';

/// Real in-memory DB whose batched count queries can be held open and are
/// counted, to prove "unknown while loading" and "one grouped query".
class _GatedDb extends AppDatabase {
  _GatedDb() : super(NativeDatabase.memory());

  Completer<void>? gate;
  int albumCountQueries = 0;
  int artistCountQueries = 0;

  @override
  Future<Map<int, ({int total, int downloaded})>>
  getAllAlbumDownloadCounts() async {
    albumCountQueries++;
    await gate?.future;
    return super.getAllAlbumDownloadCounts();
  }

  @override
  Future<Map<int, ({int total, int downloaded})>>
  getAllArtistDownloadCounts() async {
    artistCountQueries++;
    await gate?.future;
    return super.getAllArtistDownloadCounts();
  }
}

void main() {
  late _GatedDb db;
  late TestOffline offline;
  late StreamController<int> versions;
  late ProviderContainer container;

  // Album 1 (artist 1): fully downloaded. Album 2 (artist 1): 1 of 2.
  // Album 3 (artist 2): nothing downloaded.
  const seed = [
    SeedTrack(uuid: 'a', title: 'a', artistId: 1, artist: 'Ann', albumId: 1,
        album: 'One', downloaded: true),
    SeedTrack(uuid: 'b', title: 'b', artistId: 1, artist: 'Ann', albumId: 2,
        album: 'Two', downloaded: true),
    SeedTrack(uuid: 'c', title: 'c', artistId: 1, artist: 'Ann', albumId: 2,
        album: 'Two', trackNumber: 2),
    SeedTrack(uuid: 'd', title: 'd', artistId: 2, artist: 'Bo', albumId: 3,
        album: 'Three'),
  ];

  setUp(() async {
    db = _GatedDb();
    await seedLibrary(db, seed);
    offline = TestOffline(true);
    versions = StreamController<int>();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        offlineModeProvider.overrideWith(() => offline),
        downloadStatusVersionProvider.overrideWith((ref) => versions.stream),
      ],
    );
    versions.add(0);
  });

  tearDown(() async {
    container.dispose();
    // Not awaited: a never-listened single-subscription controller's close()
    // only completes once someone listens.
    unawaited(versions.close());
    await db.close();
  });

  PlaybackAvailability read(LibraryScope scope) =>
      container.read(playbackAvailabilityProvider(scope));

  /// Keeps the auto-dispose family element alive and lets it settle.
  Future<PlaybackAvailability> settle(LibraryScope scope) async {
    container.listen(playbackAvailabilityProvider(scope), (_, _) {});
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return read(scope);
  }

  test('unknown while the batched counts load, never zero', () async {
    db.gate = Completer<void>();
    const album = AlbumScope(artistId: 1, albumId: 1);
    container.listen(playbackAvailabilityProvider(album), (_, _) {});
    await Future<void>.delayed(Duration.zero);
    expect(read(album), const PlaybackAvailability.unknown(offline: true));
    expect(read(album).canPlay, isFalse);
    db.gate!.complete();
    expect(
      await settle(album),
      PlaybackAvailability.of(offline: true, downloaded: 1, total: 1),
    );
  });

  test('album and artist scopes come from the batched counts', () async {
    expect(
      (await settle(const AlbumScope(artistId: 1, albumId: 1))).coverage,
      LocalCoverage.downloaded,
    );
    final afterFirstCard = db.albumCountQueries;
    expect(
      (await settle(const AlbumScope(artistId: 1, albumId: 2))).coverage,
      LocalCoverage.partial,
    );
    expect(
      (await settle(const AlbumScope(artistId: 2, albumId: 3))).coverage,
      LocalCoverage.remote,
    );
    expect(
      (await settle(const ArtistScope(artistId: 1))).coverage,
      LocalCoverage.partial,
    );
    final afterFirstArtist = db.artistCountQueries;
    expect(
      (await settle(const ArtistScope(artistId: 2))).coverage,
      LocalCoverage.remote,
    );
    // More cards never mean more queries: one grouped read serves them all.
    expect(db.albumCountQueries, afterFirstCard);
    expect(db.artistCountQueries, afterFirstArtist);
  });

  test('an album missing from the counts map is unknown, not 0/0', () async {
    // The map is only recomputed on download events, so an album synced
    // after it was computed is absent until the next one.
    expect(
      await settle(const AlbumScope(artistId: 1, albumId: 99)),
      const PlaybackAvailability.unknown(offline: true),
    );
    expect(
      container.read(albumDownloadCountsProvider(99)).value,
      isNull,
    );
  });

  test('track scopes are computed from the rows', () async {
    final tracks = await BrowseRepository(db).watchTracks().first;
    final byUuid = {for (final t in tracks) t.uuidId: t};
    expect((await settle(TrackScope(byUuid['a']!))).canPlay, isTrue);
    expect((await settle(TrackScope(byUuid['c']!))).canPlay, isFalse);
    final mixed = await settle(TracksScope([byUuid['a']!, byUuid['c']!]));
    expect(mixed.coverage, LocalCoverage.partial);
    // No count query is needed for rows.
    expect(db.albumCountQueries + db.artistCountQueries, 0);
  });

  test('going online re-derives availability', () async {
    const scope = AlbumScope(artistId: 2, albumId: 3);
    expect((await settle(scope)).canPlay, isFalse);
    offline.set(false);
    expect((await settle(scope)).canPlay, isTrue);
  });

  test('while counts reload after a download, the last known value holds',
      () async {
    const scope = AlbumScope(artistId: 2, albumId: 3);
    expect((await settle(scope)).coverage, LocalCoverage.remote);
    db.gate = Completer<void>();
    await markDownloaded(db, 'd');
    versions.add(1);
    final during = await settle(scope);
    // Previous data while reloading: known and unchanged, never a fresh 0/0.
    expect(during, PlaybackAvailability.of(offline: true, downloaded: 0, total: 1));
    db.gate!.complete();
    expect((await settle(scope)).coverage, LocalCoverage.downloaded);
  });
}
