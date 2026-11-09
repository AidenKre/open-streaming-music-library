import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/providers/audio/queue_window.dart';
import 'package:frontend/repositories/queue_repository.dart';
import '../../helpers/server_binding.dart';

void main() {
  late AppDatabase db;
  late QueueRepository repo;
  late _FakePlayer fakePlayer;
  late QueueWindow hydration;
  late _LibraryFixture fixture;

  setUpAll(() {
    ApiClient.init('http://localhost:8080');
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    repo = QueueRepository(db);
    fakePlayer = _FakePlayer();
    hydration = QueueWindow(repo);
    fixture = _LibraryFixture(db);
  });

  tearDown(() async {
    hydration.dispose();
    fakePlayer.dispose();
    await db.close();
  });

  test('seedEntriesForPlayPosition returns bounded window', () async {
    await fixture.insertSingles(List.generate(80, (i) => 'track-${i + 1}'));
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: List.generate(80, (i) => 'track-${i + 1}'),
      currentIndex: 40,
    );

    final entries = await hydration.seedEntriesForPlayPosition(sessionId, 40);

    expect(entries, isNotEmpty);
    expect(entries.length,
        lessThanOrEqualTo(
            QueueWindow.seedPreviousCount +
            QueueWindow.seedNextCount + 1));
    expect(entries.first.playPosition,
        greaterThanOrEqualTo(40 - QueueWindow.seedPreviousCount));
    expect(entries.any((e) => e.playPosition == 40), isTrue);
  });

  // 5B.0d: loading an item outside the window is a rebase by the core
  // (audio_coordinator_test 'a distant jump rebases ...'); the window only
  // proposes seeds and records the replaced interval.
  test('a rebase seed is the bounded window around the target', () async {
    await fixture.insertSingles(List.generate(80, (i) => 'track-${i + 1}'));
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: List.generate(80, (i) => 'track-${i + 1}'),
      currentIndex: 0,
    );
    final entries = await hydration.seedEntriesForPlayPosition(sessionId, 70);
    expect(entries.first.playPosition, 70 - QueueWindow.seedPreviousCount);
    expect(entries.last.playPosition, 79);
    hydration.replaceWindow(
        start: entries.first.playPosition, end: entries.last.playPosition + 1);
    expect(hydration.windowStartPlayPosition, 58);
    expect(hydration.nextForwardHydrationPlayPosition, 80);
    expect(hydration.coversQueue(80), isFalse);
  });

  test('a window over every row covers the queue', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: const ['a', 'b', 'c'],
      currentIndex: 0,
    );
    final entries = await hydration.seedEntriesForPlayPosition(sessionId, 0);
    hydration.replaceWindow(start: 0, end: entries.last.playPosition + 1);
    expect(hydration.coversQueue(3), isTrue);
  });

  test('scheduleForwardHydration loads when buffer is low', () async {
    await fixture.insertSingles(List.generate(100, (i) => 'track-${i + 1}'));
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: List.generate(100, (i) => 'track-${i + 1}'),
      currentIndex: 0,
    );

    hydration.replaceWindow(start: 0, end: 5);
    hydration.scheduleForwardHydration(
      sessionId: sessionId,
      totalCount: 100,
      currentPlayPosition: 0,
      apply: (proposal) async {
        await fakePlayer.addEntries(proposal.entries);
        return hydration.acknowledge(proposal);
      },
    );

    await fakePlayer.firstAdd.future;
    await pumpEventQueue();

    expect(fakePlayer.addedBatches, isNotEmpty);
    expect(hydration.nextForwardHydrationPlayPosition, greaterThan(5));
  });

  test('reset sets hydration position to 0', () {
    hydration.nextForwardHydrationPlayPosition = 42;
    hydration.reset();
    expect(hydration.nextForwardHydrationPlayPosition, 0);
  });
}

class _FakePlayer {
  final Set<int> _loadedItemIds = {};
  final List<List<QueuePlaybackEntry>> addedBatches = [];
  final firstAdd = Completer<void>();
  void preloadItems(List<QueuePlaybackEntry> entries) =>
      _loadedItemIds.addAll(entries.map((entry) => entry.itemId));
  Future<void> addEntries(List<QueuePlaybackEntry> entries) async {
    final additions = entries.where((entry) => !_loadedItemIds.contains(entry.itemId)).toList();
    if (additions.isEmpty) return;
    addedBatches.add(additions);
    preloadItems(additions);
    if (!firstAdd.isCompleted) firstAdd.complete();
  }
  bool hasItem(int itemId) => _loadedItemIds.contains(itemId);
  void dispose() {}
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
