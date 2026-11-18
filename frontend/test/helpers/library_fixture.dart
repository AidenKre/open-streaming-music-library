import 'package:drift/drift.dart' show Value;
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';

/// A small catalog for queue and playback tests: tracks inserted through the
/// sync DTO path, with their artists and albums (moved here from five test
/// files, APP-TEST stage 2).
class LibraryFixture {
  final AppDatabase db;
  int _nextArtistId = 1;
  int _nextAlbumId = 1;
  final Map<String, int> _artistIds = {};
  final Map<String, int> _albumIds = {};

  LibraryFixture(this.db);

  Future<void> insertAlbum({
    required String artist,
    required String album,
    required List<String> uuids,
    String? trackTitlePrefix,
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
        title: trackTitlePrefix != null
            ? '$trackTitlePrefix ${i + 1}'
            : 'Track ${uuids[i]}',
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

  Future<TrackUI> track(String uuid) async {
    final rows = await db.getTrackByUuid(uuid);
    return TrackUI.fromQueryRow(rows.single);
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
    String? title,
  }) async {
    final dto = ClientTrackDto.fromJson({
      'uuid_id': uuid,
      'created_at': 1700000000 + trackNumber,
      'last_updated': 1700000100 + trackNumber,
      'revision': 1700000000 + trackNumber,
      'metadata': {
        'title': title ?? 'Track $uuid',
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
