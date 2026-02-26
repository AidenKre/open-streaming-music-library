import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/repositories/track_repository.dart';

Future<void> insertTrack(
  AppDatabase db, {
  required String uuid,
  String? title,
  String? artist,
  String? album,
  String? albumArtist,
  int? trackNumber,
}) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 1700000000,
    'last_updated': 1700001000,
    'metadata': {
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (albumArtist != null) 'album_artist': albumArtist,
      if (trackNumber != null) 'track_number': trackNumber,
      'duration': 180.0,
      'bitrate_kbps': 256.0,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  });
  await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
  await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
}

void main() {
  late AppDatabase db;
  late TrackRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = TrackRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('getAllTracks', () {
    test('empty DB returns empty TrackPage with null nextCursor', () async {
      final page = await repo.getAllTracks();
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
    });

    test('returns items sorted by artist -> album -> trackNumber', () async {
      await insertTrack(db, uuid: '1', artist: 'B', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'B', trackNumber: 1);
      await insertTrack(db, uuid: '3', artist: 'A', album: 'A', trackNumber: 2);
      await insertTrack(db, uuid: '4', artist: 'A', album: 'A', trackNumber: 1);

      final page = await repo.getAllTracks();
      final uuids = page.items.map((t) => t.uuidId).toList();
      expect(uuids, ['4', '3', '2', '1']);
    });

    test('nextCursor is null when fewer than pageSize items returned', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);

      final page = await repo.getAllTracks();
      expect(page.nextCursor, isNull);
    });

    test('nextCursor contains last item sort keys when page is full', () async {
      for (var i = 0; i < TrackRepository.pageSize; i++) {
        await insertTrack(
          db,
          uuid: 'track-${i.toString().padLeft(4, '0')}',
          artist: 'Artist',
          album: 'Album',
          trackNumber: i + 1,
        );
      }

      final page = await repo.getAllTracks();
      expect(page.items.length, TrackRepository.pageSize);
      expect(page.nextCursor, isA<AllTracksCursor>());
      final cursor = page.nextCursor as AllTracksCursor;
      final lastItem = page.items.last;
      expect(cursor.artist, lastItem.artist);
      expect(cursor.album, lastItem.album);
      expect(cursor.trackNumber, lastItem.trackNumber);
      expect(cursor.uuidId, lastItem.uuidId);
    });

    test('cursor pagination returns correct next page', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'A', trackNumber: 2);
      await insertTrack(db, uuid: '3', artist: 'A', album: 'A', trackNumber: 3);

      final page = await repo.getAllTracks(
        cursor: const AllTracksCursor(
          artist: 'A',
          album: 'A',
          trackNumber: 1,
          uuidId: '1',
        ),
      );
      final uuids = page.items.map((t) => t.uuidId).toList();
      expect(uuids, ['2', '3']);
    });

    test('maps results to TrackUI with correct field values', () async {
      await insertTrack(
        db,
        uuid: 'test-uuid',
        title: 'My Song',
        artist: 'My Artist',
        album: 'My Album',
        albumArtist: 'Album Artist',
        trackNumber: 5,
      );

      final page = await repo.getAllTracks();
      expect(page.items.length, 1);
      final track = page.items.first;
      expect(track.uuidId, 'test-uuid');
      expect(track.title, 'My Song');
      expect(track.artist, 'My Artist');
      expect(track.album, 'My Album');
      expect(track.albumArtist, 'Album Artist');
      expect(track.trackNumber, 5);
      expect(track.duration, 180.0);
      expect(track.bitrateKbps, 256.0);
      expect(track.sampleRateHz, 44100);
      expect(track.channels, 2);
      expect(track.hasAlbumArt, false);
    });
  });

  group('getAlbumTracks', () {
    test('returns only tracks matching artist + album', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist A', album: 'Album A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'Artist B', album: 'Album B', trackNumber: 1);

      final page = await repo.getAlbumTracks(artist: 'Artist A', album: 'Album A');
      expect(page.items.length, 1);
      expect(page.items.first.uuidId, '1');
    });

    test('matches albumArtist field when present', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Different Artist',
        albumArtist: 'Album Artist',
        album: 'My Album',
        trackNumber: 1,
      );

      final page = await repo.getAlbumTracks(artist: 'Album Artist', album: 'My Album');
      expect(page.items.length, 1);
      expect(page.items.first.uuidId, '1');
    });

    test('matches artist field when albumArtist is null', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Solo Artist',
        album: 'My Album',
        trackNumber: 1,
      );

      final page = await repo.getAlbumTracks(artist: 'Solo Artist', album: 'My Album');
      expect(page.items.length, 1);
      expect(page.items.first.uuidId, '1');
    });

    test('orders by trackNumber ASC', () async {
      await insertTrack(db, uuid: '3', artist: 'Artist', album: 'Album', trackNumber: 3);
      await insertTrack(db, uuid: '1', artist: 'Artist', album: 'Album', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'Artist', album: 'Album', trackNumber: 2);

      final page = await repo.getAlbumTracks(artist: 'Artist', album: 'Album');
      final uuids = page.items.map((t) => t.uuidId).toList();
      expect(uuids, ['1', '2', '3']);
    });

    test('cursor pagination returns correct next page', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist', album: 'Album', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'Artist', album: 'Album', trackNumber: 2);
      await insertTrack(db, uuid: '3', artist: 'Artist', album: 'Album', trackNumber: 3);

      final page = await repo.getAlbumTracks(
        artist: 'Artist',
        album: 'Album',
        cursor: const AlbumTracksCursor(trackNumber: 1, uuidId: '1'),
      );
      final uuids = page.items.map((t) => t.uuidId).toList();
      expect(uuids, ['2', '3']);
    });
  });

  group('tracksChanged', () {
    test('emits after a track is inserted into the DB', () async {
      final future = repo.tracksChanged.first;
      await insertTrack(db, uuid: 'new-track', artist: 'A', album: 'B', trackNumber: 1);
      await expectLater(future, completes);
    });
  });
}
