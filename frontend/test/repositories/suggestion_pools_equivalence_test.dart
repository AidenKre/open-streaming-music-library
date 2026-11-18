// Fix 9-fix-r4-fe (live defect 9-L-03): the rewritten "More from your
// artists" pool statement returns exactly what the shipped one returned
// (suggestion_pools_legacy.dart), row for row, on a
// seeded history built to sit on the edges: listens exactly at, 1 ms before
// and 1 ms after the 14- and 30-day lines and the captured now, rows beyond
// the insertion boundary, future, unqualified, zero, negative, null, infinite
// and absurd seconds, unknown and odd track lengths, clicks, unknown kinds,
// non-track plays naming a track uuid, gone tracks, artists without a row,
// tracks without an artist or a title, downloaded and damaged downloads, and
// many equal listening times (ties). The selection over both pools (the
// artist cap, the current track left out before the top 10 is taken, the
// Downloaded filter before the caps) is compared too.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/suggestions.dart';
import 'package:frontend/repositories/suggestion_pools_repository.dart';

import 'catalog_seed.dart';
import 'suggestion_pools_legacy.dart';

const _day = 86400000;
const _now = 1794484800000;
const _trackCount = 400;
const _eventCount = 4000;

/// Hand-placed rows of artists 43 and 44 (one track per edge).
/// (ref, kind, entity type, start offset from now, seconds, length).
const _edgeRows = <(String, String, String, int, double?, double?)>[
  // Artist 43: both tracks played, qualified, 20 days ago: a recent artist
  // with no candidate left.
  ('eq-a43-0', 'play', 'track', -20 * _day, 120.0, 300.0),
  ('eq-a43-1', 'play', 'track', -20 * _day, 120.0, 300.0),
  // Artist 44 (recent through eq-a44-played).
  ('eq-a44-played', 'play', 'track', -3 * _day, 120.0, 300.0),
  ('eq-a44-unq', 'play', 'track', -3 * _day, 29.999, 300.0), // 30 s line
  ('eq-a44-half', 'play', 'track', -3 * _day, 20.0, 40.0), // = length/2
  ('eq-a44-halfm', 'play', 'track', -3 * _day, 19.999, 40.0),
  ('eq-a44-nolen', 'play', 'track', -3 * _day, 29.0, null), // needs 30 s
  ('eq-a44-at', 'play', 'track', -1, 120.0, 300.0), // now - 1 ms
  ('eq-a44-now', 'play', 'track', 0, 120.0, 300.0), // starts at now
  ('eq-a44-fut', 'play', 'track', 2 * _day, 120.0, 300.0),
  ('eq-a44-album', 'play', 'album', -3 * _day, 120.0, 300.0),
  ('eq-a44-click', 'clicked', 'track', -3 * _day, 120.0, 300.0),
  ('eq-a44-zero', 'play', 'track', -3 * _day, 0.0, 300.0),
  ('eq-a44-null', 'play', 'track', -3 * _day, null, 300.0),
  ('eq-a44-inf', 'play', 'track', -3 * _day, double.infinity, 300.0),
  ('eq-a44-huge', 'play', 'track', -3 * _day, 1e9, 300.0),
  ('eq-a44-old', 'play', 'track', -400 * _day, 120.0, 300.0), // long ago
];

/// The last row (local id [_total]): a qualified play of eq-a44-late, beyond
/// the 3/4 insertion boundary.
final _total = _edgeRows.length + _eventCount + 1;

const _a44 = [
  'eq-a44-played', 'eq-a44-unq', 'eq-a44-half', 'eq-a44-halfm',
  'eq-a44-nolen', 'eq-a44-at', 'eq-a44-now', 'eq-a44-fut', 'eq-a44-album',
  'eq-a44-click', 'eq-a44-zero', 'eq-a44-null', 'eq-a44-inf', 'eq-a44-huge',
  'eq-a44-old', 'eq-a44-late', 'eq-a44-never',
];

/// glibc-constant LCG: the fixture's own seeded randomness.
class _Lcg {
  _Lcg(int seed) : _s = seed & 0x7fffffff;
  int _s;
  int below(int n) => (_s = (_s * 1103515245 + 12345) & 0x7fffffff) % n;
}

String _uuid(int i) => 'eq-${i.toString().padLeft(3, '0')}';

/// Artists 1..42 have rows; 77 has none; some tracks have no artist.
int? _artistOf(int i) => switch (i % 45) {
  42 => 77,
  43 => null,
  44 => 1,
  final r => r + 1,
};

Future<void> _seed(AppDatabase db) async {
  final seed = CatalogSeed(db);
  for (var a = 1; a <= 42; a++) {
    await seed.artist(a, 'Artist $a');
  }
  for (var i = 0; i < _trackCount; i++) {
    await seed.track(
      _uuid(i),
      artistId: _artistOf(i),
      // Few distinct titles: ties on title, broken by uuid.
      title: 'T${i % 9}',
      downloaded: i % 4 == 0,
      damaged: i % 13 == 0,
    );
  }
  await seed.artist(43, 'Artist 43');
  for (final u in ['eq-a43-0', 'eq-a43-1']) {
    await seed.track(u, artistId: 43, title: 'A43');
  }
  await seed.artist(44, 'Artist 44');
  for (final u in _a44) {
    await seed.track(u, artistId: 44, title: u);
  }
  // Unknown titles.
  await db.customStatement(
    "UPDATE trackmetadata SET title = NULL WHERE uuid_id GLOB 'eq-[0-9]*' "
    'AND CAST(substr(uuid_id, 4) AS INTEGER) % 17 = 0',
  );

  final rng = _Lcg(20261114);
  const edges = [
    0, -1, 1, //
    -14 * _day, -14 * _day - 1, -14 * _day + 1,
    -30 * _day, -30 * _day - 1, -30 * _day + 1,
    2 * _day,
  ];
  const seconds = <double?>[
    null, 0.0, -1.0, double.infinity, 1e9, 1.0, 29.999, 30.0, 30.0, 45.0,
    90.0, 120.0, 120.0, 200.0,
  ];
  const lengths = <double?>[null, 0.0, 40.0, 59.998, 60.0, 100.0, 300.0];
  await db.batch((b) {
    void row(int i, String ref, String kind, String type, int at, double? s,
        double? length) =>
      b.insert(db.historyEvents, HistoryEventsCompanion.insert(
        localId: Value(i),
        eventUuid: 'eqe-${i.toString().padLeft(5, '0')}',
        kind: kind,
        entityType: type,
        entityRef: ref,
        occurredAt: at,
        secondsPlayed: Value(s),
        trackLength: Value(length),
        pendingUpload: false,
      ));
    for (final (i, (ref, kind, type, offset, s, length))
        in _edgeRows.indexed) {
      row(i + 1, ref, kind, type, _now + offset, s, length);
    }
    row(_total, 'eq-a44-late', 'play', 'track', _now - 3 * _day, 120.0, 300.0);
    for (var i = _edgeRows.length + 1; i < _total; i++) {
      final shape = rng.below(100);
      final kind = shape < 3
          ? 'clicked'
          : shape < 5
              ? 'scrobble_v2'
              : 'play';
      final type = shape >= 5 && shape < 7 ? 'album' : 'track';
      final String ref;
      if (rng.below(33) == 0) {
        ref = 'gone-${rng.below(5)}';
      } else {
        // Skewed: a head of often played tracks, a long unplayed tail.
        final u = rng.below(1000) / 1000;
        ref = _uuid((u * u * _trackCount).floor());
      }
      final at = rng.below(10) < 3
          ? _now + edges[rng.below(edges.length)]
          : _now - 60 * _day + rng.below(63 * _day);
      final length = lengths[rng.below(lengths.length)];
      // Exactly half the length sometimes (the min(30, length/2) line).
      final s = rng.below(12) == 0 && length != null && length > 0
          ? length / 2
          : seconds[rng.below(seconds.length)];
      row(i, ref, kind, type, at, s, length);
    }
  });
}

typedef _Row = (String, int?, String?, bool);

/// artist id -> [micros, qualified plays, candidates sorted by uuid] (lists,
/// so the matcher compares them deeply).
Map<int, List<Object>> _normalized(List<ArtistPool> pools) {
  final out = <int, List<Object>>{};
  for (final p in pools) {
    final rows = [
      for (final c in p.candidates)
        (c.uuid, c.artistId, c.title, c.isDownloaded),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    expect(out.containsKey(p.artistId), isFalse, reason: 'one pool per artist');
    out[p.artistId] = [p.recentMicros, p.recentQualifiedPlays, rows];
  }
  return out;
}

void main() {
  late AppDatabase db;
  late SuggestionPoolsRepository repo;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await _seed(db);
    repo = SuggestionPoolsRepository(db);
  });

  tearDownAll(() => db.close());

  // Artist 44's candidates, derived by hand from _edgeRows (spec §5: a
  // catalog track with no qualified counted listen started before now within
  // the boundary); null: artist 44 is not a recent artist.
  const always = {
    'eq-a44-unq', 'eq-a44-halfm', 'eq-a44-nolen', 'eq-a44-fut',
    'eq-a44-album', 'eq-a44-click', 'eq-a44-zero', 'eq-a44-null',
    'eq-a44-inf', 'eq-a44-huge', 'eq-a44-never',
  };
  final a44 = <String, Set<String>?>{
    'all rows, now': {...always, 'eq-a44-now'},
    'all rows, now - 1 ms': {...always, 'eq-a44-now', 'eq-a44-at'},
    'all rows, now + 1 ms': always,
    'boundary at 3/4 of the rows, now': {
      ...always, 'eq-a44-now', 'eq-a44-late',
    },
    'all rows, now - 14 days': null,
  };

  final cases = <String, (int, int)>{
    'all rows, now': (_total, _now),
    'all rows, now - 1 ms': (_total, _now - 1),
    'all rows, now + 1 ms': (_total, _now + 1),
    'boundary at 3/4 of the rows, now': (_total * 3 ~/ 4, _now),
    'all rows, now - 14 days': (_total, _now - 14 * _day),
  };

  for (final MapEntry(key: name, value: (boundary, now)) in cases.entries) {
    test('$name: artist pools and picks equal the shipped statement\'s',
        () async {
      final got = await repo.load(boundary, now);
      final want = await legacyArtistPools(db, boundary, now);
      expect(got.artists, hasLength(want.length));
      final g = _normalized(got.artists);
      final w = _normalized(want);
      expect(g, w);
      expect(
        g[44] == null
            ? null
            : {for (final c in g[44]![2] as List<_Row>) c.$1},
        a44[name],
      );

      // The fixture reaches the edges it claims (not a vacuous match).
      final candidates =
          w.values.expand((v) => v[2] as List<_Row>).toList();
      expect(w.length, greaterThan(artistCap));
      expect(candidates.where((c) => c.$4), isNotEmpty);
      expect(candidates.where((c) => !c.$4), isNotEmpty);
      expect(candidates.where((c) => c.$3 == null), isNotEmpty);
      expect(w.values.where((v) => (v[2] as List).isEmpty), isNotEmpty,
          reason: 'a recent artist whose every track is played');

      final legacy = SuggestionPools(
        boundaryLocalId: boundary,
        capturedNowUtcMs: now,
        rediscover: got.rediscover,
        artists: want,
      );
      const off = BrowseFilters();
      final on = off.userSetDownloaded(true);
      final first = selectSuggestions(legacy, filter: off);
      expect(first.moreFromArtists, hasLength(suggestionCap));
      final currents = <String?>[
        null,
        first.moreFromArtists.first.uuid,
        first.moreFromArtists.last.uuid,
        if (first.rediscover.isNotEmpty) first.rediscover.first.uuid,
      ];
      for (final filter in [off, on]) {
        for (final current in currents) {
          final a = selectSuggestions(got, currentUuid: current, filter: filter);
          final b =
              selectSuggestions(legacy, currentUuid: current, filter: filter);
          expect(a.moreFromArtists, b.moreFromArtists,
              reason: 'current $current, downloaded ${filter.downloaded}');
          expect(a.rediscover, b.rediscover);
        }
      }
    });
  }
}
