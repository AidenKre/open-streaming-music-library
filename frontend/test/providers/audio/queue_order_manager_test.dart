import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/providers/audio/queue_order_manager.dart';
import 'package:frontend/repositories/queue_repository.dart';

void main() {
  test('shuffleItems produces a permutation of the input', () {
    final input = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    final result = QueueOrderManager.shuffleItems(input);

    expect(result.toSet(), input.toSet());
    expect(result, hasLength(input.length));
  });

  test('shuffleItems with seeded Random is deterministic', () {
    final input = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    final result1 = QueueOrderManager.shuffleItems(input, Random(42));
    final result2 = QueueOrderManager.shuffleItems(input, Random(42));

    expect(result1, result2);
  });

  test('shuffleItems does not modify original list', () {
    final input = [1, 2, 3];
    final copy = List<int>.from(input);
    QueueOrderManager.shuffleItems(input);
    expect(input, copy);
  });

  group('rebuildEffectiveOrder', () {
    late AppDatabase db;
    late QueueRepository repo;
    late QueueOrderManager orderManager;
    late _LibraryFixture fixture;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = QueueRepository(db);
      orderManager = QueueOrderManager(repo);
      fixture = _LibraryFixture(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('with shuffle off preserves canonical order', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'c', 'd', 'e'],
        currentIndex: 2,
      );
      final snapshot = await repo.getSessionSnapshot(sessionId);
      final currentItemId = snapshot!.currentItem!.itemId;

      await orderManager.rebuildEffectiveOrder(
        sessionId,
        currentItemId: currentItemId,
        preserveShuffledMainFuture: false,
        isShuffleOn: false,
      );

      final entries = await repo.getSessionTracksInPlayOrder(sessionId);
      expect(
        entries.map((entry) => entry.uuidId),
        ['a', 'b', 'c', 'd', 'e'],
      );
    });

    test('with shuffle on randomizes future items', () async {
      await fixture.insertSingles(
        List.generate(20, (i) => 'track-${i + 1}'),
      );

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: List.generate(20, (i) => 'track-${i + 1}'),
        currentIndex: 0,
      );
      final snapshot = await repo.getSessionSnapshot(sessionId);
      final currentItemId = snapshot!.currentItem!.itemId;

      await orderManager.rebuildEffectiveOrder(
        sessionId,
        currentItemId: currentItemId,
        preserveShuffledMainFuture: false,
        shuffleMainFuture: true,
        isShuffleOn: false,
      );

      final entries = await repo.getSessionTracksInPlayOrder(sessionId);
      expect(entries.first.uuidId, 'track-1');
      expect(entries.map((e) => e.uuidId).toSet(), hasLength(20));
    });
  });
}

class _LibraryFixture {
  final AppDatabase db;
  int _nextArtistId = 1;
  int _nextAlbumId = 1;
  final Map<String, int> _artistIds = {};
  final Map<String, int> _albumIds = {};

  _LibraryFixture(this.db);

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
