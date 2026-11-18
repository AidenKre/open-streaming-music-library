// Loads and seeds the independent listening-stats fixture workbook
// (test/fixtures/listening_stats/workbook.json, written by make_workbook.py
// from the spec §2 definitions; phase 9 review §3). The expected values are
// read from the JSON, never computed here.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/listening_stats.dart';

import 'catalog_seed.dart';

class Workbook {
  Workbook._(this.json);

  /// Loads the workbook, or another fixture of the same shape at [path]
  /// (for example the annual-recap fixture).
  factory Workbook.load([
    String path = 'test/fixtures/listening_stats/workbook.json',
  ]) => Workbook._(
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>,
  );

  final Map<String, Object?> json;

  Map<String, Object?> get _catalog => json['catalog']! as Map<String, Object?>;
  List<Map<String, Object?>> get events =>
      (json['events']! as List).cast<Map<String, Object?>>();
  List<WorkbookCase> get cases => [
    for (final c in (json['cases']! as List).cast<Map<String, Object?>>())
      WorkbookCase(c),
  ];

  /// Seeds the catalog and every event (local_id as listed) into [db].
  Future<void> seed(AppDatabase db) async {
    final seed = CatalogSeed(db);
    for (final a in (_catalog['artists']! as List).cast<Map>()) {
      await seed.artist(a['id'] as int, a['name'] as String);
    }
    for (final a in (_catalog['albums']! as List).cast<Map>()) {
      await seed.album(
        a['id'] as int,
        artistId: a['artistId'] as int,
        name: a['name'] as String,
      );
    }
    for (final t in (_catalog['tracks']! as List).cast<Map>()) {
      await seed.track(
        t['uuid'] as String,
        artistId: t['artistId'] as int?,
        albumId: t['albumId'] as int?,
        title: t['title'] as String,
        artistName: t['artistName'] as String?,
        albumName: t['albumName'] as String?,
      );
    }
    for (final uuid in (_catalog['tracksWithoutMetadata']! as List).cast<String>()) {
      final dto = ClientTrackDto.fromJson({
        'uuid_id': uuid,
        'created_at': 1700000000,
        'last_updated': 1700000100,
        'revision': 1,
        'metadata': {'title': 'x'},
      });
      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    }
    for (final e in events) {
      await db.into(db.historyEvents).insert(
        HistoryEventsCompanion.insert(
          localId: Value(e['localId']! as int),
          eventUuid: e['uuid']! as String,
          kind: e['kind']! as String,
          entityType: e['entityType']! as String,
          entityRef: e['ref']! as String,
          occurredAt: e['atMs']! as int,
          secondsPlayed: Value(_num(e['seconds'])),
          trackLength: Value(_num(e['length'])),
          serverRevision: Value(e['serverRevision'] as int?),
          pendingUpload: e['pendingUpload']! as bool,
        ),
      );
    }
  }

  int get maxLocalId => events.length;

  /// The catalog title of track [uuid].
  String trackTitle(String uuid) => (_catalog['tracks']! as List)
      .cast<Map>()
      .firstWhere((t) => t['uuid'] == uuid)['title'] as String;
}

double? _num(Object? v) => switch (v) {
  null => null,
  'Infinity' => double.infinity,
  '-Infinity' => double.negativeInfinity,
  num n => n.toDouble(),
  _ => throw FormatException('bad number $v'),
};

class WorkbookCase {
  WorkbookCase(this.json);
  final Map<String, Object?> json;

  String get name => json['name']! as String;
  int get capturedNowMs => json['capturedNowMs']! as int;
  int? get boundary => json['boundary'] as int?;
  Map<String, Object?> get expected => json['expected']! as Map<String, Object?>;

  StatsRange get range {
    final r = json['range']! as Map<String, Object?>;
    return switch (r['type']) {
      'rolling' => RollingDaysRange(r['days']! as int),
      'thisYear' => StatsRange.thisUtcYear,
      'year' => StatsRange.year(r['year']! as int),
      'allTime' => StatsRange.allTime,
      _ => throw FormatException('bad range $r'),
    };
  }

  double get listeningSeconds => _num(expected['listeningSeconds'])!;
  int get qualifiedPlays => expected['qualifiedPlays']! as int;
  int get uniqueTracks => expected['uniqueTracks']! as int;
  int get activeDays => expected['activeDays']! as int;
  double get unavailableSeconds =>
      _num((expected['unavailable']! as Map)['listeningSeconds'])!;
  int get unavailableQualified =>
      (expected['unavailable']! as Map)['qualifiedPlays']! as int;
  int get futureTimestampCount => expected['futureTimestampCount']! as int;
  String get bucketUnit => expected['bucketUnit']! as String;
  bool get chartCapped => expected['chartCapped']! as bool;

  /// `(label, seconds)`; label `YYYY-MM-DD` or `YYYY-MM` of the bucket start.
  List<(String, double)> get buckets => [
    for (final b in (expected['buckets']! as List).cast<Map>())
      (b['label'] as String, _num(b['seconds'])!),
  ];

  List<(Object, double, int)> ranked(String key) => [
    for (final r in (expected[key]! as List).cast<Map>())
      (r['id'] as Object, _num(r['seconds'])!, r['qualifiedPlays'] as int),
  ];
}
