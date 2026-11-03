import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/collection_ordering.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/library_actions.dart';

import 'browse_harness.dart';

/// Records the manager calls instead of downloading.
class _RecordingDownloads extends DownloadManager {
  _RecordingDownloads(AppDatabase db, LocalCoverArtStore store, Directory dir)
    : super(db: db, coverArtStore: store, directoryProvider: () async => dir);

  /// `kind:uuid,uuid:quality` (records holding lists aren't deep-equal).
  final calls = <String>[];

  @override
  Future<void> enqueueTracks(List<TrackUI> tracks, {required String quality}) async =>
      calls.add('enqueue:${tracks.map((t) => t.uuidId).join(',')}:$quality');

  @override
  Future<void> enqueueTracksAtQuality(
    List<TrackUI> tracks, {
    required String quality,
    bool force = false,
  }) async => calls.add('atQuality:${tracks.map((t) => t.uuidId).join(',')}:$quality');

  @override
  Future<void> deleteDownloadsForUuids(Iterable<String> uuids) async =>
      calls.add('delete:${uuids.join(',')}');
}

/// The real repository, recording what connectivity the controller passed.
class _SpyRepository extends BrowseRepository {
  _SpyRepository(super.db);
  final offlineArgs = <bool>[];

  @override
  Future<List<TrackUI>> getTracksForScope(
    LibraryScope scope, {
    required bool offline,
  }) {
    offlineArgs.add(offline);
    return super.getTracksForScope(scope, offline: offline);
  }
}

void main() {
  late AppDatabase db;
  late Directory dir;
  late _RecordingDownloads downloads;
  late _SpyRepository repo;
  late RecordingAudio audio;
  late TestOffline offline;
  late ProviderContainer container;

  // Album 2 (2010) is first in artist 1's grid; its tracks are inserted out
  // of order.
  const seed = [
    SeedTrack(uuid: 'a1', title: 'a1', artistId: 1, artist: 'Ann',
        albumId: 1, album: 'Old', albumYear: 2001),
    SeedTrack(uuid: 'n2', title: 'n2', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'New', albumYear: 2010, trackNumber: 2),
    SeedTrack(uuid: 'n1', title: 'n1', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'New', albumYear: 2010, trackNumber: 1),
  ];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, seed);
    dir = await Directory.systemTemp.createTemp('library-actions');
    final store = await LocalCoverArtStore.create(
      directoryProvider: () async => dir,
    );
    downloads = _RecordingDownloads(db, store, dir);
    repo = _SpyRepository(db);
    audio = RecordingAudio();
    offline = TestOffline(false);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        browseRepositoryProvider.overrideWithValue(repo),
        downloadManagerProvider.overrideWithValue(downloads),
        audioProvider.overrideWith(() => audio),
        offlineModeProvider.overrideWith(() => offline),
        downloadQualityProvider.overrideWithValue('320'),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  LibraryActionControls actions() => container.read(libraryActionsProvider);

  Future<Map<String, TrackUI>> tracksByUuid() async => {
    for (final t in await repo.watchTracks().first) t.uuidId: t,
  };

  test('Play next on an album queues its tracks in album order', () async {
    await actions().playNext(const AlbumScope(artistId: 1, albumId: 2));
    expect(audio.calls, [
      {'method': 'playNext', 'uuids': ['n1', 'n2']},
    ]);
  });

  test('Add to queue on an artist follows the grid, then album order',
      () async {
    await actions().addToQueue(const ArtistScope(artistId: 1));
    expect(audio.calls, [
      {'method': 'addToQueue', 'uuids': ['n1', 'n2', 'a1']},
    ]);
  });

  test('a scope with no members submits nothing', () async {
    await actions().playNext(const AlbumScope(artistId: 1, albumId: 99));
    await actions().addToQueue(const ArtistScope(artistId: 42));
    expect(audio.calls, isEmpty);
  });

  test('the controller passes the observed offline state to the model',
      () async {
    container.read(offlineModeProvider);
    offline.set(true);
    await actions().playNext(const AlbumScope(artistId: 1, albumId: 2));
    offline.set(false);
    await actions().download(const AlbumScope(artistId: 1, albumId: 2));
    expect(repo.offlineArgs, [true, false]);
  });

  test('Play from a list starts the explicit list at the chosen track',
      () async {
    final t = await tracksByUuid();
    await actions().playFromList(
      [t['n2']!, t['a1']!, t['n1']!],
      1,
      source: 'search',
    );
    expect(audio.calls, [
      {
        'method': 'playFromTrackList',
        'uuids': ['n2', 'a1', 'n1'],
        'uuid': 'a1',
        'sourceType': 'search',
      },
    ]);
  });

  test('a row tap in an album queues the album query in album order',
      () async {
    final t = await tracksByUuid();
    await actions().playQuery(
      t['n2']!,
      album: const AlbumScope(artistId: 1, albumId: 2),
      downloadedOnly: false,
    );
    final call = audio.calls.single;
    expect(call['method'], 'playFromQueue');
    expect(call['uuid'], 'n2');
    expect(call['sourceType'], 'album');
    expect(call['artistId'], 1);
    expect(call['albumId'], 2);
    expect(identical(call['orderParams'], CollectionOrdering.albumTracks),
        isTrue);
    expect(call['downloadedOnly'], false);
  });

  test('a row tap in the library queues the library query, filter kept',
      () async {
    final t = await tracksByUuid();
    await actions().playQuery(t['a1']!, downloadedOnly: true);
    final call = audio.calls.single;
    expect(call['sourceType'], 'library');
    expect(call['artistId'], isNull);
    expect(call['albumId'], isNull);
    expect(identical(call['orderParams'], CollectionOrdering.libraryTracks),
        isTrue);
    expect(call['downloadedOnly'], true);
  });

  test('Download uses the default quality; Download at quality overrides it',
      () async {
    await actions().download(const AlbumScope(artistId: 1, albumId: 2));
    await actions().downloadAtQuality(const ArtistScope(artistId: 1), '128');
    expect(downloads.calls, [
      'enqueue:n1,n2:320',
      'atQuality:n1,n2,a1:128',
    ]);
  });

  test('Delete downloads deletes every member, a single track included',
      () async {
    final t = await tracksByUuid();
    await actions().deleteDownloads(const AlbumScope(artistId: 1, albumId: 2));
    await actions().deleteDownloads(TrackScope(t['a1']!));
    await actions().deleteDownloads(const AlbumScope(artistId: 1, albumId: 99));
    expect(downloads.calls, [
      'delete:n1,n2',
      'delete:a1',
    ]);
  });

  test('Play from a list ignores an empty list or an out-of-range start',
      () async {
    final t = await tracksByUuid();
    await actions().playFromList(const [], 0, source: 'search');
    await actions().playFromList([t['a1']!], 1, source: 'search');
    await actions().playFromList([t['a1']!], -1, source: 'search');
    expect(audio.calls, isEmpty);
  });

  test('Play next on a compilation queues track order, not artist order',
      () async {
    await seedLibrary(db, const [
      // Artist, title and uuid orders all disagree with track numbers.
      SeedTrack(uuid: 'c-a', title: 'Aa', artistId: 9, artist: 'Amy',
          albumId: 5, album: 'Hits', trackNumber: 2),
      SeedTrack(uuid: 'c-z', title: 'Zz', artistId: 9, artist: 'Zed',
          albumId: 5, album: 'Hits', trackNumber: 1),
    ]);
    await actions().playNext(const AlbumScope(artistId: 9, albumId: 5));
    expect(audio.calls, [
      {'method': 'playNext', 'uuids': ['c-z', 'c-a']},
    ]);
  });
}
