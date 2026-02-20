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

