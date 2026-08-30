import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/repositories/queue_repository.dart';

void main() {
  late AppDatabase db;
  late QueueRepository repo;
  late _LibraryFixture fixture;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = QueueRepository(db);
    fixture = _LibraryFixture(db);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'createSessionFromQuery uses canonical order when shuffle is off',
    () async {
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c', 'd', 'e'],
      );

      final sessionId = await repo.createSessionFromQuery(
        sourceType: 'album',
        sourceArtistId: 1,
        sourceAlbumId: 1,
        currentUuid: 'c',
        orderBy: [OrderParameter(column: 'track_number')],
      );

      final snapshot = await repo.getSessionSnapshot(sessionId);
      final entries = await repo.getPlaybackEntries(sessionId);

      expect(snapshot, isNotNull);
      expect(snapshot!.totalCount, 5);
      expect(snapshot.currentItem?.uuidId, 'c');
      expect(entries.map((entry) => entry.uuidId), ['a', 'b', 'c', 'd', 'e']);
      expect(entries.map((entry) => entry.playPosition), [0, 1, 2, 3, 4]);
      expect(entries.map((entry) => entry.canonicalPosition), [0, 1, 2, 3, 4]);
      expect(await _playOrderCount(db, sessionId), 5);
    },
  );

  test(
    'createSessionFromExplicitList preserves duplicates and current index',
    () async {
      await fixture.insertSingles(['a', 'b', 'c']);

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'a', 'c'],
        currentIndex: 2,
      );

      final snapshot = await repo.getSessionSnapshot(sessionId);
      final tracks = await repo.getSessionTracksInPlayOrder(sessionId);

      expect(snapshot?.totalCount, 4);
      expect(snapshot?.currentItem?.playPosition, 2);
      expect(tracks.map((entry) => entry.uuidId), ['a', 'b', 'a', 'c']);
      expect(tracks.map((entry) => entry.itemId).toSet().length, 4);
    },
  );

  test(
    'getSessionSnapshot falls back to first entry when current_item_id is null',
    () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'c'],
        currentIndex: 1,
      );

      await db.customStatement(
        'UPDATE queue_sessions SET current_item_id = NULL WHERE id = ?',
        [sessionId],
      );

      final snapshot = await repo.getSessionSnapshot(sessionId);
      expect(snapshot!.totalCount, 3);
      expect(snapshot.currentItem, isNotNull);
      expect(snapshot.currentItem!.uuidId, 'a');
    },
  );

  test(
    'getSessionSnapshot recovers when current_item_id points at a deleted track',
    () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'c'],
        currentIndex: 0,
      );

      // Drop the current track's row (as a tombstone sync would). The INNER
      // JOIN on tracks then resolves current_item_id to null; the snapshot must
      // recover to the first surviving entry rather than returning null.
      await db.customStatement("DELETE FROM tracks WHERE uuid_id = 'a'");

      final entry = await repo.getFirstPlayableEntry(sessionId);
      expect(entry!.uuidId, 'b');

      final snapshot = await repo.getSessionSnapshot(sessionId);
      expect(snapshot!.currentItem, isNotNull);
      expect(snapshot.currentItem!.uuidId, 'b');
    },
  );

  test(
    'replacePlayOrder changes effective order without rewriting canonical order',
    () async {
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c', 'd'],
      );

      final sessionId = await repo.createSessionFromQuery(
        sourceType: 'album',
        sourceArtistId: 1,
        sourceAlbumId: 1,
        currentUuid: 'b',
        orderBy: [OrderParameter(column: 'track_number')],
      );

      final canonicalBefore = await repo.getCanonicalItemIds(sessionId);
      final shuffled = [
        canonicalBefore[0],
        canonicalBefore[1],
        canonicalBefore[3],
        canonicalBefore[2],
      ];

      await repo.replacePlayOrder(sessionId, shuffled);
      await repo.updateShuffleEnabled(sessionId, true);

      final playOrder = await repo.getSessionTracksInPlayOrder(sessionId);
      final canonicalAfter = await repo.getCanonicalItemIds(sessionId);

      expect(playOrder.map((entry) => entry.uuidId), ['a', 'b', 'd', 'c']);
      expect(canonicalAfter, canonicalBefore);
    },
  );

  test('clearing play order falls back to canonical order', () async {
    await fixture.insertAlbum(
      artist: 'Artist',
      album: 'Album',
      uuids: ['a', 'b', 'c', 'd'],
    );
    await fixture.insertSingles(['x']);

    final sessionId = await repo.createSessionFromQuery(
      sourceType: 'album',
      sourceArtistId: 1,
      sourceAlbumId: 1,
      currentUuid: 'b',
      orderBy: [OrderParameter(column: 'track_number')],
    );

    final snapshot = await repo.getSessionSnapshot(sessionId);
    final currentItemId = snapshot!.currentItem!.itemId;

    await repo.prependManualItems(sessionId, const ['x']);
    await repo.rebuildFutureSuffix(
      sessionId,
      currentItemId: currentItemId,
      mainFutureItemIds: await repo.getFutureMainItemIds(
        sessionId,
        currentItemId: currentItemId,
        usePlayOrder: false,
      ),
    );

    final queued = await repo.getSessionTracksInPlayOrder(sessionId);
    expect(queued.map((entry) => entry.uuidId), ['a', 'b', 'x', 'c', 'd']);

    final futureMainIds = await repo.getFutureMainItemIds(
      sessionId,
      currentItemId: currentItemId,
      usePlayOrder: false,
    );
    await repo.updateShuffleEnabled(sessionId, true);
    await repo.rebuildFutureSuffix(
      sessionId,
      currentItemId: currentItemId,
      mainFutureItemIds: futureMainIds.reversed.toList(growable: false),
    );

    final shuffled = await repo.getSessionTracksInPlayOrder(sessionId);
    expect(shuffled.map((entry) => entry.uuidId), ['a', 'b', 'x', 'd', 'c']);

    await repo.updateShuffleEnabled(sessionId, false);
    await repo.rebuildFutureSuffix(
      sessionId,
      currentItemId: currentItemId,
      mainFutureItemIds: await repo.getFutureMainItemIds(
        sessionId,
        currentItemId: currentItemId,
        usePlayOrder: false,
      ),
    );

    final restored = await repo.getSessionTracksInPlayOrder(sessionId);
    expect(restored.map((entry) => entry.uuidId), ['a', 'b', 'x', 'c', 'd']);
    expect(await _playOrderCount(db, sessionId), 5);
  });

  test('prependManualItems inserts ahead of the main future', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'x', 'y']);

    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'custom',
      trackUuids: const ['a', 'b', 'c'],
      currentIndex: 1,
    );
    final current = (await repo.getSessionSnapshot(sessionId))!.currentItem!;

    await repo.prependManualItems(sessionId, const ['x', 'y']);
    await repo.rebuildFutureSuffix(
      sessionId,
      currentItemId: current.itemId,
      mainFutureItemIds: await repo.getFutureMainItemIds(
        sessionId,
        currentItemId: current.itemId,
        usePlayOrder: false,
      ),
    );

    final entries = await repo.getSessionTracksInPlayOrder(sessionId);

    expect(entries.map((entry) => entry.uuidId), ['a', 'b', 'x', 'y', 'c']);
    expect(entries.map((entry) => entry.playPosition), [0, 1, 2, 3, 4]);
    expect(
      entries
          .where((entry) => entry.queueType == QueueItemTypes.manual)
          .map((entry) => entry.canonicalPosition),
      [0, 1],
    );
  });

  test('removeItem shifts canonical and play positions safely', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'd']);

    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'custom',
      trackUuids: const ['a', 'b', 'c', 'd'],
      currentIndex: 2,
    );

    final entries = await repo.getPlaybackEntries(sessionId);
    await repo.removeItem(sessionId, entries[1].itemId);

    final updated = await repo.getSessionTracksInPlayOrder(sessionId);
    expect(updated.map((entry) => entry.uuidId), ['a', 'c', 'd']);
    expect(updated.map((entry) => entry.canonicalPosition), [0, 1, 2]);
    expect(updated.map((entry) => entry.playPosition), [0, 1, 2]);
  });

  test(
    'getPlaybackEntriesForItemIds returns updated play positions after shuffle',
    () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'custom',
        trackUuids: const ['a', 'b', 'c', 'd'],
        currentIndex: 0,
      );

      final entries = await repo.getPlaybackEntries(sessionId);
      await repo.replacePlayOrder(sessionId, [
        entries[2].itemId,
        entries[0].itemId,
        entries[3].itemId,
        entries[1].itemId,
      ]);
      await repo.updateShuffleEnabled(sessionId, true);

      final updated = await repo.getPlaybackEntriesForItemIds(
        sessionId,
        entries.map((entry) => entry.itemId),
      );

      final byUuid = {
        for (final entry in updated) entry.uuidId: entry.playPosition,
      };
      expect(byUuid, {'a': 1, 'b': 3, 'c': 0, 'd': 2});
    },
  );

  test('appendManualItems creates play order entries immediately', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'x', 'y']);

    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'custom',
      trackUuids: const ['a', 'b', 'c'],
      currentIndex: 0,
    );

    final beforeCount = await _playOrderCount(db, sessionId);
    expect(beforeCount, 3);

    await repo.appendManualItems(sessionId, const ['x', 'y']);

    final afterCount = await _playOrderCount(db, sessionId);
    expect(afterCount, 5);

    final manualIds = await repo.getQueueTypeItemIds(
      sessionId,
      QueueItemTypes.manual,
    );
    expect(manualIds, hasLength(2));
  });

  test('prependManualItems creates play order entries immediately', () async {
    await fixture.insertSingles(['a', 'b', 'x']);

    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'custom',
      trackUuids: const ['a', 'b'],
      currentIndex: 0,
    );

    await repo.prependManualItems(sessionId, const ['x']);

    final afterCount = await _playOrderCount(db, sessionId);
    expect(afterCount, 3);
  });

  test('createSessionFromQuery with no matching tracks throws', () async {
    expect(
      () => repo.createSessionFromQuery(
        sourceType: 'album',
        sourceArtistId: 999,
        sourceAlbumId: 999,
        currentUuid: 'nonexistent',
        orderBy: [OrderParameter(column: 'track_number')],
      ),
      throwsStateError,
    );
  });

  test(
    'createSessionFromQuery with downloadedOnly only inserts downloaded tracks',
    () async {
      // Two downloaded, three streaming-only.
      await fixture.insertSingles(['dl-1', 'stream-1', 'dl-2', 'stream-2', 'stream-3']);
      for (final uuid in const ['dl-1', 'dl-2']) {
        await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
            .write(TracksCompanion(filePath: Value('/tmp/$uuid.audio')));
      }

      final sessionId = await repo.createSessionFromQuery(
        sourceType: 'library',
        currentUuid: 'dl-1',
        orderBy: [OrderParameter(column: 'uuid_id')],
        downloadedOnly: true,
      );

      final entries = await repo.getPlaybackEntries(sessionId);
      expect(entries.map((e) => e.uuidId), ['dl-1', 'dl-2']);
    },
  );

  group('locally playable lookup', () {
    QueueRepository repoWithFs(Set<String> existing) {
      return QueueRepository(db, localFileExists: existing.contains);
    }

    Future<void> markDownloaded(String uuid, String path) async {
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
          .write(TracksCompanion(filePath: Value(path)));
    }

    test(
      'findNextLocallyPlayableEntry skips streaming-only entries forward',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        await markDownloaded('a', '/tmp/a');
        await markDownloaded('d', '/tmp/d');
        final existing = {'/tmp/a', '/tmp/d'};

        final localRepo = repoWithFs(existing);
        final sessionId = await localRepo.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c', 'd', 'e'],
          currentIndex: 0,
        );

        final next = await localRepo.findNextLocallyPlayableEntry(
          sessionId: sessionId,
          fromPlayPosition: 0,
          direction: PlayOrderDirection.forward,
          repeatMode: 'off',
          totalCount: 5,
        );

        expect(next?.uuidId, 'd');
      },
    );

    test(
      'findNextLocallyPlayableEntry searches backward when going to previous',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        await markDownloaded('a', '/tmp/a');
        await markDownloaded('e', '/tmp/e');
        final existing = {'/tmp/a', '/tmp/e'};

        final localRepo = repoWithFs(existing);
        final sessionId = await localRepo.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c', 'd', 'e'],
          currentIndex: 4,
        );

        final prev = await localRepo.findNextLocallyPlayableEntry(
          sessionId: sessionId,
          fromPlayPosition: 4,
          direction: PlayOrderDirection.backward,
          repeatMode: 'off',
          totalCount: 5,
        );

        expect(prev?.uuidId, 'a');
      },
    );

    test(
      'findNextLocallyPlayableEntry wraps when repeat mode is all',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);
        await markDownloaded('a', '/tmp/a');
        final existing = {'/tmp/a'};

        final localRepo = repoWithFs(existing);
        final sessionId = await localRepo.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c'],
          currentIndex: 0,
        );

        final wrapped = await localRepo.findNextLocallyPlayableEntry(
          sessionId: sessionId,
          fromPlayPosition: 0,
          direction: PlayOrderDirection.forward,
          repeatMode: 'all',
          totalCount: 3,
        );

        expect(wrapped?.uuidId, 'a');
      },
    );

    test(
      'findNextLocallyPlayableEntry returns null when nothing is playable',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);

        final localRepo = repoWithFs(const <String>{});
        final sessionId = await localRepo.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c'],
          currentIndex: 0,
        );

        final result = await localRepo.findNextLocallyPlayableEntry(
          sessionId: sessionId,
          fromPlayPosition: 0,
          direction: PlayOrderDirection.forward,
          repeatMode: 'all',
          totalCount: 3,
        );

        expect(result, isNull);
      },
    );

    test(
      'findNextLocallyPlayableEntry treats a db-only file_path as not playable',
      () async {
        await fixture.insertSingles(['a', 'b']);
        await markDownloaded('a', '/tmp/missing');
        await markDownloaded('b', '/tmp/present');

        final localRepo = repoWithFs({'/tmp/present'});
        final sessionId = await localRepo.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b'],
          currentIndex: 0,
        );

        final result = await localRepo.findNextLocallyPlayableEntry(
          sessionId: sessionId,
          fromPlayPosition: 0,
          direction: PlayOrderDirection.forward,
          repeatMode: 'off',
          totalCount: 2,
          includeStart: true,
        );

        expect(result?.uuidId, 'b');
      },
    );

    test('findLocallyPlayableFallback returns requested when playable', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      await markDownloaded('b', '/tmp/b');
      final existing = {'/tmp/b'};

      final localRepo = repoWithFs(existing);
      final sessionId = await localRepo.createSessionFromExplicitList(
        sourceType: 'custom',
        trackUuids: const ['a', 'b', 'c'],
        currentIndex: 1,
      );
      final preferred = (await localRepo.getSessionSnapshot(sessionId))!
          .currentItem!;

      final result = await localRepo.findLocallyPlayableFallback(
        sessionId: sessionId,
        preferredItemId: preferred.itemId,
        totalCount: 3,
      );

      expect(result?.uuidId, 'b');
    });

    test(
      'findLocallyPlayableFallback picks nearest playable when requested missing',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        await markDownloaded('a', '/tmp/a');
        await markDownloaded('e', '/tmp/e');
        final existing = {'/tmp/a', '/tmp/e'};

        final localRepo = repoWithFs(existing);
        final sessionId = await localRepo.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: const ['a', 'b', 'c', 'd', 'e'],
          currentIndex: 2,
        );
        final preferred = (await localRepo.getSessionSnapshot(sessionId))!
            .currentItem!;

        final result = await localRepo.findLocallyPlayableFallback(
          sessionId: sessionId,
          preferredItemId: preferred.itemId,
          totalCount: 5,
        );

        expect(result?.uuidId, 'e');
      },
    );
  });

  test(
    'getSessionTracksPage returns a bounded page in effective order',
    () async {
      await fixture.insertSingles(List.generate(12, (i) => 'track-${i + 1}'));

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'custom',
        trackUuids: List.generate(12, (i) => 'track-${i + 1}'),
        currentIndex: 5,
      );
      final entries = await repo.getPlaybackEntries(sessionId);
      await repo.replacePlayOrder(sessionId, [
        entries[5].itemId,
        entries[2].itemId,
        entries[8].itemId,
        entries[0].itemId,
        entries[1].itemId,
        entries[3].itemId,
        entries[4].itemId,
        entries[6].itemId,
        entries[7].itemId,
        entries[9].itemId,
        entries[10].itemId,
        entries[11].itemId,
      ]);
      await repo.updateShuffleEnabled(sessionId, true);

      final page = await repo.getSessionTracksPage(
        sessionId,
        startPlayPosition: 2,
        limit: 4,
      );

      expect(page, hasLength(4));
      expect(page.first.playPosition, 2);
      expect(page.last.playPosition, 5);
      expect(page.map((entry) => entry.uuidId), [
        'track-9',
        'track-1',
        'track-2',
        'track-4',
      ]);
    },
  );
}

Future<int> _playOrderCount(AppDatabase db, int sessionId) async {
  final row = await db
      .customSelect(
        'SELECT COUNT(*) AS c FROM queue_session_play_order WHERE session_id = ?',
        variables: [Variable.withInt(sessionId)],
      )
      .getSingle();
  return row.read<int>('c');
}

class _LibraryFixture {
  final AppDatabase db;
  int _nextArtistId = 1;
  int _nextAlbumId = 1;
  final Map<String, int> _artistIds = {};
  final Map<String, int> _albumIds = {};

  _LibraryFixture(this.db);

  Future<void> insertAlbum({
    required String artist,
    required String album,
    required List<String> uuids,
  }) async {
    final artistId = await _ensureArtist(artist);
    final albumId = await _ensureAlbum(artistId, album);
    for (var i = 0; i < uuids.length; i++) {
      await _insertTrack(
        uuid: uuids[i],
        artist: artist,
        artistId: artistId,
        album: album,
        albumId: albumId,
        trackNumber: i + 1,
      );
    }
  }

  Future<void> insertSingles(List<String> uuids) async {
    for (var i = 0; i < uuids.length; i++) {
      final artistName = 'Artist ${i + 1}';
      final artistId = await _ensureArtist(artistName);
      final albumId = await _ensureAlbum(artistId, 'Singles ${i + 1}');
      await _insertTrack(
        uuid: uuids[i],
        artist: artistName,
        artistId: artistId,
        album: 'Singles ${i + 1}',
        albumId: albumId,
        trackNumber: 1,
      );
    }
  }

  Future<int> _ensureArtist(String name) async {
    final key = name.toLowerCase();
    final existing = _artistIds[key];
    if (existing != null) return existing;

    final id = _nextArtistId++;
    await db
        .into(db.artists)
        .insert(ArtistsCompanion(id: Value(id), name: Value(name)));
    _artistIds[key] = id;
    return id;
  }

  Future<int> _ensureAlbum(int artistId, String name) async {
    final key = '$artistId:${name.toLowerCase()}';
    final existing = _albumIds[key];
    if (existing != null) return existing;

    final id = _nextAlbumId++;
    await db
        .into(db.albums)
        .insert(
          AlbumsCompanion(
            id: Value(id),
            name: Value(name),
            artistId: Value(artistId),
            year: const Value(2024),
            isSingleGrouping: const Value(false),
          ),
        );
    _albumIds[key] = id;
    return id;
  }

  Future<void> _insertTrack({
    required String uuid,
    required String artist,
    required int artistId,
    required String album,
    required int albumId,
    required int trackNumber,
  }) async {
    final dto = ClientTrackDto.fromJson({
      'uuid_id': uuid,
      'created_at': 1700000000 + trackNumber,
      'last_updated': 1700000100 + trackNumber,
      'revision': 1700000000 + trackNumber,
      'metadata': {
        'title': 'Track $uuid',
        'artist': artist,
        'album': album,
        'artist_id': artistId,
        'album_id': albumId,
        'track_number': trackNumber,
        'disc_number': 1,
        'duration': 180.0,
        'bitrate_kbps': 320.0,
        'sample_rate_hz': 44100,
        'channels': 2,
        'has_album_art': false,
      },
    });

    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  }
}
