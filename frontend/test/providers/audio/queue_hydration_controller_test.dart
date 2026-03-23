import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/providers/audio/concatenating_player_controller.dart';
import 'package:frontend/providers/audio/queue_hydration_controller.dart';
import 'package:frontend/repositories/queue_repository.dart';

void main() {
  late AppDatabase db;
  late QueueRepository repo;
  late _FakePlayer fakePlayer;
  late QueueHydrationController hydration;
  late _LibraryFixture fixture;

  setUpAll(() {
    ApiClient.init('http://localhost:8080');
  });

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = QueueRepository(db);
    fakePlayer = _FakePlayer();
    hydration = QueueHydrationController(repo, fakePlayer);
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
            QueueHydrationController.seedPreviousCount +
            QueueHydrationController.seedNextCount + 1));
    expect(entries.first.playPosition,
        greaterThanOrEqualTo(40 - QueueHydrationController.seedPreviousCount));
    expect(entries.any((e) => e.playPosition == 40), isTrue);
  });

  test('ensureItemLoaded is no-op when item already loaded', () async {
    await fixture.insertSingles(['a', 'b']);
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: const ['a', 'b'],
      currentIndex: 0,
    );

    final entries = await repo.getPlaybackEntries(sessionId);
    fakePlayer.preloadItems(entries);

    await hydration.ensureItemLoaded(sessionId, entries.first);

    expect(fakePlayer.addedBatches, isEmpty);
  });

  test('ensureItemLoaded loads entries when item not present', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: const ['a', 'b', 'c'],
      currentIndex: 0,
    );

    final entries = await repo.getPlaybackEntries(sessionId);

    await hydration.ensureItemLoaded(sessionId, entries.last);

    expect(fakePlayer.addedBatches, isNotEmpty);
    expect(fakePlayer.hasItem(entries.last.itemId), isTrue);
  });

  test('scheduleForwardHydration loads when buffer is low', () async {
    await fixture.insertSingles(List.generate(100, (i) => 'track-${i + 1}'));
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: List.generate(100, (i) => 'track-${i + 1}'),
      currentIndex: 0,
    );

    hydration.nextForwardHydrationPlayPosition = 5;
    hydration.scheduleForwardHydration(
      sessionId: sessionId,
      totalCount: 100,
      currentPlayPosition: 0,
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(fakePlayer.addedBatches, isNotEmpty);
    expect(hydration.nextForwardHydrationPlayPosition, greaterThan(5));
  });

  test('reset sets hydration position to 0', () {
    hydration.nextForwardHydrationPlayPosition = 42;
    hydration.reset();
    expect(hydration.nextForwardHydrationPlayPosition, 0);
  });
}

class _FakePlayer implements ConcatenatingPlayerController {
  final Set<int> _loadedItemIds = {};
  final List<List<QueuePlaybackEntry>> addedBatches = [];

  void preloadItems(List<QueuePlaybackEntry> entries) {
    for (final entry in entries) {
      _loadedItemIds.add(entry.itemId);
    }
  }

  @override
  Future<void> addEntries(List<QueuePlaybackEntry> entries) async {
    final additions =
        entries.where((e) => !_loadedItemIds.contains(e.itemId)).toList();
    if (additions.isEmpty) return;
    addedBatches.add(additions);
    for (final entry in additions) {
      _loadedItemIds.add(entry.itemId);
    }
  }

  @override
  bool hasItem(int itemId) => _loadedItemIds.contains(itemId);

  @override
  List<int> get loadedItemIds => _loadedItemIds.toList();

  @override
  int get queueLength => _loadedItemIds.length;

  @override
  int? get currentIndex => null;
  @override
  int? get currentItemId => null;
  @override
  String? get currentUuid => null;
  @override
  Duration get position => Duration.zero;

  @override
  Stream<ja.PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<int?> get currentItemIdStream => const Stream.empty();

  @override
  Future<void> setSeed(List<QueuePlaybackEntry> entries,
      {required int currentItemId,
      Duration initialPosition = Duration.zero,
      bool autoPlay = false,
      bool shuffleEnabled = false}) async {}
  @override
  Future<void> replaceFutureEntries(
      {required int currentItemId,
      required List<QueuePlaybackEntry> entries}) async {}
  @override
  Future<void> rebuildAroundCurrent(
      {required int currentItemId,
      required List<QueuePlaybackEntry> entries}) async {}
  @override
  void replaceLoadedEntriesMetadata(List<QueuePlaybackEntry> entries) {}
  @override
  Future<void> removeItem(int itemId) async {}
  @override
  Future<void> seekToItem(int itemId, {Duration position = Duration.zero}) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setLoopMode(ja.LoopMode mode) async {}
  @override
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
