import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
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

TracksCompanion tracksCompanionFromJson(Map<String, dynamic> json) {
  return TracksCompanion(
    uuidId: Value(json['uuid_id'] as String),
    createdAt: Value((json['created_at'] as num).toInt()),
    lastUpdated: Value((json['last_updated'] as num).toInt()),
    filePath: Value.absent(),
  );
}

TrackmetadataCompanion trackmetadataCompanionFromJson(
  String uuidId,
  Map<String, dynamic> json,
) {
  return TrackmetadataCompanion(
    uuidId: Value(uuidId),
    title: Value(json['title'] as String?),
    artist: Value(json['artist'] as String?),
    album: Value(json['album'] as String?),
    albumArtist: Value(json['album_artist'] as String?),
    year: Value((json['year'] as num?)?.toInt()),
    date: Value(json['date'] as String?),
    genre: Value(json['genre'] as String?),
    trackNumber: Value((json['track_number'] as num?)?.toInt()),
    discNumber: Value((json['disc_number'] as num?)?.toInt()),
    codec: Value(json['codec'] as String?),
    duration: Value((json['duration'] as num).toDouble()),
    bitrateKbps: Value((json['bitrate_kbps'] as num).toDouble()),
    sampleRateHz: Value((json['sample_rate_hz'] as num).toInt()),
    channels: Value((json['channels'] as num).toInt()),
    hasAlbumArt: Value(json['has_album_art'] as bool? ?? false),
  );
}

