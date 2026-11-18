// Phase 9A.1c (spec §3 "Performance fixture"; review §3; decision O14): the
// seeded 100,000-event / 10,000-track statistics fixture and its independent
// oracle. The generator and the oracle share nothing with the code under
// test: their own PRNG, their own reading of the spec §2 rules in plain Dart,
// no production SQL fragment. The recorded counts and checksum below prove a
// later run generates the same data (recorded in stats_perf_test.dart).
//
// Evidence recorded 2026-11-12 (macOS, debug-mode `flutter test`, in-memory
// Drift, machine shared with other runs: load average 6.5–7.3 on 12 cores;
// medians of 3; timings vary up to tenfold under load, so no test asserts
// them; reprint with OSML_PERF_EVIDENCE=1, see stats_perf_test.dart):
//   load 30 days 74 ms, this UTC year 243 ms, all time 807 ms;
//   ranking page 1 (all time): tracks 134 ms, artists 182 ms, albums 231 ms.
//   All time per statement: totals ~170 ms (walks every play row: it also
//   counts future rows), each of the three rankings 170–230 ms (correlated
//   catalog lookups per row), buckets ~45 ms, hydration 0 ms.
//   Plans: every history_events read is SEARCH … idx_history_events_kind_
//   occurred (kind=? AND occurred_at>? AND occurred_at<?), totals (kind=?);
//   no SCAN. The spec's candidate index (kind, entity_type, occurred_at,
//   entity_ref), created in the test DB only: SQLite uses it, no measurable
//   gain (all time 724 vs 807 ms, within noise), so it is not added (D5).
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';

/// The fixed seed of the fixture.
const perfSeed = 20261112;

/// "now" of the fixture: 2026-11-12T12:00Z.
const perfNowMs = 1794484800000;

const perfEventCount = 100000;
const perfTrackCount = 10000;
const perfArtistCount = 500;
const perfAlbumCount = 1000;

/// Played refs with no catalog row (deleted or never synced tracks).
const perfGoneCount = 200;

/// Spec §2 as the oracle reads it (independent of the repository): seconds
/// above a week of played audio are implausible (the 9A.1c bound).
const _oracleMaxSeconds = 604800.0;

const _dayMs = 86400000;

/// A 31-bit linear congruential generator (glibc constants): portable, and
/// independent of dart:math's unspecified Random algorithm.
class _Lcg {
  _Lcg(int seed) : _s = seed & 0x7fffffff;
  int _s;
  int next() => _s = (_s * 1103515245 + 12345) & 0x7fffffff;

  /// Uniform in [0, n), n at most 2^31 (draws are 31-bit).
  int below(int n) {
    assert(n <= 0x80000000);
    return next() % n;
  }

  /// Uniform in [0, 1).
  double unit() => next() / 0x80000000;
}

class PerfEvent {
  PerfEvent(this.uuid, this.kind, this.type, this.ref, this.at, this.seconds,
      this.length);
  final String uuid;
  final String kind;
  final String type;
  final String ref;
  final int at;
  final double? seconds;
  final double? length;

  String get canonical => '$uuid|$kind|$type|$ref|$at|$seconds|$length';
}

class PerfTrack {
  const PerfTrack(this.uuid, this.artistId, this.albumId);
  final String uuid;
  final int artistId;
  final int albumId;
}

String trackUuid(int i) => 'pt-${i.toString().padLeft(5, '0')}';

/// The generated fixture.
class PerfFixture {
  PerfFixture._(this.tracks, this.events);

  factory PerfFixture.generate() {
    final rng = _Lcg(perfSeed);
    final tracks = [
      for (var i = 0; i < perfTrackCount; i++)
        PerfTrack(trackUuid(i), _trackArtist(i), _trackAlbum(i)),
    ];
    final events = <PerfEvent>[];
    for (var i = 0; i < perfEventCount; i++) {
      final shape = rng.below(1000);
      // Kinds and types: mostly track plays, plus clicks, an unknown future
      // kind and plays of a non-track type (stored, never counted).
      final kind = shape < 20
          ? 'clicked'
          : shape < 30
              ? 'scrobble_v2'
              : 'play';
      final type = shape >= 30 && shape < 40 ? 'album' : 'track';
      // Skewed popularity (cube of a uniform), so rankings have heads,
      // long tails and many ties; 2 % of plays name a gone track.
      final String ref;
      if (rng.below(50) == 0) {
        ref = 'gone-${rng.below(perfGoneCount).toString().padLeft(3, '0')}';
      } else {
        final u = rng.unit();
        ref = trackUuid((u * u * u * perfTrackCount).floor());
      }
      // Starts over the last three years; 0.5 % in the future.
      final future = rng.below(200) == 0;
      final at = future
          ? perfNowMs + rng.below(30) * _dayMs + rng.below(_dayMs)
          : perfNowMs - 1 - rng.below(3 * 365) * _dayMs - rng.below(_dayMs);
      // Seconds: null, zero, negative, +Inf and a few absurd values among
      // millisecond-resolution positive listens (exact microseconds).
      final sShape = rng.below(1000);
      final double? seconds = switch (sShape) {
        < 5 => null,
        < 10 => 0.0,
        < 13 => -12.5,
        < 15 => double.infinity,
        < 16 => 1e9,
        _ => (1 + rng.below(400000)) / 1000,
      };
      final lShape = rng.below(20);
      final double? length = switch (lShape) {
        0 => null,
        1 => 0.0,
        _ => (30000 + rng.below(370000)) / 1000,
      };
      events.add(PerfEvent('pe-${i.toString().padLeft(6, '0')}', kind, type,
          ref, at, seconds, length));
    }
    return PerfFixture._(tracks, events);
  }

  final List<PerfTrack> tracks;
  final List<PerfEvent> events;

  /// Albums 1..1000 belong to artists 1..500; the extra albums
  /// 1001..1010 name artist 8888, which has no row (an orphan parent).
  static int _albumArtist(int albumId) => albumId <= perfAlbumCount
      ? (albumId - 1) % perfArtistCount + 1
      : _missingArtist;

  static const _missingArtist = 8888;

  /// Every 233rd track sits on an orphan album, every 307th on album 7777,
  /// which has no row; the rest on albums 1..1000.
  static int _trackAlbum(int i) => i % 307 == 0
      ? 7777
      : i % 233 == 0
          ? perfAlbumCount + 1 + i % 10
          : i % perfAlbumCount + 1;

  /// The track's own artist: usually its album's artist; every 97th track
  /// another artist (track artist differs from album artist); every 211th
  /// artist 9999, which has no row.
  static int _trackArtist(int i) {
    if (i % 211 == 0) return 9999;
    final albumArtist = (i % perfAlbumCount) % perfArtistCount + 1;
    return i % 97 == 0 ? albumArtist % perfArtistCount + 1 : albumArtist;
  }

  static bool _artistExists(int id) => id >= 1 && id <= perfArtistCount;

  static bool _albumExists(int id) => id >= 1 && id <= perfAlbumCount + 10;

  /// SHA-256 over every generated event and track, one canonical line each.
  String checksum() {
    final b = StringBuffer();
    for (final t in tracks) {
      b.writeln('${t.uuid}|${t.artistId}|${t.albumId}');
    }
    for (final e in events) {
      b.writeln(e.canonical);
    }
    return sha256.convert(utf8.encode(b.toString())).toString();
  }

  /// Inserts the catalog and the events (local ids 1..N in generation order).
  /// [eventLimit] seeds only the first that many events (a smaller history
  /// over the same catalog, for probes that must stay short).
  Future<void> seed(AppDatabase db, {int? eventLimit}) async {
    await db.batch((b) {
      for (var a = 1; a <= perfArtistCount; a++) {
        b.insert(db.artists,
            ArtistsCompanion(id: Value(a), name: Value('Artist $a')));
      }
      for (var al = 1; al <= perfAlbumCount + 10; al++) {
        b.insert(db.albums, AlbumsCompanion(
          id: Value(al),
          name: Value('Album $al'),
          artistId: Value(_albumArtist(al)),
          isSingleGrouping: const Value(false),
        ));
      }
      for (final t in tracks) {
        b.insert(db.tracks, TracksCompanion.insert(
          uuidId: t.uuid,
          createdAt: 1700000000,
          lastUpdated: 1700000100,
          revision: const Value(1),
        ));
        b.insert(db.trackmetadata, TrackmetadataCompanion(
          uuidId: Value(t.uuid),
          title: Value('Title ${t.uuid}'),
          artist: Value('Artist ${t.artistId}'),
          album: Value('Album ${t.albumId}'),
          artistId: Value(t.artistId),
          albumId: Value(t.albumId),
          duration: const Value(180.0),
        ));
      }
    });
    await db.batch((b) {
      for (final e in events.take(eventLimit ?? events.length)) {
        b.insert(db.historyEvents, HistoryEventsCompanion.insert(
          eventUuid: e.uuid,
          kind: e.kind,
          entityType: e.type,
          entityRef: e.ref,
          occurredAt: e.at,
          secondsPlayed: Value(e.seconds),
          trackLength: Value(e.length),
          pendingUpload: false,
        ));
      }
    });
  }

  /// The oracle for the half-open window `[start, min(end, now))`.
  PerfExpect oracle({required int? startMs, required int endMs}) {
    final byUuid = {for (final t in tracks) t.uuid: t};
    final countedEnd = endMs < perfNowMs ? endMs : perfNowMs;
    var micros = 0;
    var q = 0;
    final uniq = <String>{};
    final days = <int>{};
    var uMicros = 0;
    var uQ = 0;
    var future = 0;
    var overlong = 0;
    final trackRank = <String, List<int>>{};
    final artistRank = <int, List<int>>{};
    final albumRank = <int, List<int>>{};
    for (final e in events) {
      if (e.kind != 'play' || e.type != 'track') continue;
      final s = e.seconds;
      if (s == null || !(s > 0) || s == double.infinity) continue;
      final inWindow = (startMs == null || e.at >= startMs) && e.at < countedEnd;
      if (s > _oracleMaxSeconds) {
        // Counted as overlong whatever its date (in range, or future).
        if (inWindow || e.at >= perfNowMs) overlong++;
        continue;
      }
      if (e.at >= perfNowMs) future++;
      if (!inWindow) continue;
      final len = e.length;
      final threshold = len != null && len > 0 && len.isFinite
          ? (len / 2 < 30 ? len / 2 : 30.0)
          : 30.0;
      final qualified = s >= threshold;
      final m = (s * 1e6).round();
      micros += m;
      if (qualified) {
        q++;
        uniq.add(e.ref);
      }
      days.add(e.at ~/ _dayMs);
      final track = byUuid[e.ref];
      if (track == null) {
        uMicros += m;
        if (qualified) uQ++;
        continue;
      }
      _add(trackRank, track.uuid, m, qualified);
      // Parents rank only when their rows exist (an album also needs its
      // album artist's row): the spec's "current catalog parent IDs".
      if (_artistExists(track.artistId)) {
        _add(artistRank, track.artistId, m, qualified);
      }
      if (_albumExists(track.albumId) &&
          _artistExists(_albumArtist(track.albumId))) {
        _add(albumRank, track.albumId, m, qualified);
      }
    }
    return PerfExpect(
      listeningMicros: micros,
      qualifiedPlays: q,
      uniqueTracks: uniq.length,
      activeDays: days.length,
      unavailableMicros: uMicros,
      unavailableQualified: uQ,
      futureCount: future,
      overlongCount: overlong,
      tracks: _rank(trackRank),
      artists: _rank(artistRank),
      albums: _rank(albumRank),
    );
  }
}

void _add<K>(Map<K, List<int>> m, K key, int micros, bool qualified) {
  final acc = m.putIfAbsent(key, () => [0, 0]);
  acc[0] += micros;
  if (qualified) acc[1]++;
}

/// Micros DESC, qualified DESC, key ASC.
List<(K, int, int)> _rank<K extends Comparable<Object?>>(Map<K, List<int>> m) => [
  for (final e in m.entries) (e.key, e.value[0], e.value[1]),
]..sort((a, b) {
    if (a.$2 != b.$2) return b.$2.compareTo(a.$2);
    if (a.$3 != b.$3) return b.$3.compareTo(a.$3);
    return Comparable.compare(a.$1, b.$1);
  });

class PerfExpect {
  PerfExpect({
    required this.listeningMicros,
    required this.qualifiedPlays,
    required this.uniqueTracks,
    required this.activeDays,
    required this.unavailableMicros,
    required this.unavailableQualified,
    required this.futureCount,
    required this.overlongCount,
    required this.tracks,
    required this.artists,
    required this.albums,
  });
  final int listeningMicros;
  final int qualifiedPlays;
  final int uniqueTracks;
  final int activeDays;
  final int unavailableMicros;
  final int unavailableQualified;
  final int futureCount;
  final int overlongCount;

  /// Full rankings: (key, micros, qualified), rank order.
  final List<(String, int, int)> tracks;
  final List<(int, int, int)> artists;
  final List<(int, int, int)> albums;
}
