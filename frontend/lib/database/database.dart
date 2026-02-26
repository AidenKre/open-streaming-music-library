import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

class Tracks extends Table {
  TextColumn get uuidId => text()();
  TextColumn get filePath => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get lastUpdated => integer()();

  @override
  Set<Column> get primaryKey => {uuidId};
}

class Trackmetadata extends Table {
  TextColumn get uuidId => text().references(Tracks, #uuidId)();
  TextColumn get title => text().nullable()();
  TextColumn get artist => text().nullable()();
  TextColumn get album => text().nullable()();
  TextColumn get albumArtist => text().nullable()();
  IntColumn get year => integer().nullable()();
  TextColumn get date => text().nullable()();
  TextColumn get genre => text().nullable()();
  IntColumn get trackNumber => integer().nullable()();
  IntColumn get discNumber => integer().nullable()();
  TextColumn get codec => text().nullable()();
  RealColumn get duration => real()();
  RealColumn get bitrateKbps => real()();
  IntColumn get sampleRateHz => integer()();
  IntColumn get channels => integer()();
  BoolColumn get hasAlbumArt => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {uuidId};
}

@DriftDatabase(tables: [Tracks, Trackmetadata])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  // Sort-key cursor pagination for all tracks.
  // This cursor logic is linked to the backend's filter_for_cursor()
  // in backend/app/database/database.py — keep them in sync.
  Future<List<QueryRow>> getTrackPage({
    required int limit,
    String? cursorArtist,
    String? cursorAlbum,
    int? cursorTrackNumber,
    String? cursorUuidId,
  }) {
    final vars = <Variable>[];
    var cursorClause = '';

    if (cursorUuidId != null) {
      final parts = <String>[];

      // depth 0: artist
      if (cursorArtist == null) {
        parts.add('tm.artist IS NOT NULL');
      } else {
        parts.add('tm.artist > ?');
        vars.add(Variable.withString(cursorArtist));
      }

      // depth 1: artist =, album >
      if (cursorArtist == null) {
        // artist IS NULL AND album > ? (or IS NOT NULL if album is null)
        if (cursorAlbum == null) {
          parts.add('(tm.artist IS NULL AND tm.album IS NOT NULL)');
        } else {
          parts.add('(tm.artist IS NULL AND tm.album > ?)');
          vars.add(Variable.withString(cursorAlbum));
        }
      } else {
        if (cursorAlbum == null) {
          parts.add('(tm.artist = ? AND tm.album IS NOT NULL)');
          vars.add(Variable.withString(cursorArtist));
        } else {
          parts.add('(tm.artist = ? AND tm.album > ?)');
          vars.add(Variable.withString(cursorArtist));
          vars.add(Variable.withString(cursorAlbum));
        }
      }

      // depth 2: artist =, album =, trackNumber >
      final eqArtist =
          cursorArtist == null ? 'tm.artist IS NULL' : 'tm.artist = ?';
      final eqAlbum =
          cursorAlbum == null ? 'tm.album IS NULL' : 'tm.album = ?';

      if (cursorTrackNumber == null) {
        parts.add('($eqArtist AND $eqAlbum AND tm.track_number IS NOT NULL)');
      } else {
        parts.add('($eqArtist AND $eqAlbum AND tm.track_number > ?)');
      }
      if (cursorArtist != null) vars.add(Variable.withString(cursorArtist));
      if (cursorAlbum != null) vars.add(Variable.withString(cursorAlbum));
      if (cursorTrackNumber != null) vars.add(Variable.withInt(cursorTrackNumber));

      // depth 3: artist =, album =, trackNumber =, uuidId >
      final eqTrackNumber = cursorTrackNumber == null
          ? 'tm.track_number IS NULL'
          : 'tm.track_number = ?';
      parts.add('($eqArtist AND $eqAlbum AND $eqTrackNumber AND t.uuid_id > ?)');
      if (cursorArtist != null) vars.add(Variable.withString(cursorArtist));
      if (cursorAlbum != null) vars.add(Variable.withString(cursorAlbum));
      if (cursorTrackNumber != null) vars.add(Variable.withInt(cursorTrackNumber));
      vars.add(Variable.withString(cursorUuidId));

      cursorClause = 'WHERE (${parts.join(' OR ')})';
    }

    vars.add(Variable.withInt(limit));

    return customSelect(
      'SELECT tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, '
      'tm.year, tm.date, tm.genre, tm.track_number, tm.disc_number, '
      'tm.codec, tm.duration, tm.bitrate_kbps, tm.sample_rate_hz, '
      'tm.channels, tm.has_album_art, t.file_path, t.created_at, t.last_updated '
      'FROM trackmetadata AS tm '
      'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id '
      '$cursorClause '
      'ORDER BY tm.artist ASC, tm.album ASC, tm.track_number ASC, t.uuid_id ASC '
      'LIMIT ?',
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).get();
  }

  // Sort-key cursor pagination for album tracks.
  // This cursor logic is linked to the backend's filter_for_cursor()
  // in backend/app/database/database.py — keep them in sync.
  Future<List<QueryRow>> getAlbumTrackPage({
    required String artist,
    required String album,
    required int limit,
    int? cursorTrackNumber,
    String? cursorUuidId,
  }) {
    final vars = <Variable>[];
    var cursorClause = '';

    // Artist/album filter (same as backend artist_album_filter_clause)
    vars.add(Variable.withString(artist.toLowerCase()));
    vars.add(Variable.withString(artist.toLowerCase()));
    vars.add(Variable.withString(album));

    if (cursorUuidId != null) {
      final parts = <String>[];

      // depth 0: trackNumber >
      if (cursorTrackNumber == null) {
        parts.add('tm.track_number IS NOT NULL');
      } else {
        parts.add('tm.track_number > ?');
        vars.add(Variable.withInt(cursorTrackNumber));
      }

      // depth 1: trackNumber =, uuidId >
      final eqTrackNumber = cursorTrackNumber == null
          ? 'tm.track_number IS NULL'
          : 'tm.track_number = ?';
      parts.add('($eqTrackNumber AND t.uuid_id > ?)');
      if (cursorTrackNumber != null) vars.add(Variable.withInt(cursorTrackNumber));
      vars.add(Variable.withString(cursorUuidId));

      cursorClause = 'AND (${parts.join(' OR ')})';
    }

    vars.add(Variable.withInt(limit));

    return customSelect(
      'SELECT tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, '
      'tm.year, tm.date, tm.genre, tm.track_number, tm.disc_number, '
      'tm.codec, tm.duration, tm.bitrate_kbps, tm.sample_rate_hz, '
      'tm.channels, tm.has_album_art, t.file_path, t.created_at, t.last_updated '
      'FROM trackmetadata AS tm '
      'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id '
      'WHERE ((LOWER(tm.album_artist) = ? ) '
      '  OR (tm.album_artist IS NULL AND LOWER(tm.artist) = ?)) '
      '  AND tm.album = ? '
      '$cursorClause '
      'ORDER BY tm.track_number ASC, t.uuid_id ASC '
      'LIMIT ?',
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).get();
  }
}

LazyDatabase openAppDatabase() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'database.db'));
    return NativeDatabase.createInBackground(file);
  });
}

TracksCompanion tracksCompanionFromDto(ClientTrackDto dto) {
  return TracksCompanion(
    uuidId: Value(dto.uuidId),
    createdAt: Value(dto.createdAt),
    lastUpdated: Value(dto.lastUpdated),
    filePath: Value.absent(),
  );
}

TrackmetadataCompanion trackmetadataCompanionFromDto(ClientTrackDto dto) {
  final meta = dto.metadata;
  return TrackmetadataCompanion(
    uuidId: Value(dto.uuidId),
    title: Value(meta.title),
    artist: Value(meta.artist),
    album: Value(meta.album),
    albumArtist: Value(meta.albumArtist),
    year: Value(meta.year),
    date: Value(meta.date),
    genre: Value(meta.genre),
    trackNumber: Value(meta.trackNumber),
    discNumber: Value(meta.discNumber),
    codec: Value(meta.codec),
    duration: Value(meta.duration),
    bitrateKbps: Value(meta.bitrateKbps),
    sampleRateHz: Value(meta.sampleRateHz),
    channels: Value(meta.channels),
    hasAlbumArt: Value(meta.hasAlbumArt),
  );
}
