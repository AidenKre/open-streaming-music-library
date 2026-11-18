import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/models/listening_stats.dart';

const _noteTimes =
    "All times are UTC. A listen counts in the day, month and year in which it started.";

const _noteListeningTime =
    "Listening time is recorded playback time. Rewinding and playing on two devices at once both add time, and a listen cut short when the app was stopped may lose its last seconds.";

const _noteQualifiedPlay =
    "A qualified play is a listen of at least 30 seconds, or of at least half the track when the track is shorter than a minute. This is OSML's own threshold.";

const _noteNames =
    "Names are the library's current metadata when the recap was generated, not the names at the time of listening.";

const _noteUnavailable =
    "Unavailable time is listening to tracks that were deleted or are not in this device's library. It is included in the totals but in no top list.";

const _noteLocalHistory =
    "Counted from the listening history on this device when the recap was generated. Listens from other devices that had not synced yet are not included.";

const _noteYearSoFar =
    "Year so far: listens are counted up to the generated time.";

/// Exports an [AnnualRecap] (spec §6). Every export reads the one recap
/// snapshot it is given and nothing else: no clock, no database, no
/// account, server or device fact, no Last.fm data.
class RecapExportService {
  const RecapExportService();

  /// The recap as JSON, schema 1: fixed key order, UTC timestamps as
  /// ISO 8601 with milliseconds and `Z`, exact seconds, null for an unknown
  /// label and for an absent busiest month, two-space indent and a trailing
  /// newline.
  String buildJson(AnnualRecap recap) {
    final window = recap.window;
    final busiest = recap.busiestMonth;
    final doc = <String, Object?>{
      'schema': 1,
      'kind': 'osml-annual-recap',
      'year': recap.year,
      'year_so_far': recap.isYearSoFar,
      'time_zone': 'UTC',
      'range': {
        'start_utc': _iso(window.startUtcMs!),
        'end_utc': _iso(window.endUtcMs),
        'counted_until_utc': _iso(window.countedEndUtcMs),
      },
      'generated_at_utc': _iso(recap.generatedAtUtcMs),
      'metrics': {
        'listening_seconds': recap.totals.listeningSeconds,
        'qualified_plays': recap.totals.qualifiedPlays,
        'unique_tracks': recap.totals.uniqueTracks,
        'active_days': recap.totals.activeDays,
      },
      'unavailable': {
        'listening_seconds': recap.unavailable.listeningSeconds,
        'qualified_plays': recap.unavailable.qualifiedPlays,
      },
      'busiest_month': busiest == null
          ? null
          : {
              'month': _month(busiest),
              'start_utc': _iso(busiest.startUtcMs),
              'end_utc': _iso(busiest.endUtcMs),
              'listening_seconds': busiest.listeningSeconds,
            },
      'months': [
        for (final m in recap.months)
          {'month': _month(m), 'listening_seconds': m.listeningSeconds},
      ],
      'top_tracks': _ranked(recap.topTracks, (t) => {
        'uuid': t.uuidId,
        'title': t.title,
        'artist': t.artist,
        'album': t.album,
      }),
      'top_artists': _ranked(recap.topArtists, (a) => {
        'id': a.id,
        'name': a.name,
      }),
      'top_albums': _ranked(recap.topAlbums, (a) => {
        'id': a.id,
        'title': a.name,
        'artist': a.artist,
      }),
      'notes': [
        _noteTimes,
        _noteListeningTime,
        _noteQualifiedPlay,
        _noteNames,
        _noteUnavailable,
        _noteLocalHistory,
        if (recap.isYearSoFar) _noteYearSoFar,
      ],
    };
    return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
  }

  static String _iso(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

  static String _month(ListeningBucket b) => _iso(b.startUtcMs).substring(0, 7);

  static List<Map<String, Object?>> _ranked<T>(
    List<RankedEntry<T>> entries,
    Map<String, Object?> Function(T) fields,
  ) => [
    for (var i = 0; i < entries.length; i++)
      {
        'rank': i + 1,
        ...fields(entries[i].entity),
        'listening_seconds': entries[i].listeningSeconds,
        'qualified_plays': entries[i].qualifiedPlays,
      },
  ];
}

final recapExportServiceProvider = Provider<RecapExportService>(
  (ref) => const RecapExportService(),
);
