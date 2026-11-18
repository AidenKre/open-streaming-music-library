// Explicit-ID catalog and click seeding for the recents and SC-12 resolver
// tests. Every ID, name and timestamp is chosen by the test, so expected
// results come from the test's own manifest, never from production SQL.
import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';

class CatalogSeed {
  CatalogSeed(this.db);

  final AppDatabase db;

  Future<void> artist(int id, String name) => db
      .into(db.artists)
      .insert(ArtistsCompanion(id: Value(id), name: Value(name)));

  Future<void> album(
    int id, {
    required int artistId,
    String? name,
    int? year,
    bool single = false,
  }) => db
      .into(db.albums)
      .insert(
        AlbumsCompanion(
          id: Value(id),
          name: Value(name),
          artistId: Value(artistId),
          year: Value(year),
          isSingleGrouping: Value(single),
        ),
      );

  /// A synced track. [art] sets `has_album_art` + `cover_art_id`;
  /// [downloaded] records a local file, [damaged] marks it damaged too.
  Future<void> track(
    String uuid, {
    int? artistId,
    int? albumId,
    int trackNumber = 1,
    String? title,
    int? art,
    bool downloaded = false,
    bool damaged = false,
  }) async {
    final dto = ClientTrackDto.fromJson({
      'uuid_id': uuid,
      'created_at': 1700000000,
      'last_updated': 1700000100,
      'revision': 1,
      'metadata': {
        'title': title ?? 'Track $uuid',
        'artist': 'artist-$artistId',
        'album': 'album-$albumId',
        'artist_id': artistId,
        'album_id': albumId,
        'track_number': trackNumber,
        'disc_number': 1,
        'duration': 180.0,
        'bitrate_kbps': 320.0,
        'sample_rate_hz': 44100,
        'channels': 2,
        'has_album_art': art != null,
        'cover_art_id': art,
      },
    });
    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
    if (downloaded || damaged) {
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
        TracksCompanion(
          filePath: Value('/local/$uuid.flac'),
          damagedFilePath: Value(damaged ? '/local/$uuid.flac' : null),
        ),
      );
    }
  }

  var _seq = 0;

  /// One `clicked` history row. [eventUuid] defaults to a fresh unique
  /// value; pass it to pin tie order.
  Future<void> click(
    String type,
    String ref, {
    required int at,
    String? eventUuid,
    String kind = 'clicked',
  }) => db
      .into(db.historyEvents)
      .insert(
        HistoryEventsCompanion.insert(
          eventUuid: eventUuid ?? 'ev-${(_seq++).toString().padLeft(6, '0')}',
          kind: kind,
          entityType: type,
          entityRef: ref,
          occurredAt: at,
          pendingUpload: false,
        ),
      );
}
