// Phase 9B.1 (spec §2, §5 items 1–2; review §3 suggestion fixture, 9-U05):
// the suggestion pools against the independent fixture. Every expected value
// comes from suggestions.json (make_suggestions.py, written from the spec's
// rules), never from the repository's SQL.
import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/suggestions.dart';
import 'package:frontend/repositories/suggestion_pools_repository.dart';

import 'suggestion_fixture.dart';

const _day = 86400000;

void main() {
  final fixture = SuggestionFixture.load();
  late AppDatabase db;
  late SuggestionPoolsRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await fixture.seed(db);
    repo = SuggestionPoolsRepository(db);
  });

  tearDown(() => db.close());

  Map<String, (int, int, int, bool)> rediscoverOf(SuggestionPools p) => {
    for (final r in p.rediscover)
      r.track.uuid: (
        r.listeningMicros,
        r.qualifiedPlays,
        r.lastQualifiedAtUtcMs,
        r.track.isDownloaded,
      ),
  };

  group('Rediscover pool', () {
    test('equals the fixture: at least two qualified plays, the last at '
        'least 14 days ago, resolvable, within the boundary', () async {
      final p = await repo.load(fixture.boundary, fixture.capturedNowMs);
      expect(p.boundaryLocalId, fixture.boundary);
      expect(p.capturedNowUtcMs, fixture.capturedNowMs);
      expect(rediscoverOf(p), fixture.rediscover);
      // More than 20 candidates, and the hand-picked boundaries.
      expect(p.rediscover.length, greaterThan(20));
      expect(rediscoverOf(p).keys, containsAll(['rd-at14', 'rd-unk',
          'rd-future']));
      expect(rediscoverOf(p).keys, isNot(anyOf(contains('rd-in14'),
          contains('rd-one'), contains('rd-unk-short'), contains('rd-click'),
          contains('t-gone'), contains('t-nometa'))));
    });

    test('candidates carry the current catalog artist and title', () async {
      final p = await repo.load(fixture.boundary, fixture.capturedNowMs);
      for (final r in p.rediscover) {
        final (artistId, title) = fixture.catalogTrack(r.track.uuid);
        expect((r.track.artistId, r.track.title), (artistId, title),
            reason: r.track.uuid);
      }
    });

    test('exactly 14 days is in; one ms later it is not', () async {
      // rd-at14's last qualified play starts at now - 14 days exactly.
      final now = fixture.capturedNowMs;
      final at = await repo.load(fixture.boundary, now);
      expect(rediscoverOf(at).keys, contains('rd-at14'));
      final earlier = await repo.load(fixture.boundary, now - 1);
      expect(rediscoverOf(earlier).keys, isNot(contains('rd-at14')));
      // rd-in14 (1 ms short at now) gets in 1 ms later.
      final later = await repo.load(fixture.boundary, now + 1);
      expect(rediscoverOf(later).keys, contains('rd-in14'));
    });

    test('a listen that starts in the future does not count until its time',
        () async {
      // rd-future: two qualified plays at -40 d and -39 d, one at +1 d. At
      // +1 d + 1 ms the third counts: its seconds join and it is the last
      // qualified play (so the track is now too recent).
      final now = fixture.capturedNowMs;
      final p = await repo.load(fixture.boundary, now);
      expect(fixture.rediscover['rd-future'], isNotNull);
      expect(rediscoverOf(p)['rd-future'], (120000000, 2, now - 39 * _day,
          false));
      final later = await repo.load(fixture.boundary, now + _day + 1);
      expect(rediscoverOf(later).keys, isNot(contains('rd-future')));
    });

    test('nothing at all before the first event', () async {
      final p = await repo.load(0, fixture.capturedNowMs);
      expect(p.rediscover, isEmpty);
      expect(p.artists, isEmpty);
    });
  });

  Map<int, (int, int, Map<String, (String?, bool)>)> artistsOf(
    SuggestionPools p,
  ) => {
    for (final a in p.artists)
      a.artistId: (
        a.recentMicros,
        a.recentQualifiedPlays,
        {for (final c in a.candidates) c.uuid: (c.title, c.isDownloaded)},
      ),
  };

  /// Records compare a nested map by identity: flatten the candidates to a
  /// sorted string so pools compare by value.
  Map<int, (int, int, String)> comparable(
    Map<int, (int, int, Map<String, (String?, bool)>)> pools,
  ) => {
    for (final MapEntry(:key, :value) in pools.entries)
      key: (
        value.$1,
        value.$2,
        ([
          for (final MapEntry(key: u, value: c) in value.$3.entries)
            '$u|${c.$1}|${c.$2}',
        ]..sort()).join(', '),
      ),
  };

  group('artist pools', () {
    test('equal the fixture: recent artists with a qualified play in the '
        'last 30 days, their seconds there, and their tracks with zero '
        'qualified plays', () async {
      final p = await repo.load(fixture.boundary, fixture.capturedNowMs);
      expect(comparable(artistsOf(p)), comparable(fixture.artists));
      // More than ten recent artists.
      expect(p.artists.length, greaterThan(10));
      for (final a in p.artists) {
        for (final c in a.candidates) {
          expect(c.artistId, a.artistId, reason: c.uuid);
        }
      }
    });

    test('exactly 30 days is in; one ms earlier it is not', () async {
      final now = fixture.capturedNowMs;
      // p11's only qualified play starts at now - 30 days exactly; p12's at
      // now - 30 days - 1 ms.
      final at = artistsOf(await repo.load(fixture.boundary, now));
      expect(at.keys, contains(11));
      expect(at.keys, isNot(contains(12)));
      final later = artistsOf(await repo.load(fixture.boundary, now + 1));
      expect(later.keys, isNot(contains(11)));
      final earlier = artistsOf(await repo.load(fixture.boundary, now - 1));
      expect(earlier.keys, containsAll([11, 12]));
    });

    test('only short listens in the window do not make a recent artist',
        () async {
      final p = artistsOf(
        await repo.load(fixture.boundary, fixture.capturedNowMs),
      );
      expect(p.keys, isNot(contains(13)));
    });

    test('a track listened to briefly is still unplayed; one qualified play '
        'long ago is not', () async {
      final p = artistsOf(
        await repo.load(fixture.boundary, fixture.capturedNowMs),
      );
      expect(p[3]!.$3.keys, contains('u03-b'));
      expect(p[4]!.$3.keys, isNot(contains('u04-a')));
    });

    test('an artist that cannot be resolved is never a group', () async {
      final p = artistsOf(
        await repo.load(fixture.boundary, fixture.capturedNowMs),
      );
      expect(p.keys, isNot(contains(99)));
      final all = [for (final a in p.values) ...a.$3.keys];
      expect(all, isNot(anyOf(contains('u-orph'), contains('u-none'))));
    });

    test('a qualified play beyond the boundary is not in the snapshot',
        () async {
      final now = fixture.capturedNowMs;
      final at = artistsOf(await repo.load(fixture.boundary, now));
      expect(at[1]!.$3.keys, contains('u01-c'));
      final all = artistsOf(await repo.load(fixture.events.length, now));
      expect(all[1]!.$3.keys, isNot(contains('u01-c')));
    });

    test('a tombstoned track drops out of the candidates', () async {
      // Catalog sync applies a tombstone by deleting the track's rows.
      await db.customStatement(
        "DELETE FROM trackmetadata WHERE uuid_id = 'u02-a'",
      );
      await db.customStatement("DELETE FROM tracks WHERE uuid_id = 'u02-a'");
      final p = artistsOf(
        await repo.load(fixture.boundary, fixture.capturedNowMs),
      );
      expect(p[2]!.$3.keys.toSet(), {'u02-b', 'u02-c'});
    });
  });

  group('selection over the fixture pools', () {
    for (final c in fixture.cases) {
      test(c.name, () async {
        final p = await repo.load(fixture.boundary, fixture.capturedNowMs);
        final s = selectSuggestions(
          p,
          currentUuid: c.currentUuid,
          filter: BrowseFilters(
            downloaded: c.downloaded,
            policy: OfflineFilterPolicy.manual,
          ),
        );
        expect([for (final t in s.rediscover) t.uuid], c.rediscover);
        expect([for (final t in s.moreFromArtists) t.uuid], c.moreFromArtists);
        if (c.currentUuid case final current?) {
          expect([...s.rediscover, ...s.moreFromArtists].map((t) => t.uuid),
              isNot(contains(current)));
        }
      });
    }

    test('the fixture holds the review §3 situations', () {
      final all = fixture.cases.first;
      final dl = fixture.cases.firstWhere((c) => c.name == 'Downloaded only');
      expect(fixture.rediscover.length, greaterThan(20));
      expect(all.rediscover.length, 20);
      // Downloaded matches ranked outside the unfiltered 20.
      expect(dl.rediscover.where((u) => !all.rediscover.contains(u)),
          isNotEmpty);
      // More than ten recent artists with candidates; ten taken.
      expect(fixture.artists.values.where((a) => a.$3.isNotEmpty).length,
          greaterThan(10));
      expect(all.moreFromArtists.length, 20);
    });
  });

  group('one snapshot', () {
    late AppDatabase gated;
    late _GatedSelects gate;
    late SuggestionPoolsRepository gatedRepo;

    setUp(() async {
      gate = _GatedSelects();
      gated = AppDatabase(NativeDatabase.memory().interceptWith(gate));
      await fixture.seed(gated);
      gatedRepo = SuggestionPoolsRepository(gated);
    });

    tearDown(() => gated.close());

    for (var at = 2; at <= 3; at++) {
      test('writers during load cannot change the pools (paused at SELECT '
          '$at)', () async {
        gate.armAt(gate.selects + at);
        final loading = gatedRepo.load(fixture.boundary, fixture.capturedNowMs);
        await Future.any([gate.reached.future, loading]);
        final writing = () async {
          // A tombstone of a Rediscover track and of a candidate, and a
          // qualified listen of a candidate, all inside the boundary's
          // reach (local ids are below none of them: the boundary is fixed,
          // so only the catalog writes could leak).
          for (final uuid in ['rd01', 'u02-a']) {
            await gated.customUpdate(
              "DELETE FROM trackmetadata WHERE uuid_id = '$uuid'",
              updates: {gated.trackmetadata},
              updateKind: UpdateKind.delete,
            );
          }
          await gated.customUpdate(
            "UPDATE tracks SET file_path = NULL WHERE uuid_id = 'rd03'",
            updates: {gated.tracks},
            updateKind: UpdateKind.update,
          );
        }();
        gate.release();
        final p = await loading;
        await writing;
        expect(rediscoverOf(p), fixture.rediscover);
        expect(comparable(artistsOf(p)), comparable(fixture.artists));
      });
    }
  });
}

/// Pauses the [armAt]-th SELECT reaching SQLite until [release] (the 9A.1a
/// listening-stats test's gate).
class _GatedSelects extends QueryInterceptor {
  int selects = 0;
  int? _at;
  final reached = Completer<void>();
  final _release = Completer<void>();

  void armAt(int n) => _at = n;
  void release() => _release.complete();

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    selects++;
    if (selects == _at) {
      reached.complete();
      await _release.future;
    }
    return super.runSelect(executor, statement, args);
  }
}
