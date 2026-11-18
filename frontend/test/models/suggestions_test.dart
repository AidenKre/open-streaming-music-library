// Phase 9B.1 (spec §5 items 1–2, para 3; review 9-U05): the pure suggestion
// selection. Every expected list here is written out by hand from the spec's
// rules; the pools are passed in shuffled so the rank rules are the
// function's, not the input order's.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/suggestions.dart';

const _all = BrowseFilters(policy: OfflineFilterPolicy.manual);
const _downloaded = BrowseFilters(
  downloaded: true,
  policy: OfflineFilterPolicy.manual,
);

SuggestionPools _pools({
  List<RediscoverCandidate> rediscover = const [],
  List<ArtistPool> artists = const [],
}) => SuggestionPools(
  boundaryLocalId: 100,
  capturedNowUtcMs: 1800000000000,
  rediscover: rediscover,
  artists: artists,
);

RediscoverCandidate _rd(
  String uuid, {
  required int micros,
  int lastAt = 1000,
  bool downloaded = false,
}) => RediscoverCandidate(
  track: SuggestionCandidate(uuid: uuid, isDownloaded: downloaded),
  listeningMicros: micros,
  qualifiedPlays: 2,
  lastQualifiedAtUtcMs: lastAt,
);

List<String> _uuids(List<SuggestionCandidate> l) => [for (final c in l) c.uuid];

/// `r00`..`r{n-1}`, ranked in that order (r00 has the most time).
List<RediscoverCandidate> _ranked(int n, {bool Function(int)? downloaded}) => [
  for (var i = 0; i < n; i++)
    _rd(
      'r${i.toString().padLeft(2, '0')}',
      micros: (1000 - i) * 1000000,
      downloaded: downloaded?.call(i) ?? false,
    ),
];


SuggestionCandidate _cand(
  String uuid,
  int artistId, {
  String? title = 'Same title',
  bool downloaded = false,
}) => SuggestionCandidate(
  uuid: uuid,
  artistId: artistId,
  title: title,
  isDownloaded: downloaded,
);

/// An artist whose candidates all share one title, so uuid decides.
ArtistPool _artist(
  int id,
  List<String> uuids, {
  required int micros,
  required int q,
}) => ArtistPool(
  artistId: id,
  recentMicros: micros,
  recentQualifiedPlays: q,
  candidates: [for (final u in uuids) _cand(u, id)],
);

void main() {
  group('Rediscover', () {
    test('ranks all-time seconds DESC, last qualified play ASC, uuid ASC', () {
      final pools = _pools(
        rediscover: [
          _rd('t-c', micros: 50000000, lastAt: 500),
          _rd('t-z', micros: 90000000, lastAt: 900),
          _rd('t-b', micros: 50000000, lastAt: 400),
          _rd('t-a', micros: 50000000, lastAt: 500),
          _rd('t-y', micros: 50000001, lastAt: 999),
        ],
      );
      final s = selectSuggestions(pools, filter: _all);
      // 90 s first; 50.000001 s beats 50 s; among 50 s, last play 400 before
      // 500; at 500, t-a before t-c.
      expect(_uuids(s.rediscover), ['t-z', 't-y', 't-b', 't-a', 't-c']);
    });

    test('takes 20 of more than 20 candidates', () {
      final s = selectSuggestions(
        _pools(rediscover: _ranked(25).reversed.toList()),
        filter: _all,
      );
      expect(_uuids(s.rediscover), [
        for (var i = 0; i < 20; i++) 'r${i.toString().padLeft(2, '0')}',
      ]);
    });

    test('the current track is excluded before the cap', () {
      final s = selectSuggestions(
        _pools(rediscover: _ranked(21)),
        currentUuid: 'r03',
        filter: _all,
      );
      expect(_uuids(s.rediscover), [
        'r00', 'r01', 'r02',
        for (var i = 4; i <= 20; i++) 'r${i.toString().padLeft(2, '0')}',
      ]);
    });

    test('a current track outside the pool changes nothing', () {
      final s = selectSuggestions(
        _pools(rediscover: _ranked(3)),
        currentUuid: 'elsewhere',
        filter: _all,
      );
      expect(_uuids(s.rediscover), ['r00', 'r01', 'r02']);
    });

    test('the Downloaded filter applies before the cap: downloaded matches '
        'ranked beyond the unfiltered 20 are kept', () {
      // 30 candidates; downloaded: r01, r05 and every one from r22 on.
      final pools = _pools(
        rediscover: _ranked(
          30,
          downloaded: (i) => i == 1 || i == 5 || i >= 22,
        ).reversed.toList(),
      );
      final unfiltered = selectSuggestions(pools, filter: _all);
      expect(unfiltered.rediscover.length, 20);
      expect(_uuids(unfiltered.rediscover), isNot(contains('r22')));

      final s = selectSuggestions(pools, filter: _downloaded);
      expect(_uuids(s.rediscover), [
        'r01', 'r05', 'r22', 'r23', 'r24', 'r25', 'r26', 'r27', 'r28', 'r29',
      ]);
    });

    test('filter and current-track exclusion combine before the cap', () {
      // 25 downloaded candidates; the current one is the best.
      final s = selectSuggestions(
        _pools(rediscover: _ranked(25, downloaded: (_) => true)),
        currentUuid: 'r00',
        filter: _downloaded,
      );
      expect(_uuids(s.rediscover), [
        for (var i = 1; i <= 20; i++) 'r${i.toString().padLeft(2, '0')}',
      ]);
    });

    test('Downloaded off keeps remote candidates', () {
      final s = selectSuggestions(
        _pools(rediscover: [_rd('remote', micros: 5), _rd('local', micros: 4,
            downloaded: true)]),
        filter: _all,
      );
      expect(_uuids(s.rediscover), ['remote', 'local']);
      expect(s.rediscover.first.isDownloaded, isFalse);
    });

    test('an empty pool collapses the rail', () {
      final s = selectSuggestions(_pools(), filter: _all);
      expect(s.rediscover, isEmpty);
    });

    test('a pool emptied by the exclusions collapses the rail', () {
      final pools = _pools(rediscover: [_rd('only', micros: 1)]);
      expect(
        selectSuggestions(pools, currentUuid: 'only', filter: _all).rediscover,
        isEmpty,
      );
      expect(
        selectSuggestions(pools, filter: _downloaded).rediscover,
        isEmpty,
      );
    });

    test('the same pools give the same list, whatever their order', () {
      final ranked = _ranked(25, downloaded: (i) => i.isEven);
      final a = selectSuggestions(_pools(rediscover: ranked), filter: _all);
      final b = selectSuggestions(
        _pools(rediscover: ranked.reversed.toList()),
        filter: _all,
      );
      final c = selectSuggestions(_pools(rediscover: ranked), filter: _all);
      expect(_uuids(a.rediscover), _uuids(b.rediscover));
      expect(_uuids(a.rediscover), _uuids(c.rediscover));
    });
  });

  group('More from your artists', () {
    test('artists by recent seconds DESC, recent qualified DESC, id ASC; '
        'first candidates of every artist, then the seconds', () {
      final pools = _pools(
        artists: [
          _artist(3, ['c1', 'c2'], micros: 50, q: 1),
          _artist(1, ['a1', 'a2'], micros: 90, q: 1),
          _artist(4, ['d1'], micros: 50, q: 2),
          _artist(2, ['b1', 'b2'], micros: 50, q: 1),
        ],
      );
      final s = selectSuggestions(pools, filter: _all);
      // Rank: 1 (90 s), 4 (50 s, 2 qualified), 2 (50 s, id 2), 3 (id 3).
      expect(_uuids(s.moreFromArtists), [
        'a1', 'd1', 'b1', 'c1', //
        'a2', 'b2', 'c2',
      ]);
    });

    test('at most two per artist, by normalized title then uuid', () {
      final pools = _pools(
        artists: [
          ArtistPool(
            artistId: 7,
            recentMicros: 10,
            recentQualifiedPlays: 1,
            candidates: [
              _cand('u5', 7, title: null),
              _cand('u4', 7, title: 'beta'),
              _cand('u3', 7, title: '  Alpha'),
              _cand('u2', 7, title: 'ALPHA'),
              _cand('u1', 7, title: 'Gamma'),
            ],
          ),
        ],
      );
      // "  Alpha" and "ALPHA" both normalize to "alpha": uuid u2 < u3.
      expect(_uuids(selectSuggestions(pools, filter: _all).moreFromArtists), [
        'u2',
        'u3',
      ]);
    });

    test('an unknown title sorts after every known title', () {
      final pools = _pools(
        artists: [
          ArtistPool(
            artistId: 7,
            recentMicros: 10,
            recentQualifiedPlays: 1,
            candidates: [
              _cand('a-untitled', 7, title: null),
              _cand('z-titled', 7, title: 'zzz'),
              _cand('b-untitled', 7, title: null),
            ],
          ),
        ],
      );
      final s = selectSuggestions(
        pools,
        currentUuid: 'z-titled',
        filter: _all,
      );
      expect(_uuids(s.moreFromArtists), ['a-untitled', 'b-untitled']);
      expect(
        _uuids(selectSuggestions(pools, filter: _all).moreFromArtists),
        ['z-titled', 'a-untitled'],
      );
    });

    test('takes ten of more than ten artists, capped at 20', () {
      final pools = _pools(
        artists: [
          for (var a = 12; a >= 1; a--)
            _artist(a, ['x$a-1', 'x$a-2', 'x$a-3'], micros: 100 - a, q: 1),
        ],
      );
      final s = selectSuggestions(pools, filter: _all);
      expect(_uuids(s.moreFromArtists), [
        for (var a = 1; a <= 10; a++) 'x$a-1',
        for (var a = 1; a <= 10; a++) 'x$a-2',
      ]);
    });

    test('artists with no eligible candidate are dropped before taking ten',
        () {
      // 12 artists, rank = id. Under Downloaded: artist 2 has only remote
      // candidates, artist 5's only candidate is the current track, artist 8
      // has none at all. Dropping them first lets 11 and 12 in: nine artists
      // are eligible, all taken.
      final pools = _pools(
        artists: [
          for (var a = 1; a <= 12; a++)
            ArtistPool(
              artistId: a,
              recentMicros: 100 - a,
              recentQualifiedPlays: 1,
              candidates: switch (a) {
                2 => [_cand('x2-1', 2), _cand('x2-2', 2)],
                5 => [_cand('x5-1', 5, downloaded: true)],
                8 => const [],
                _ => [_cand('x$a-1', a, downloaded: true)],
              },
            ),
        ],
      );
      final s = selectSuggestions(
        pools,
        currentUuid: 'x5-1',
        filter: _downloaded,
      );
      expect(_uuids(s.moreFromArtists), [
        for (final a in [1, 3, 4, 6, 7, 9, 10, 11, 12]) 'x$a-1',
      ]);
      // Without the filter artist 2 is back: exactly ten eligible artists.
      final unfiltered = selectSuggestions(
        pools,
        currentUuid: 'x5-1',
        filter: _all,
      );
      expect(_uuids(unfiltered.moreFromArtists), [
        for (final a in [1, 2, 3, 4, 6, 7, 9, 10, 11, 12]) 'x$a-1',
        'x2-2',
      ]);
    });

    test('the Downloaded filter applies before the two per artist', () {
      final pools = _pools(
        artists: [
          ArtistPool(
            artistId: 1,
            recentMicros: 10,
            recentQualifiedPlays: 1,
            candidates: [
              _cand('a', 1, title: 'a'),
              _cand('b', 1, title: 'b'),
              _cand('c', 1, title: 'c', downloaded: true),
              _cand('d', 1, title: 'd', downloaded: true),
              _cand('e', 1, title: 'e', downloaded: true),
            ],
          ),
        ],
      );
      expect(
        _uuids(selectSuggestions(pools, filter: _all).moreFromArtists),
        ['a', 'b'],
      );
      expect(
        _uuids(selectSuggestions(pools, filter: _downloaded).moreFromArtists),
        ['c', 'd'],
      );
    });

    test('the current track is excluded before the two per artist', () {
      final pools = _pools(artists: [_artist(1, ['a', 'b', 'c'], micros: 1, q: 1)]);
      expect(
        _uuids(
          selectSuggestions(pools, currentUuid: 'a', filter: _all)
              .moreFromArtists,
        ),
        ['b', 'c'],
      );
    });

    test('no artists, or none with an eligible candidate, collapses the rail',
        () {
      expect(selectSuggestions(_pools(), filter: _all).moreFromArtists, isEmpty);
      final pools = _pools(
        artists: [
          _artist(1, ['remote'], micros: 1, q: 1),
          _artist(2, [], micros: 1, q: 1),
        ],
      );
      expect(
        selectSuggestions(pools, filter: _downloaded).moreFromArtists,
        isEmpty,
      );
    });

    test('the rails are independent: Rediscover empty, artists not', () {
      final s = selectSuggestions(
        _pools(artists: [_artist(1, ['a'], micros: 1, q: 1)]),
        filter: _all,
      );
      expect(s.rediscover, isEmpty);
      expect(_uuids(s.moreFromArtists), ['a']);
    });
  });
}
