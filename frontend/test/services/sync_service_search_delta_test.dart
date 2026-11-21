// PM-APP-SEARCH: a catalog sync updates the search index page by page, in
// the transaction that saves the page, instead of rebuilding it after every
// sync. The index after any sequence of syncs must answer every search
// exactly as a full rebuild from the same data would, and a sync must not
// touch more of the index than the tracks it changed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ftsTables = ['fts_tracks', 'fts_artists', 'fts_albums'];

/// One track as the server describes it.
class _T {
  const _T(
    this.uuid, {
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.artistId,
    this.albumId,
    this.year,
  });

  final String uuid;
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? artistId;
  final int? albumId;
  final int? year;
}

Map<String, Object?> _upsert(_T t, int revision) => {
  'type': 'upsert',
  'revision': revision,
  'uuid_id': t.uuid,
  'track': {
    'uuid_id': t.uuid,
    'created_at': 1,
    'last_updated': 1,
    'revision': revision,
    'metadata': {
      'title': t.title,
      'artist': t.artist,
      'album': t.album,
      'album_artist': t.albumArtist,
      'artist_id': t.artistId,
      'album_id': t.albumId,
      'year': t.year,
      'codec': 'flac',
      'duration': 10.0,
      'bitrate_kbps': 900.0,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  },
};

Map<String, Object?> _delete(String uuid, int revision) => {
  'type': 'delete',
  'revision': revision,
  'uuid_id': uuid,
};

/// An entry of a page before the fake server numbers it.
sealed class _Op {
  const _Op();
}

class _Up extends _Op {
  const _Up(this.t);
  final _T t;
}

class _Del extends _Op {
  const _Del(this.uuid);
  final String uuid;
}

/// Records every statement that names a search table, and how many search
/// rows the writing ones wrote (`changes()` right after the statement; one
/// row per execution of a batched statement).
class _FtsRecorder extends QueryInterceptor {
  final statements = <String>[];
  var rowsWritten = 0;

  void reset() {
    statements.clear();
    rowsWritten = 0;
  }

  /// Full rebuilds of the track index (its 'delete-all' command).
  int get fullTrackRebuilds => statements
      .where((s) => s.contains("fts_tracks(fts_tracks) VALUES('delete-all')"))
      .length;

  static bool _isFts(String sql) => sql.contains('fts_');

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await super.runCustom(executor, statement, args);
    if (_isFts(statement)) {
      statements.add(statement);
      final r = await executor.runSelect('SELECT changes() AS n', const []);
      rowsWritten += r.single['n']! as int;
    }
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (_isFts(statement)) statements.add(statement);
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final id = await super.runInsert(executor, statement, args);
    if (_isFts(statement)) {
      statements.add(statement);
      rowsWritten += 1;
    }
    return id;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final n = await super.runUpdate(executor, statement, args);
    if (_isFts(statement)) {
      statements.add(statement);
      rowsWritten += n;
    }
    return n;
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final n = await super.runDelete(executor, statement, args);
    if (_isFts(statement)) {
      statements.add(statement);
      rowsWritten += n;
    }
    return n;
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) async {
    await super.runBatched(executor, statements);
    for (final args in statements.arguments) {
      final sql = statements.statements[args.statementIndex];
      if (_isFts(sql)) {
        this.statements.add(sql);
        rowsWritten += 1;
      }
    }
  }
}

/// A fake `/changes` server that numbers the entries it is given and serves
/// them in the pages the test asks for.
class _Harness {
  _Harness(this.db) : recorder = null;
  _Harness._recorded(this.db, this.recorder);

  /// [executor]: the in-memory database unless given.
  factory _Harness.recorded({QueryExecutor? executor}) {
    final recorder = _FtsRecorder();
    return _Harness._recorded(
      AppDatabase((executor ?? NativeDatabase.memory()).interceptWith(recorder)),
      recorder,
    );
  }

  final AppDatabase db;
  final _FtsRecorder? recorder;
  late final String token;
  final pages = <int, Map<String, Object?>>{};
  var revision = 0;

  /// Requests for an `after_revision` held here wait for the completer.
  final holds = <int, Completer<void>>{};
  final requested = <int, Completer<void>>{};

  Future<void> init() async {
    token = (await ServerBindingRepository(db)
            .ensureProvisional('http://test:8080'))
        .localBindingId;
  }

  SyncService service() {
    SharedPreferences.setMockInitialValues({});
    final api = testApiClient(
      'http://test:8080',
      MockClient((req) async {
        final after = int.parse(req.url.queryParameters['after_revision']!);
        requested[after]?.complete();
        final hold = holds[after];
        if (hold != null) await hold.future;
        final page = pages[after];
        if (page == null) return http.Response('no page for $after', 500);
        return http.Response(jsonEncode(page), 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    return SyncService(
      db: db,
      api: TracksApi(api: api),
      queueRepository: QueueRepository(db),
      bindingToken: token,
    );
  }

  /// Serves [pageOps] as consecutive pages (an empty list: a sync that
  /// brings nothing); [failAfter] pages are served and the next request
  /// fails.
  void serve(List<List<_Op>> pageOps, {int? failAfter}) {
    pages.clear();
    final start = revision;
    if (pageOps.isEmpty) {
      pages[start] = {
        'changes': <Object>[],
        'nextCursor': null,
        'latestRevision': start,
      };
      return;
    }
    final built = <(int, List<Map<String, Object?>>)>[];
    var after = start;
    for (final ops in pageOps) {
      final entries = [
        for (final op in ops)
          switch (op) {
            _Up(:final t) => _upsert(t, ++revision),
            _Del(:final uuid) => _delete(uuid, revision += 1),
          },
      ];
      built.add((after, entries));
      after = revision;
    }
    for (var i = 0; i < built.length; i++) {
      if (failAfter != null && i >= failAfter) break;
      final (pageAfter, entries) = built[i];
      final last = i == built.length - 1;
      pages[pageAfter] = {
        'changes': entries,
        'nextCursor': last ? null : built[i + 1].$1,
        'latestRevision': revision,
      };
    }
  }

  /// Runs one sync of [pageOps]. With a recorder, it also checks that the
  /// sync never fell back to rebuilding the track index: a healthy index is
  /// only ever updated per page.
  Future<void> sync(List<List<_Op>> pageOps) async {
    recorder?.reset();
    serve(pageOps);
    await service().syncChanges();
    if (recorder != null) {
      expect(recorder!.fullTrackRebuilds, 0,
          reason: 'a healthy index never takes the full-rebuild fallback');
    }
  }
}

/// Everything the three search tables hold, read through FTS5's own views:
/// every indexed token instance (`fts5vocab`, instance form: term, row,
/// column, offset), every row's column sizes (`%_docsize`) and the table
/// totals bm25 ranks with (`%_data` id 1, the averages record), the rowids
/// a full scan returns, plus what the app's search answers for [terms].
Future<Map<String, Object>> _indexState(
  AppDatabase db,
  List<String> terms,
) async {
  final state = <String, Object>{};
  for (final t in _ftsTables) {
    Future<List<String>> rows(String sql) async => [
      for (final r in await db.customSelect(sql).get())
        r.data.values.join('|'),
    ];
    state['$t vocab'] = await rows(
      'SELECT term, doc, col, offset FROM temp.v_$t '
      'ORDER BY term, doc, col, offset',
    );
    state['$t docsize'] =
        await rows('SELECT id, hex(sz) FROM ${t}_docsize ORDER BY id');
    state['$t averages'] =
        await rows('SELECT hex(block) FROM ${t}_data WHERE id = 1');
    state['$t rowids'] = await rows('SELECT rowid FROM $t ORDER BY rowid');
  }
  for (final term in terms) {
    final r = await db.getSearchResults(term, limitPerType: 100000);
    state['search "$term"'] = [
      'tracks: ${r.tracks.map((q) => q.read<String>('uuid_id')).join(',')}',
      'artists: ${r.artists.map((q) => q.read<int>('id')).join(',')}',
      'albums: ${r.albums.map((q) => q.read<int>('id')).join(',')}',
    ];
  }
  return state;
}

class _Rollback implements Exception {
  const _Rollback();
}

/// Runs [body] in a transaction that is rolled back afterwards.
Future<T> _thenRollBack<T>(AppDatabase db, Future<T> Function() body) async {
  late T result;
  try {
    await db.transaction(() async {
      result = await body();
      throw const _Rollback();
    });
  } on _Rollback {
    // the rebuild is undone: the database keeps its incremental index
  }
  return result;
}

Future<List<String>> _vocabTerms(AppDatabase db) async => [
  for (final t in _ftsTables)
    for (final r in await db
        .customSelect('SELECT DISTINCT term FROM temp.v_$t')
        .get())
      r.read<String>('term'),
];

Future<void> _createVocabViews(AppDatabase db) async {
  for (final t in _ftsTables) {
    await db.customStatement(
      'CREATE VIRTUAL TABLE IF NOT EXISTS temp.v_$t '
      'USING fts5vocab(main, $t, instance)',
    );
  }
}

/// The index equals a full rebuild from the same tables: FTS5's integrity
/// check passes on it, its content (tokens, sizes, totals, rowids) is the
/// rebuilt one's, and the app's search answers every term (every indexed
/// token of either, plus [probes]) the same way. The rebuild is rolled back.
Future<void> _expectMatchesRebuild(
  AppDatabase db, {
  required String when,
  List<String> probes = const [],
}) async {
  await _createVocabViews(db);
  for (final t in _ftsTables) {
    await db.customStatement("INSERT INTO $t($t) VALUES('integrity-check')");
  }
  final rebuiltTerms = await _thenRollBack(db, () async {
    await db.rebuildFtsIndexes();
    return _vocabTerms(db);
  });
  final terms = {...await _vocabTerms(db), ...rebuiltTerms, ...probes}.toList()
    ..sort();
  final incremental = await _indexState(db, terms);
  final rebuilt = await _thenRollBack(db, () async {
    await db.rebuildFtsIndexes();
    return _indexState(db, terms);
  });
  expect(incremental.keys, rebuilt.keys, reason: when);
  for (final key in rebuilt.keys) {
    expect(incremental[key], rebuilt[key], reason: '$when: $key');
  }
}

Future<List<String>> _trackHits(AppDatabase db, String term) async => [
  for (final r in (await db.getSearchResults(term, limitPerType: 1000)).tracks)
    r.read<String>('uuid_id'),
];

Future<List<int>> _artistHits(AppDatabase db, String term) async => [
  for (final r in (await db.getSearchResults(term, limitPerType: 1000)).artists)
    r.read<int>('id'),
];

Future<List<int>> _albumHits(AppDatabase db, String term) async => [
  for (final r in (await db.getSearchResults(term, limitPerType: 1000)).albums)
    r.read<int>('id'),
];

// ── The hand-written library ────────────────────────────────────────────

const _ella = 'Ella Fitzgerald';
const t1 = _T('t1',
    title: 'Blue Moon', artist: _ella, album: 'Songbook', artistId: 1, albumId: 10);
const t2 = _T('t2',
    title: 'Café Ünïcode 東京', artist: 'Björk', album: 'Début', artistId: 2, albumId: 20);
const t3 = _T('t3',
    title: '', artist: _ella, album: 'Songbook', artistId: 1, albumId: 10);
const t4 = _T('t4');
const t5 = _T('t5',
    title: 'Night Train',
    artist: 'Oscar',
    albumArtist: 'Oscar Peterson Trio',
    album: 'Night Train LP',
    artistId: 3,
    albumId: 31);
const t6 = _T('t6',
    title: 'Solo Single', artist: 'Nina', album: '', artistId: 4, albumId: 40, year: 1999);

const _probes = [
  'blue', 'Café', 'cafe', '東京', 'ella', 'songbook', 'bjork', 'gudmundsdottir',
  'oscar', 'trio', 'night', 'montreux', 'green', 'sarah', 'sassy', 'solo',
  'nina', 'fresh', 'reborn', 'zzz',
];

void main() {
  late _Harness h;

  group('hand-written syncs', () {
    setUp(() async {
      h = _Harness.recorded();
      await h.init();
    });
    tearDown(() => h.db.close());

    Future<void> base() => h.sync([
      [_Up(t1), _Up(t2), _Up(t3)],
      [_Up(t4), _Up(t5), _Up(t6)],
    ]);

    test('new tracks, in two pages, are found', () async {
      await base();
      await _expectMatchesRebuild(h.db, when: 'after the first sync', probes: _probes);
      expect(await _trackHits(h.db, 'blue'), ['t1']);
      expect(await _trackHits(h.db, 'cafe'), ['t2']);
      expect(await _trackHits(h.db, '東京'), ['t2']);
      expect(await _artistHits(h.db, 'trio'), [3]);
      expect(await _albumHits(h.db, 'songbook'), [10]);
    });

    test('retitled, re-arted, re-albumed and moved tracks; a repeated '
        'unchanged track; the same change twice; a deleted track', () async {
      await base();
      const t1Green = _T('t1',
          title: 'Green Sun', artist: _ella, album: 'Songbook', artistId: 1, albumId: 10);
      await h.sync([
        [
          _Up(t1Green),
          // the artist renamed: same id, new name
          const _Up(_T('t2',
              title: 'Café Ünïcode 東京',
              artist: 'Björk Gudmundsdóttir',
              album: 'Début',
              artistId: 2,
              albumId: 20)),
          // a new album for t5; its old album is left with no track
          _Up(const _T('t5',
              title: 'Night Train',
              artist: 'Oscar',
              albumArtist: 'Oscar Peterson Trio',
              album: 'Live at Montreux',
              artistId: 3,
              albumId: 32)),
          // t3 moves to a new artist and album
          _Up(const _T('t3',
              title: '', artist: 'Sarah Vaughan', album: 'Sassy', artistId: 5, albumId: 50)),
          _Up(t6), // unchanged
          _Del('t4'),
          _Up(t1Green), // the same change twice in one page
        ],
      ]);
      await _expectMatchesRebuild(h.db, when: 'after the changes', probes: _probes);
      expect(await _trackHits(h.db, 'blue'), isEmpty);
      expect(await _trackHits(h.db, 'green'), ['t1']);
      expect(await _artistHits(h.db, 'gudmundsdottir'), [2]);
      expect(await _albumHits(h.db, 'montreux'), [32]);
      expect(await _albumHits(h.db, 'night'), isEmpty,
          reason: 'the emptied album is removed from the album index');
      expect(await _artistHits(h.db, 'sarah'), [5]);
      expect(await _trackHits(h.db, 'solo'), ['t6']);

      // The same change arriving again in a later sync changes nothing.
      await h.sync([
        [_Up(t1Green)],
      ]);
      await _expectMatchesRebuild(h.db, when: 'after the repeat', probes: _probes);
      expect(await _trackHits(h.db, 'green'), ['t1']);
    });

    test('an artist left with no tracks leaves the artist index', () async {
      await base();
      await h.sync([
        [
          _Up(const _T('t1',
              title: 'Blue Moon', artist: 'Sarah Vaughan', album: 'Sassy', artistId: 5, albumId: 50)),
          _Del('t3'),
        ],
      ]);
      await _expectMatchesRebuild(h.db, when: 'after Ella lost her tracks', probes: _probes);
      expect(await _artistHits(h.db, 'ella'), isEmpty);
      expect(await _albumHits(h.db, 'songbook'), isEmpty);
      expect(await _artistHits(h.db, 'sarah'), [5]);
      expect(await _trackHits(h.db, 'blue'), ['t1']);
    });

    test('a page of deletions only: the emptied artist and album leave their '
        'indexes', () async {
      await base();
      await h.sync([
        [const _Del('t6')],
      ]);
      await _expectMatchesRebuild(h.db, when: 'after Nina lost her only track', probes: _probes);
      expect(await _artistHits(h.db, 'nina'), isEmpty);
      expect(await _trackHits(h.db, 'solo'), isEmpty);
    });

    test('a deleted track, a new one taking its rowid, an upsert then a '
        'delete and a delete then an upsert in one page; null and empty '
        'values', () async {
      await base();
      // t6 has the highest rowid; a new track inserted after its delete in
      // the same page reuses it.
      await h.sync([
        [
          _Del('t6'),
          _Up(const _T('t7', title: 'Fresh Start', artist: 'Nina', album: '', artistId: 4, albumId: 40, year: 1999)),
          _Up(const _T('t1', title: 'Gone Soon', artist: _ella, album: 'Songbook', artistId: 1, albumId: 10)),
          _Del('t1'),
          _Del('t5'),
          _Up(const _T('t5', title: 'Night Train Reborn', artist: 'Oscar', albumArtist: 'Oscar Peterson Trio', album: 'Night Train LP', artistId: 3, albumId: 31)),
          // every indexed value null
          const _Up(_T('t2', artistId: 2, albumId: 20)),
        ],
      ]);
      await _expectMatchesRebuild(h.db, when: 'after the mixed page', probes: _probes);
      expect(await _trackHits(h.db, 'solo'), isEmpty);
      expect(await _trackHits(h.db, 'fresh'), ['t7']);
      expect(await _trackHits(h.db, 'gone'), isEmpty);
      expect(await _trackHits(h.db, 'blue'), isEmpty);
      expect(await _trackHits(h.db, 'reborn'), ['t5']);
      expect(await _trackHits(h.db, 'cafe'), isEmpty);

      // A sync that brings nothing leaves it as it is.
      await h.sync([]);
      await _expectMatchesRebuild(h.db, when: 'after an empty sync', probes: _probes);
    });
  });

  group('a seeded random sequence', () {
    // Artist and album names stay unique per id (the schema's unique
    // indexes); a rename bumps the id's version. Albums 7 and 8 are single
    // groupings (no album name), unique by (artist, year): year = album id.
    const artistWords = ['Alpha', 'Ça va', 'Δelta', '東 京', 'Echo'];
    const titleWords = [
      'love', 'naïve', 'Ünïcode', '日本語', 'rock', 'roll', 'O\'Brien',
      'blue', 'moon', 'x',
    ];

    for (final seed in [1, 2, 3, 4, 5, 6]) {
      test('seed $seed', () async {
        h = _Harness.recorded();
        await h.init();
        addTearDown(h.db.close);
        final rnd = Random(seed);
        final artistVersion = List.filled(6, 0);
        final albumVersion = List.filled(9, 0);
        final albumArtist = [0, 1, 2, 3, 4, 5, 1, 2, 3];
        String artistName(int id) => '${artistWords[id - 1]} v${artistVersion[id]}';
        String? albumName(int id) =>
            id >= 7 ? (rnd.nextBool() ? '' : null) : 'Album$id v${albumVersion[id]}';
        String? title() => switch (rnd.nextInt(8)) {
          0 => null,
          1 => '',
          _ => [
            for (var i = 0; i <= rnd.nextInt(3); i++)
              titleWords[rnd.nextInt(titleWords.length)],
          ].join(' '),
        };
        _T track(String uuid) {
          if (rnd.nextInt(6) == 0) return _T(uuid, title: title());
          final albumId = 1 + rnd.nextInt(8);
          final artistId = albumArtist[albumId];
          return _T(uuid,
              title: title(),
              artist: artistName(artistId),
              album: albumName(albumId),
              artistId: artistId,
              albumId: albumId,
              year: albumId);
        }

        final known = <String, _T>{};
        for (var s = 0; s < 10; s++) {
          // Between syncs the server may rename an artist or an album, or
          // move an album to another artist.
          if (rnd.nextInt(3) == 0) artistVersion[1 + rnd.nextInt(5)]++;
          if (rnd.nextInt(3) == 0) albumVersion[1 + rnd.nextInt(6)]++;
          if (rnd.nextInt(4) == 0) albumArtist[1 + rnd.nextInt(8)] = 1 + rnd.nextInt(5);
          final pageCount = rnd.nextInt(4); // 0: a sync that brings nothing
          final pagesOps = <List<_Op>>[];
          for (var p = 0; p < pageCount; p++) {
            final ops = <_Op>[];
            for (var e = 0; e <= rnd.nextInt(6); e++) {
              final uuid = 'r${rnd.nextInt(20)}';
              switch (rnd.nextInt(10)) {
                case 0 || 1:
                  ops.add(_Del(uuid));
                  known.remove(uuid);
                case 2 when known.containsKey(uuid):
                  ops.add(_Up(known[uuid]!)); // repeated, unchanged
                case 3 when ops.isNotEmpty:
                  ops.add(ops.last); // the same change twice
                default:
                  final t = track(uuid);
                  known[uuid] = t;
                  ops.add(_Up(t));
              }
            }
            pagesOps.add(ops);
          }
          await h.sync(pagesOps);
          await _expectMatchesRebuild(h.db, when: 'seed $seed, sync $s');
        }
      });
    }
  });

  group('failures and interruptions', () {
    test('a sync that fails on its third page: search finds what pages one '
        'and two brought and nothing else, without a rebuild', () async {
      h = _Harness.recorded();
      await h.init();
      addTearDown(h.db.close);
      await h.sync([
        [_Up(const _T('old', title: 'Common Old'))],
      ]);
      h.recorder!.reset();
      h.serve([
        [_Up(const _T('p1', title: 'Common One'))],
        [_Up(const _T('p2', title: 'Common Two', artist: 'Pagetwo', artistId: 9))],
        [_Up(const _T('p3', title: 'Common Three'))],
      ], failAfter: 2);
      await expectLater(h.service().syncChanges(), throwsA(isA<ApiException>()));

      expect((await _trackHits(h.db, 'common'))..sort(), ['old', 'p1', 'p2']);
      expect(await _trackHits(h.db, 'three'), isEmpty);
      expect(await _artistHits(h.db, 'pagetwo'), [9]);
      expect(
        h.recorder!.statements
            .where((s) => s.contains("fts_tracks(fts_tracks) VALUES('delete-all')")),
        isEmpty,
        reason: 'no track index rebuild during or after the failed sync (page '
            "two's new artist rebuilds only the two small indexes)",
      );
      await _expectMatchesRebuild(h.db, when: 'after the failed sync');
    });

    test('killed between pages: a fresh open finds page one by search',
        () async {
      final dir = Directory.systemTemp.createTempSync('pm_app_search_');
      final file = File('${dir.path}/app.db');
      h = _Harness(AppDatabase(NativeDatabase(file)));
      await h.init();
      h.serve([
        [_Up(const _T('k1', title: 'Survivor Song', artist: 'Kept', artistId: 7, album: 'Kept Album', albumId: 70))],
        [_Up(const _T('k2', title: 'Never Arrives'))],
      ]);
      // The second page's request never answers while the app "dies".
      final secondPage = h.pages.keys.reduce(max);
      h.holds[secondPage] = Completer<void>();
      h.requested[secondPage] = Completer<void>();
      final run = h.service().syncChanges();
      await h.requested[secondPage]!.future; // page one has committed

      // A second connection to the same file, as a restarted app opens it.
      final warned = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final fresh = AppDatabase(NativeDatabase(file));
      try {
        expect(await _trackHits(fresh, 'survivor'), ['k1']);
        expect(await _artistHits(fresh, 'kept'), [7]);
        expect(await _albumHits(fresh, 'kept'), [70]);
        expect(await _trackHits(fresh, 'never'), isEmpty);
      } finally {
        await fresh.close();
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = warned;
        // Let the held request end (as a failure) so nothing outlives the
        // test.
        h.pages.remove(secondPage);
        h.holds[secondPage]!.complete();
        await expectLater(run, throwsA(anything));
        await h.db.close();
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('cost at 50,000 tracks', () {
    const n = 50000;

    setUp(() async {
      h = _Harness.recorded();
      await h.init();
      // Built by SQL: 500 artists, 5,000 albums, 50,000 tracks, then indexed.
      await h.db.customStatement(
        'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 500) '
        "INSERT INTO artists(id, name) SELECT i, 'Artist ' || i FROM n",
      );
      await h.db.customStatement(
        'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5000) '
        'INSERT INTO albums(id, name, artist_id, is_single_grouping) '
        "SELECT i, 'Album ' || i, ((i - 1) % 500) + 1, 0 FROM n",
      );
      await h.db.customStatement(
        'WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < $n - 1) '
        'INSERT INTO tracks(uuid_id, created_at, last_updated, revision) '
        "SELECT 'b' || i, 1, 1, 1 FROM n",
      );
      await h.db.customStatement(
        'WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < $n - 1) '
        'INSERT INTO trackmetadata(uuid_id, title, artist, album, artist_id, album_id, has_album_art) '
        "SELECT 'b' || i, 'Title ' || i, 'Artist ' || ((i % 500) + 1), "
        "'Album ' || ((i % 5000) + 1), (i % 500) + 1, (i % 5000) + 1, 0 FROM n",
      );
      await h.db.transaction(() => h.db.rebuildFtsIndexes());
      h.recorder!.reset();
    });
    tearDown(() => h.db.close());

    _T existing(int i, {required String title, String? artistName}) {
      final artistId = (i % 500) + 1;
      final albumId = (i % 5000) + 1;
      return _T('b$i',
          title: title,
          artist: artistName ?? 'Artist $artistId',
          album: 'Album $albumId',
          artistId: artistId,
          albumId: albumId);
    }

    test('a sync that changes nothing runs no statement on a search table',
        () async {
      await h.sync([]);
      expect(h.recorder!.statements, isEmpty);
      expect(h.recorder!.rowsWritten, 0);
    });

    test('a page that retitles 50 tracks writes about 100 search rows, not '
        '50,000, and touches no artist or album index', () async {
      await h.sync([
        [for (var i = 0; i < 50; i++) _Up(existing(i * 997, title: 'Renamed $i'))],
      ]);
      // 50 deletions of the old terms + 50 insertions of the new ones.
      expect(h.recorder!.rowsWritten, 100);
      expect(
        h.recorder!.statements.where((s) => s.contains('fts_artists') || s.contains('fts_albums')),
        isEmpty,
      );
      expect(await _trackHits(h.db, 'renamed'), hasLength(50));
    });

    test('a page that renames an artist rebuilds only the artist and album '
        'indexes besides its own tracks\' entries', () async {
      await h.sync([
        [_Up(existing(0, title: 'Title 0', artistName: 'Artist One Renamed'))],
      ]);
      // 2 track rows + the artist and album indexes (500 + 5,000 rows).
      expect(h.recorder!.rowsWritten, lessThan(6000));
      expect(await _artistHits(h.db, 'renamed'), [1]);
      expect(await _albumHits(h.db, 'renamed'), hasLength(10),
          reason: 'the ten albums of artist 1 carry its new name');
    });
  });

  group('the safety net: an index that does not hold what the tables say', () {
    Future<int> cursor(AppDatabase db) async =>
        (await db
                .customSelect(
                  "SELECT value FROM sync_cursors WHERE stream = 'catalog'",
                )
                .getSingleOrNull())
            ?.read<int>('value') ??
        0;

    Future<String?> titleOf(AppDatabase db, String uuid) async => (await db
            .customSelect(
              'SELECT title FROM trackmetadata WHERE uuid_id = ?',
              variables: [Variable.withString(uuid)],
            )
            .getSingleOrNull())
        ?.read<String?>('title');

    for (final background in [false, true]) {
      final where = background
          ? 'a file database in a background isolate, as the app opens it'
          : 'an in-memory database';
      test('a sync that changes tracks that were never indexed saves its '
          'page, rebuilds the index once, and goes on per page ($where)',
          () async {
        final dir = Directory.systemTemp.createTempSync('pm_app_search_net_');
        addTearDown(() => dir.deleteSync(recursive: true));
        h = _Harness.recorded(
          executor: background
              ? NativeDatabase.createInBackground(File('${dir.path}/app.db'))
              : null,
        );
        await h.init();
        addTearDown(h.db.close);
        await _writeUnindexed(h.db, [t1, t2, t3]);
        h.recorder!.reset();

        h.serve([
          [
            const _Up(_T('t1',
                title: 'Green Sun', artist: _ella, album: 'Songbook', artistId: 1, albumId: 10)),
            _Up(t5),
          ],
        ]);
        await h.service().syncChanges();

        expect(h.recorder!.fullTrackRebuilds, 1,
            reason: 'the page fell back to one full rebuild');
        expect(await cursor(h.db), h.revision, reason: 'the page is saved');
        expect(await titleOf(h.db, 't1'), 'Green Sun');
        await _expectMatchesRebuild(h.db, when: 'after the fallback', probes: _probes);
        expect(await _trackHits(h.db, 'green'), ['t1']);
        expect(await _trackHits(h.db, 'cafe'), ['t2'],
            reason: 'a track the page did not touch is indexed by the rebuild');

        // The index matches again: the next page is updated per page
        // (h.sync checks that no full rebuild ran).
        await h.sync([
          [const _Up(_T('t3', title: 'Third Again', artist: _ella, album: 'Songbook', artistId: 1, albumId: 10))],
        ]);
        await _expectMatchesRebuild(h.db, when: 'after the next page', probes: _probes);
        expect(await _trackHits(h.db, 'third'), ['t3']);
      });
    }

    test('a sync that deletes a track that was never indexed saves its page '
        'and leaves the index equal to a full rebuild', () async {
      h = _Harness.recorded();
      await h.init();
      addTearDown(h.db.close);
      await _writeUnindexed(h.db, [t1, t6]);
      h.recorder!.reset();

      h.serve([
        [const _Del('t6')],
      ]);
      await h.service().syncChanges();

      expect(h.recorder!.fullTrackRebuilds, 1);
      expect(await cursor(h.db), h.revision);
      expect(await titleOf(h.db, 't6'), isNull);
      await _expectMatchesRebuild(h.db, when: 'after the fallback', probes: _probes);
      expect(await _trackHits(h.db, 'solo'), isEmpty);
      expect(await _artistHits(h.db, 'nina'), isEmpty);
      expect(await _trackHits(h.db, 'blue'), ['t1']);
    });

    // Only SQLite's SQLITE_CORRUPT_VTAB (267) from a statement on a search
    // table takes the fallback; anything else fails the page as before.
    final notSearchErrors = <String, Object>{
      'a constraint error': SqliteException(
          19, 'UNIQUE constraint failed', null, 'INSERT INTO trackmetadata (uuid_id) VALUES (?)'),
      'SQLITE_CORRUPT_VTAB from a statement on another table': SqliteException(
          267, 'database disk image is malformed', null, 'SELECT * FROM trackmetadata'),
      'plain SQLITE_CORRUPT from a search-table statement': SqliteException(
          11, 'database disk image is malformed', null,
          "INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) VALUES('delete', ?, ?, ?, ?)"),
      'an error that is not from SQLite': StateError('not a database error'),
    };
    for (final e in notSearchErrors.entries) {
      test('${e.key} still fails the page', () async {
        final db = _ThrowingSearchDb(e.value);
        h = _Harness(db);
        await h.init();
        addTearDown(h.db.close);
        h.serve([
          [_Up(t1)],
        ]);
        await expectLater(h.service().syncChanges(), throwsA(same(e.value)));
        expect(await cursor(h.db), 0, reason: 'the page is not saved');
        expect(await titleOf(h.db, 't1'), isNull);
      });
    }

    test('SQLITE_CORRUPT_VTAB from a search-table statement takes the '
        'fallback', () async {
      final recorder = _FtsRecorder();
      final db = _ThrowingSearchDb(SqliteException(
          267, 'database disk image is malformed', null,
          "INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) VALUES('delete', ?, ?, ?, ?)"),
          NativeDatabase.memory().interceptWith(recorder));
      h = _Harness._recorded(db, recorder);
      await h.init();
      addTearDown(h.db.close);
      recorder.reset();
      h.serve([
        [_Up(t1)],
      ]);
      await h.service().syncChanges();
      expect(recorder.fullTrackRebuilds, 1,
          reason: 'the fallback is the full rebuild, not a retry of the page');
      expect(await cursor(h.db), h.revision);
      expect(await _trackHits(h.db, 'blue'), ['t1']);
    });
  });
}

/// Writes catalog rows without their search entries, the way a test seed
/// that inserts into the tables directly does (and the state an older build
/// left when killed between a saved page and its end-of-sync rebuild).
Future<void> _writeUnindexed(AppDatabase db, List<_T> tracks) async {
  for (final t in tracks) {
    final dto = ClientTrackDto.fromJson(
      (_upsert(t, 1)['track']! as Map<String, Object?>).cast<String, dynamic>(),
    );
    final meta = dto.metadata;
    final artistName = meta.albumArtist ?? meta.artist;
    if (meta.artistId != null && artistName != null) {
      await db.into(db.artists).insert(
            ArtistsCompanion.insert(id: Value(meta.artistId!), name: artistName),
            mode: InsertMode.insertOrIgnore,
          );
    }
    if (meta.albumId != null && meta.artistId != null) {
      final named = meta.album != null && meta.album!.isNotEmpty;
      await db.into(db.albums).insert(
            AlbumsCompanion.insert(
              id: Value(meta.albumId!),
              name: Value(named ? meta.album : null),
              artistId: meta.artistId!,
              year: Value(meta.year),
              isSingleGrouping: Value(!named),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  }
}

/// The real database, except that a page's search update throws [error]
/// (once) before doing anything.
class _ThrowingSearchDb extends AppDatabase {
  _ThrowingSearchDb(this.error, [QueryExecutor? executor])
      : super(executor ?? NativeDatabase.memory());

  Object? error;

  @override
  Future<void> applySearchDeltaOfPage(
    PageSearchBefore before, {
    required bool parentsPruned,
  }) async {
    final e = error;
    if (e != null) {
      error = null;
      throw e;
    }
    return super.applySearchDeltaOfPage(before, parentsPruned: parentsPruned);
  }
}
