import 'package:drift/drift.dart' show InsertMode, Value;
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';

// Library seeders for tests against a real in-memory drift DB. Moved from
// test/ui/browse_harness.dart (U29-A-12), which re-exports them so its
// importers keep working.

/// One track to seed. Artists/albums are derived (and de-duplicated) from it.
class SeedTrack {
  const SeedTrack({
    required this.uuid,
    required this.title,
    required this.artistId,
    required this.artist,
    this.albumId,
    this.album,
    this.downloaded = false,
    this.trackNumber = 1,
    this.discNumber = 1,
    this.albumYear,
    this.albumIsSingles = false,
    this.revision = 1,
  });

  final String uuid;
  final String title;
  final int artistId;
  final String artist;
  final int? albumId;
  final String? album;
  final bool downloaded;
  final int? trackNumber;
  final int? discNumber;

  /// Album-level fields (taken from the first track seeding the album).
  final int? albumYear;
  final bool albumIsSingles;

  /// The server revision the track is seeded at.
  final int revision;
}

/// Safe to call again on a seeded DB: existing artists/albums are kept.
Future<void> seedLibrary(AppDatabase db, List<SeedTrack> tracks) async {
  final artists = <int, String>{};
  final albums = <int, SeedTrack>{};
  for (final t in tracks) {
    artists[t.artistId] = t.artist;
    if (t.albumId != null) albums.putIfAbsent(t.albumId!, () => t);
  }
  await db.batch((batch) {
    for (final e in artists.entries) {
      batch.insert(
        db.artists,
        ArtistsCompanion(id: Value(e.key), name: Value(e.value)),
        mode: InsertMode.insertOrIgnore,
      );
    }
    for (final e in albums.entries) {
      batch.insert(
        db.albums,
        AlbumsCompanion(
          id: Value(e.key),
          name: Value(e.value.album ?? ''),
          artistId: Value(e.value.artistId),
          year: Value(e.value.albumYear),
          isSingleGrouping: Value(e.value.albumIsSingles),
        ),
        mode: InsertMode.insertOrIgnore,
      );
    }
  });
  for (final t in tracks) {
    final dto = ClientTrackDto.fromJson({
      'uuid_id': t.uuid,
      'created_at': 1000,
      'last_updated': 1000,
      'revision': t.revision,
      'metadata': {
        'title': t.title,
        'artist': t.artist,
        'album': t.album,
        'album_artist': t.artist,
        'artist_id': t.artistId,
        'album_id': t.albumId,
        'track_number': t.trackNumber,
        'disc_number': t.discNumber,
        'codec': 'flac',
        'duration': 60.0,
        'bitrate_kbps': 900.0,
        'sample_rate_hz': 44100,
        'channels': 2,
        'has_album_art': false,
      },
    });
    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
    if (t.downloaded) await markDownloaded(db, t.uuid);
  }
  await db.rebuildFtsIndexes();
}

Future<void> markDownloaded(AppDatabase db, String uuid) async {
  await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
    TracksCompanion(
      filePath: Value('/downloads/$uuid.flac'),
      downloadedAtRevision: const Value(1),
    ),
  );
}
