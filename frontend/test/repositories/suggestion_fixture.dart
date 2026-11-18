// Loads and seeds the independent suggestion fixture
// (test/fixtures/suggestions/suggestions.json, written by
// make_suggestions.py from spec §2 and §5; phase 9 review §3). The expected
// values are read from the JSON, never computed here.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';

import 'catalog_seed.dart';

class SuggestionFixture {
  SuggestionFixture._(this.json);

  factory SuggestionFixture.load() => SuggestionFixture._(
    jsonDecode(
          File('test/fixtures/suggestions/suggestions.json').readAsStringSync(),
        )
        as Map<String, Object?>,
  );

  final Map<String, Object?> json;

  int get capturedNowMs => json['capturedNowMs']! as int;
  int get boundary => json['boundary']! as int;
  Map<String, Object?> get _catalog => json['catalog']! as Map<String, Object?>;
  List<Map<String, Object?>> get events =>
      (json['events']! as List).cast<Map<String, Object?>>();
  List<Map<String, Object?>> get tracks =>
      (_catalog['tracks']! as List).cast<Map<String, Object?>>();
  Map<String, Object?> get _expected =>
      json['expected']! as Map<String, Object?>;

  /// Expected Rediscover pool, keyed by uuid:
  /// `(micros, qualifiedPlays, lastQualifiedAtMs, downloaded)`.
  Map<String, (int, int, int, bool)> get rediscover => {
    for (final r in (_expected['rediscover']! as List).cast<Map>())
      r['uuid'] as String: (
        r['micros'] as int,
        r['qualifiedPlays'] as int,
        r['lastQualifiedAtMs'] as int,
        r['downloaded'] as bool,
      ),
  };

  /// Expected artist pools, keyed by artist id:
  /// `(micros, qualifiedPlays, {uuid: (title, downloaded)})`.
  Map<int, (int, int, Map<String, (String?, bool)>)> get artists => {
    for (final a in (_expected['artists']! as List).cast<Map>())
      a['artistId'] as int: (
        a['micros'] as int,
        a['qualifiedPlays'] as int,
        {
          for (final c in (a['candidates']! as List).cast<Map>())
            c['uuid'] as String: (c['title'] as String?, c['downloaded'] as bool),
        },
      ),
  };

  List<SuggestionCase> get cases => [
    for (final c in (json['cases']! as List).cast<Map<String, Object?>>())
      SuggestionCase(c),
  ];

  /// The catalog row of track [uuid]: `(artistId, title)`.
  (int?, String?) catalogTrack(String uuid) {
    final t = tracks.firstWhere((t) => t['uuid'] == uuid);
    return (t['artistId'] as int?, t['title'] as String?);
  }

  /// Seeds the catalog and every event (local_id as listed) into [db].
  Future<void> seed(AppDatabase db) async {
    final seed = CatalogSeed(db);
    for (final a in (_catalog['artists']! as List).cast<Map>()) {
      await seed.artist(a['id'] as int, a['name'] as String);
    }
    for (final t in tracks) {
      await seed.track(
        t['uuid']! as String,
        artistId: t['artistId'] as int?,
        title: t['title'] as String?,
        downloaded: t['downloaded']! as bool,
        damaged: t['damaged'] as bool? ?? false,
      );
    }
    for (final uuid
        in (_catalog['tracksWithoutMetadata']! as List).cast<String>()) {
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
          eventUuid: 'ev-${e['localId']}',
          kind: e['kind']! as String,
          entityType: e['entityType']! as String,
          entityRef: e['ref']! as String,
          occurredAt: e['atMs']! as int,
          secondsPlayed: Value((e['seconds'] as num?)?.toDouble()),
          trackLength: Value((e['length'] as num?)?.toDouble()),
          pendingUpload: false,
        ),
      );
    }
  }
}

class SuggestionCase {
  SuggestionCase(this.json);
  final Map<String, Object?> json;

  String get name => json['name']! as String;
  String? get currentUuid => json['currentUuid'] as String?;
  bool get downloaded => json['downloaded']! as bool;
  Map<String, Object?> get _expected =>
      json['expected']! as Map<String, Object?>;
  List<String> get rediscover =>
      (_expected['rediscover']! as List).cast<String>();
  List<String> get moreFromArtists =>
      (_expected['moreFromArtists']! as List).cast<String>();
}
