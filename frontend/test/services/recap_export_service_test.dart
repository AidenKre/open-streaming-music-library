// Phase 9C.1 S4 (spec §6 paragraph 2; review 9-U06 JSON half): the recap's
// JSON export. The golden files are written by the independent fixture
// generator (test/fixtures/annual_recap/make_recap_fixture.py) from spec §2
// and §6, never by running this code.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';
import 'package:frontend/services/annual_recap_service.dart';
import 'package:frontend/services/recap_export_service.dart';

import '../helpers/fake_clock.dart';
import '../repositories/listening_stats_workbook.dart';

const _dir = 'test/fixtures/annual_recap';

void main() {
  final fixture = Workbook.load('$_dir/recap_fixture.json');
  const export = RecapExportService();
  late AppDatabase db;
  late AnnualRecapService service;

  HistorySnapshotToken tokenFor(WorkbookCase c) => HistorySnapshotToken(
    boundaryLocalId: c.boundary!,
    historyContentVersion: 0,
    capturedNowUtcMs: c.capturedNowMs,
    filterKey: annualRecapFilterKey,
  );

  Future<AnnualRecap> recapOf(WorkbookCase c) =>
      service.load(c.json['year']! as int, tokenFor(c));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await fixture.seed(db);
    service = AnnualRecapService(
      ListeningStatsRepository(db, BrowseRepository(db)),
      HistorySnapshotService(db, clock: FakeClock()),
    );
  });

  tearDown(() => db.close());

  group('golden', () {
    for (final c in fixture.cases) {
      test('${c.name} matches ${c.json['golden']} byte for byte', () async {
        final golden = File('$_dir/${c.json['golden']}').readAsStringSync();
        expect(export.buildJson(await recapOf(c)), golden);
      });
    }
  });

  test('the same snapshot always gives the same text', () async {
    final recap = await recapOf(fixture.cases.first);
    expect(export.buildJson(recap), export.buildJson(recap));
  });

  group('privacy: only the recap\'s numbers, ids, labels and notes', () {
    // Everything the export may carry: the fixture's ids and current labels,
    // the fixed vocabulary, UTC timestamps and month labels, the notes.
    final catalog = fixture.json['catalog']! as Map<String, Object?>;
    final allowedStrings = <String>{
      'osml-annual-recap',
      'UTC',
      for (final t in (catalog['tracks']! as List).cast<Map>()) ...[
        t['uuid'] as String,
        t['title'] as String,
        t['artistName'] as String,
        t['albumName'] as String,
      ],
      for (final a in (catalog['artists']! as List).cast<Map>())
        a['name'] as String,
      for (final a in (catalog['albums']! as List).cast<Map>())
        a['name'] as String,
    };
    final timestamp = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$');
    final month = RegExp(r'^\d{4}-\d\d$');
    const allowedKeys = {
      'schema', 'kind', 'year', 'year_so_far', 'time_zone', 'range',
      'start_utc', 'end_utc', 'counted_until_utc', 'generated_at_utc',
      'metrics', 'listening_seconds', 'qualified_plays', 'unique_tracks',
      'active_days', 'unavailable', 'busiest_month', 'month', 'months',
      'top_tracks', 'top_artists', 'top_albums', 'rank', 'uuid', 'id',
      'title', 'artist', 'album', 'name', 'notes',
    };

    for (final c in fixture.cases) {
      test('${c.name}: nothing else, even with a downloaded file', () async {
        // Local facts that must never leave: a file path, a codec.
        await (db.update(db.tracks)..where((t) => t.uuidId.equals('t-a')))
            .write(
              const TracksCompanion(
                filePath: Value('/Users/someone/Music/OSML/t-a-secret.flac'),
              ),
            );
        final text = export.buildJson(await recapOf(c));
        final notes = <String>{};
        final golden =
            jsonDecode(File('$_dir/${c.json['golden']}').readAsStringSync())
                as Map;
        notes.addAll((golden['notes'] as List).cast<String>());

        void walk(Object? v, String at) {
          switch (v) {
            case Map():
              for (final MapEntry(:key, :value) in v.entries) {
                expect(allowedKeys, contains(key), reason: 'key at $at');
                walk(value, '$at.$key');
              }
            case List():
              for (final x in v) {
                walk(x, '$at[]');
              }
            case String():
              expect(
                allowedStrings.contains(v) ||
                    notes.contains(v) ||
                    timestamp.hasMatch(v) ||
                    month.hasMatch(v),
                isTrue,
                reason: 'unexpected string "$v" at $at',
              );
            case num() || bool() || null:
              break;
            default:
              fail('unexpected value $v at $at');
          }
        }

        walk(jsonDecode(text), r'$');
        final lower = text.toLowerCase();
        for (final banned in [
          'secret',
          '/users/',
          '.flac',
          'http',
          'last.fm',
          'lastfm',
          'scrobble',
        ]) {
          expect(lower, isNot(contains(banned)), reason: banned);
        }
      });
    }
  });

  test('an unknown label is null, never an empty string or a made-up name',
      () {
    final range = StatsRange.year(2025);
    final now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
    final stats = ListeningStats(
      range: range,
      window: range.resolve(now),
      boundaryLocalId: 7,
      totals: const ListeningTotals(
        listeningSeconds: 40,
        qualifiedPlays: 1,
        uniqueTracks: 1,
        activeDays: 1,
      ),
      unavailable: const ListeningSubtotal(
        listeningSeconds: 0,
        qualifiedPlays: 0,
      ),
      futureTimestampCount: 0,
      overlongListenCount: 0,
      buckets: [
        ListeningBucket(
          startUtcMs: DateTime.utc(2025).millisecondsSinceEpoch,
          endUtcMs: DateTime.utc(2025, 2).millisecondsSinceEpoch,
          listeningSeconds: 40,
        ),
      ],
      chartCapped: false,
      topTracks: const [
        RankedEntry(
          entity: TrackUI(
            uuidId: 't-x',
            createdAt: 0,
            lastUpdated: 0,
            duration: null,
            bitrateKbps: null,
            sampleRateHz: null,
            channels: null,
            hasAlbumArt: false,
          ),
          listeningSeconds: 40,
          qualifiedPlays: 1,
        ),
      ],
      topArtists: const [
        RankedEntry(
          entity: ArtistUI(id: 3, name: 'Known'),
          listeningSeconds: 40,
          qualifiedPlays: 1,
        ),
      ],
      topAlbums: const [
        RankedEntry(
          entity: AlbumUI(id: 9, artistId: 3),
          listeningSeconds: 40,
          qualifiedPlays: 1,
        ),
      ],
    );
    final recap = AnnualRecap.fromStats(
      stats,
      HistorySnapshotToken(
        boundaryLocalId: 7,
        historyContentVersion: 0,
        capturedNowUtcMs: now,
        filterKey: annualRecapFilterKey,
      ),
    );
    final json = jsonDecode(export.buildJson(recap)) as Map;
    final track = (json['top_tracks'] as List).single as Map;
    expect(track['uuid'], 't-x');
    expect(track.containsKey('title') && track['title'] == null, isTrue);
    expect(track.containsKey('artist') && track['artist'] == null, isTrue);
    expect(track.containsKey('album') && track['album'] == null, isTrue);
    final album = (json['top_albums'] as List).single as Map;
    expect(album['id'], 9);
    expect(album.containsKey('title') && album['title'] == null, isTrue);
    expect(album.containsKey('artist') && album['artist'] == null, isTrue);
  });
}
