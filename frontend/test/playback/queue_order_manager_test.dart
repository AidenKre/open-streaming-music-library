import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/playback/queue_order_manager.dart';
import 'package:frontend/repositories/queue_repository.dart';
import '../helpers/server_binding.dart';

void main() {
  test('shuffleItems produces a permutation of the input', () {
    final input = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    final result = QueueOrderManager.shuffleItems(input);

    expect(result.toSet(), input.toSet());
    expect(result, hasLength(input.length));
  });

  test('shuffleItems with seeded Random is deterministic', () {
    final input = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    final result1 = QueueOrderManager.shuffleItems(input, Random(42));
    final result2 = QueueOrderManager.shuffleItems(input, Random(42));

    expect(result1, result2);
  });

  test('shuffleItems does not modify original list', () {
    final input = [1, 2, 3];
    final copy = List<int>.from(input);
    QueueOrderManager.shuffleItems(input);
    expect(input, copy);
  });

  group('rebuildEffectiveOrder', () {
    late AppDatabase db;
    late QueueRepository repo;
    late QueueOrderManager orderManager;
    late _LibraryFixture fixture;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
      repo = QueueRepository(db);
      orderManager = QueueOrderManager(repo);
      fixture = _LibraryFixture(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('with shuffle off preserves canonical order', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'c', 'd', 'e'],
        currentIndex: 2,
      );
      final snapshot = await repo.getSessionSnapshot(sessionId);
      final currentItemId = snapshot!.currentItem!.itemId;

      await orderManager.rebuildEffectiveOrder(
        sessionId,
        currentItemId: currentItemId,
        preserveShuffledMainFuture: false,
        isShuffleOn: false,
      );

      final entries = await repo.getSessionTracksInPlayOrder(sessionId);
      expect(
        entries.map((entry) => entry.uuidId),
        ['a', 'b', 'c', 'd', 'e'],
      );
    });

    test('with shuffle on randomizes future items', () async {
      await fixture.insertSingles(
        List.generate(20, (i) => 'track-${i + 1}'),
      );

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: List.generate(20, (i) => 'track-${i + 1}'),
        currentIndex: 0,
      );
      final snapshot = await repo.getSessionSnapshot(sessionId);
      final currentItemId = snapshot!.currentItem!.itemId;

      await orderManager.rebuildEffectiveOrder(
        sessionId,
        currentItemId: currentItemId,
        preserveShuffledMainFuture: false,
        shuffleMainFuture: true,
        isShuffleOn: false,
      );

      final entries = await repo.getSessionTracksInPlayOrder(sessionId);
      expect(entries.first.uuidId, 'track-1');
      expect(entries.map((e) => e.uuidId).toSet(), hasLength(20));
    });
  });

  group('6A.1b initializeShuffled (spec §5 Shuffle, SC-27)', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());
    QueueOrderManager managerWith(Random random) =>
        QueueOrderManager(QueueRepository(db), random);

    test('the first draw picks the first item: forced to the last canonical '
        'index', () {
      final canonical = List.generate(9, (i) => i);
      final random = _FirstPickRandom((max) => max - 1, Random(5));
      final order = managerWith(random).initializeShuffled(canonical);

      expect(order.first, 8, reason: 'the last canonical item starts');
      expect(random.firstMax, 9, reason: 'chosen uniformly from all members');
      expect(order, hasLength(9));
      expect(order.toSet(), canonical.toSet(), reason: 'nothing missing');
    });

    test('the permutation is complete: duplicates kept, nothing added', () {
      const canonical = ['x', 'y', 'x', 'z', 'y', 'x'];
      for (var seed = 0; seed < 20; seed++) {
        final order = managerWith(Random(seed)).initializeShuffled(canonical);
        expect(order, hasLength(canonical.length));
        expect([...order]..sort(), [...canonical]..sort(), reason: 'seed $seed');
      }
    });

    test('every member is equally likely to start (seeded)', () {
      final manager = managerWith(Random(2026));
      final counts = List.filled(6, 0);
      for (var i = 0; i < 6000; i++) {
        counts[manager.initializeShuffled(const [0, 1, 2, 3, 4, 5]).first]++;
      }
      for (final count in counts) {
        expect(count, inInclusiveRange(850, 1150), reason: '$counts');
      }
    });

    test('the rest is shuffled too, not left in canonical order', () {
      final canonical = List.generate(12, (i) => i);
      final random = _FirstPickRandom((max) => 0, Random(9));
      final order = managerWith(random).initializeShuffled(canonical);
      expect(order.first, 0);
      expect(order.skip(1), isNot(orderedEquals(canonical.skip(1))));
      expect(order.toSet(), canonical.toSet());
    });

    test('the input is left untouched; zero and one item', () {
      final canonical = [3, 1, 2];
      final copy = List.of(canonical);
      managerWith(Random(1)).initializeShuffled(canonical);
      expect(canonical, copy);
      expect(managerWith(Random(1)).initializeShuffled(const <int>[]), isEmpty);
      expect(managerWith(Random(1)).initializeShuffled(const [7]), [7]);
    });
  });

  group('6A.1b played-prefix rule (O1/DEV-6-01, spec §5)', () {
    late AppDatabase db;
    late QueueRepository repo;
    late _LibraryFixture fixture;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await seedTestBinding(db);
      repo = QueueRepository(db);
      fixture = _LibraryFixture(db);
    });
    tearDown(() => db.close());

    /// A session over [uuids] whose play order is [order] (uuids; a uuid
    /// listed twice in [uuids] is addressed as `uuid#canonicalPosition`),
    /// current at [current]. Returns the session and an id lookup.
    Future<(int, Map<String, int>)> sessionWith(List<String> uuids,
        {required List<String> order,
        required String current,
        List<String> manual = const []}) async {
      final sessionId = await repo.createSessionFromExplicitList(
          sourceType: 'album', trackUuids: uuids);
      if (manual.isNotEmpty) await repo.appendManualItems(sessionId, manual);
      final ids = <String, int>{};
      final entries = await repo.getSessionTracksInPlayOrder(sessionId);
      final counts = <String, int>{};
      for (final u in uuids) {
        counts[u] = (counts[u] ?? 0) + 1;
      }
      for (final e in entries) {
        final key = counts[e.uuidId] == 1 || e.queueType != 'main'
            ? e.uuidId
            : '${e.uuidId}#${e.canonicalPosition}';
        ids[key] = e.itemId;
      }
      await repo.replacePlayOrder(sessionId, [for (final k in order) ids[k]!]);
      await repo.updateShuffleEnabled(sessionId, true);
      await repo.updatePlaybackCursor(
          sessionId: sessionId, currentItemId: ids[current]!, positionMs: 0);
      return (sessionId, ids);
    }

    Future<List<String>> orderOf(int sessionId, Map<String, int> ids) async {
      final byId = {for (final e in ids.entries) e.value: e.key};
      return [
        for (final id in await repo.getPlayOrderItemIds(sessionId)) byId[id]!
      ];
    }

    Future<void> toggle(int sessionId, Map<String, int> ids, String current,
            {required bool on, Random? random}) =>
        QueueOrderManager(repo, random ?? Random(0)).rebuildEffectiveOrder(
          sessionId,
          currentItemId: ids[current]!,
          preserveShuffledMainFuture: false,
          shuffleMainFuture: on,
          isShuffleOn: !on,
        );

    test('off keeps the played prefix and puts every unplayed main item in '
        'canonical order', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'f']);
      final (s, ids) = await sessionWith(['a', 'b', 'c', 'd', 'e', 'f'],
          order: ['c', 'a', 'e', 'b', 'f', 'd'], current: 'e');
      await toggle(s, ids, 'e', on: false);
      expect(await orderOf(s, ids), ['c', 'a', 'e', 'b', 'd', 'f']);
    });

    test('on reshuffles only the unplayed rest, the prefix stays', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'f', 'g']);
      for (var seed = 0; seed < 8; seed++) {
        final (s, ids) = await sessionWith(
            ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
            order: ['d', 'a', 'f', 'b', 'c', 'e', 'g'],
            current: 'f');
        await toggle(s, ids, 'f', on: true, random: Random(seed));
        final order = await orderOf(s, ids);
        expect(order.take(3), ['d', 'a', 'f'], reason: 'seed $seed');
        expect(order.skip(3).toSet(), {'b', 'c', 'e', 'g'},
            reason: 'seed $seed: only the unplayed members, each once');
        expect(order, hasLength(7));
      }
    });

    test('a pending manual item stays next; a played one stays in the '
        'prefix', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'x', 'y']);
      final (s, ids) = await sessionWith(['a', 'b', 'c', 'd', 'e'],
          manual: ['x', 'y'],
          order: ['d', 'x', 'b', 'y', 'e', 'a', 'c'],
          current: 'b');
      await toggle(s, ids, 'b', on: false);
      expect(await orderOf(s, ids), ['d', 'x', 'b', 'y', 'a', 'c', 'e']);
    });

    test('a manual current item keeps its place', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'x']);
      final (s, ids) = await sessionWith(['a', 'b', 'c', 'd', 'e'],
          manual: ['x'],
          order: ['d', 'x', 'e', 'a', 'c', 'b'],
          current: 'x');
      await toggle(s, ids, 'x', on: false);
      expect(await orderOf(s, ids), ['d', 'x', 'a', 'b', 'c', 'e']);
    });

    test('duplicate tracks are separate members of the rule', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final (s, ids) = await sessionWith(['a', 'b', 'a', 'c'],
          order: ['a#2', 'c', 'a#0', 'b'], current: 'c');
      await toggle(s, ids, 'c', on: false);
      expect(await orderOf(s, ids), ['a#2', 'c', 'a#0', 'b']);
    });

    // Sign-off DEV-6-01 (owner, 2026-11-17): turning shuffle off puts the
    // whole queue back in its original order, behind and ahead of the
    // current track; each queued item stays right after the track it
    // followed (coordinator Q1).
    group('restoreCanonicalOrder (DEV-6-01, shuffle off)', () {
      Future<bool> restart(int sessionId) =>
          QueueOrderManager(repo, Random(0)).restoreCanonicalOrder(sessionId);

      test('the guide example: heard a then c, now on c: a b c d e',
          () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        final (s, ids) = await sessionWith(['a', 'b', 'c', 'd', 'e'],
            order: ['a', 'c', 'e', 'b', 'd'], current: 'c');
        expect(await restart(s), isTrue);
        expect(await orderOf(s, ids), ['a', 'b', 'c', 'd', 'e']);
      });

      test('a played queued item whose track lies ahead of the current one '
          'is kept, after that track (Phase 5 dropped it)', () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'x', 'y']);
        final (s, ids) = await sessionWith(['a', 'b', 'c', 'd', 'e'],
            manual: ['x', 'y'],
            order: ['d', 'x', 'b', 'y', 'e', 'a', 'c'],
            current: 'b');
        expect(await restart(s), isTrue);
        expect(await orderOf(s, ids), ['a', 'b', 'y', 'c', 'd', 'x', 'e']);
      });

      test('a queued item not yet played and not right after the current '
          'track stays after the track it followed', () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'x']);
        // x was queued at c; the listener then went back to e.
        final (s, ids) = await sessionWith(['a', 'b', 'c', 'd', 'e'],
            manual: ['x'],
            order: ['e', 'a', 'c', 'x', 'd', 'b'],
            current: 'e');
        expect(await restart(s), isTrue);
        expect(await orderOf(s, ids), ['a', 'b', 'c', 'x', 'd', 'e']);
      });

      test('a queued current item stays right after the track it followed',
          () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'x', 'y']);
        final (s, ids) = await sessionWith(['a', 'b', 'c', 'd', 'e'],
            manual: ['x', 'y'],
            order: ['d', 'b', 'x', 'y', 'e', 'a', 'c'],
            current: 'x');
        expect(await restart(s), isTrue);
        expect(await orderOf(s, ids), ['a', 'b', 'x', 'y', 'c', 'd', 'e']);
      });

      test('a shuffled prefix becomes canonical order', () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        final (s, ids) = await sessionWith(['a', 'b', 'c', 'd', 'e'],
            order: ['d', 'b', 'e', 'a', 'c'], current: 'c');
        expect(await restart(s), isTrue);
        expect(await orderOf(s, ids), ['a', 'b', 'c', 'd', 'e']);
      });

      test('a manual item stays right after the main item it followed',
          () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'x', 'y']);
        final (s, ids) = await sessionWith(['a', 'b', 'c', 'd', 'e'],
            manual: ['x', 'y'],
            order: ['y', 'd', 'x', 'b', 'e', 'a', 'c'],
            current: 'c');
        expect(await restart(s), isTrue);
        expect(await orderOf(s, ids), ['y', 'a', 'b', 'c', 'd', 'x', 'e'],
            reason: 'y came before any main item; x followed d');
      });

      test('duplicate tracks keep one entry per canonical position', () async {
        await fixture.insertSingles(['a', 'b', 'c']);
        final (s, ids) = await sessionWith(['a', 'b', 'a', 'c'],
            order: ['a#2', 'c', 'a#0', 'b'], current: 'b');
        expect(await restart(s), isTrue);
        expect(await orderOf(s, ids), ['a#0', 'b', 'a#2', 'c']);
      });

      test('an order whose main items are already canonical is left as is',
          () async {
        await fixture.insertSingles(['a', 'b', 'c', 'x']);
        final (s, ids) = await sessionWith(['a', 'b', 'c'],
            manual: ['x'], order: ['a', 'x', 'b', 'c'], current: 'c');
        final before = await repo.getPlayOrderItemIds(s);
        expect(await restart(s), isFalse);
        expect(await repo.getPlayOrderItemIds(s), before);
        expect(await orderOf(s, ids), ['a', 'x', 'b', 'c']);
      });
    });
  });
}

/// A generator whose first `nextInt` answer is scripted (the first pick of a
/// collection shuffle); every later draw comes from [_rest].
class _FirstPickRandom implements Random {
  _FirstPickRandom(this._first, this._rest);
  final int Function(int max) _first;
  final Random _rest;
  int? firstMax;

  @override
  int nextInt(int max) {
    if (firstMax == null) {
      firstMax = max;
      return _first(max);
    }
    return _rest.nextInt(max);
  }

  @override
  double nextDouble() => _rest.nextDouble();

  @override
  bool nextBool() => _rest.nextBool();
}

class _LibraryFixture {
  final AppDatabase db;
  int _nextArtistId = 1;
  int _nextAlbumId = 1;
  final Map<String, int> _artistIds = {};
  final Map<String, int> _albumIds = {};

  _LibraryFixture(this.db);

  Future<void> insertSingles(List<String> uuids) async {
    for (var i = 0; i < uuids.length; i++) {
      final artistName = 'Artist ${i + 1}';
      final artistId = await _ensureArtist(artistName);
      final albumId = await _ensureAlbum(artistId, 'Singles ${i + 1}');
      await _insertTrack(
        uuid: uuids[i],
        artist: artistName,
        artistId: artistId,
        album: 'Singles ${i + 1}',
        albumId: albumId,
        trackNumber: 1,
      );
    }
  }

  Future<int> _ensureArtist(String name) async {
    final key = name.toLowerCase();
    final existing = _artistIds[key];
    if (existing != null) return existing;

    final id = _nextArtistId++;
    await db
        .into(db.artists)
        .insert(ArtistsCompanion(id: Value(id), name: Value(name)));
    _artistIds[key] = id;
    return id;
  }

  Future<int> _ensureAlbum(int artistId, String name) async {
    final key = '$artistId:${name.toLowerCase()}';
    final existing = _albumIds[key];
    if (existing != null) return existing;

    final id = _nextAlbumId++;
    await db
        .into(db.albums)
        .insert(
          AlbumsCompanion(
            id: Value(id),
            name: Value(name),
            artistId: Value(artistId),
            year: const Value(2024),
            isSingleGrouping: const Value(false),
          ),
        );
    _albumIds[key] = id;
    return id;
  }

  Future<void> _insertTrack({
    required String uuid,
    required String artist,
    required int artistId,
    required String album,
    required int albumId,
    required int trackNumber,
  }) async {
    final dto = ClientTrackDto.fromJson({
      'uuid_id': uuid,
      'created_at': 1700000000 + trackNumber,
      'last_updated': 1700000100 + trackNumber,
      'revision': 1700000000 + trackNumber,
      'metadata': {
        'title': 'Track $uuid',
        'artist': artist,
        'album': album,
        'artist_id': artistId,
        'album_id': albumId,
        'track_number': trackNumber,
        'disc_number': 1,
        'duration': 180.0,
        'bitrate_kbps': 320.0,
        'sample_rate_hz': 44100,
        'channels': 2,
        'has_album_art': false,
      },
    });

    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  }
}
