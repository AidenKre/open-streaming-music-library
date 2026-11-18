// Phase 9 spec §3 "Metadata/download status may update cards in place;
// deleted cards become unavailable and prompt refresh" (9A.2b): the
// statistics screens re-resolve the entities they show through the SC-12
// resolvers whenever the catalog changes. A shown id that no longer
// resolves is absent (unavailable); same-title tracks stay distinct by
// uuid (9-U03). Real in-memory Drift; ids and names are the test's own.
import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

import 'catalog_seed.dart';

void main() {
  late AppDatabase db;
  late ListeningStatsRepository stats;
  late CatalogSeed seed;
  late _ReadControl reads;

  setUp(() async {
    reads = _ReadControl();
    db = AppDatabase(NativeDatabase.memory().interceptWith(reads));
    stats = ListeningStatsRepository(db, BrowseRepository(db));
    seed = CatalogSeed(db);
    await seed.artist(1, 'Ann');
    await seed.artist(2, 'Bea');
    await seed.album(10, artistId: 1, name: 'One');
    await seed.album(20, artistId: 2, name: 'Two');
    // Two tracks with the same title by different artists.
    await seed.track('t-a', artistId: 1, albumId: 10, title: 'Same');
    await seed.track('t-b', artistId: 2, albumId: 20, title: 'Same');
    await seed.track('t-c', artistId: 1, albumId: 10, title: 'Other',
        trackNumber: 2);
  });

  tearDown(() => db.close());

  /// Listens to [stream]; `next` waits for the following emission.
  _Emissions watch(Stream<CurrentStatsEntities> stream) {
    final e = _Emissions(stream);
    addTearDown(e.cancel);
    return e;
  }

  Map<String, String?> titles(CurrentStatsEntities c) => {
    for (final e in c.tracks.entries) e.key: e.value.title,
  };

  test('the first emission resolves every shown id; an unknown id is absent',
      () async {
    final q = watch(stats.watchCurrent(
      trackUuids: const ['t-a', 't-b', 'gone'],
      artistIds: const [1, 2, 99],
      albumIds: const [10, 20, 98],
    ));
    final first = await q.next;
    expect(titles(first), {'t-a': 'Same', 't-b': 'Same'});
    expect(first.tracks['t-a']!.artistId, 1);
    expect(first.tracks['t-b']!.artistId, 2);
    expect({for (final e in first.artists.entries) e.key: e.value.name},
        {1: 'Ann', 2: 'Bea'});
    expect({for (final e in first.albums.entries) e.key: e.value.name},
        {10: 'One', 20: 'Two'});
  });

  test('a deleted track drops out of the next emission; the others stay',
      () async {
    final q = watch(stats.watchCurrent(trackUuids: const ['t-a', 't-b']));
    expect(titles(await q.next).keys, {'t-a', 't-b'});
    await db.customUpdate(
      "DELETE FROM trackmetadata WHERE uuid_id = 't-a'",
      updates: {db.trackmetadata},
      updateKind: UpdateKind.delete,
    );
    expect(titles(await q.next), {'t-b': 'Same'});
  });

  Future<void> rename(String uuid, String title) =>
      (db.update(db.trackmetadata)..where((t) => t.uuidId.equals(uuid)))
          .write(TrackmetadataCompanion(title: Value(title)));

  // DR-332-STATS-B-02: the read pump. A watch cancelled while its read runs
  // emits nothing more (no value, no error); a read that fails reaches the
  // stream as an error and the next catalog change reads again. (Coalescing
  // of changes during a read is not pinned here: a writer cannot commit
  // while the read's transaction is open, so its timing cannot be forced
  // deterministically from a test.)
  test('cancelled during a read: nothing more is emitted', () async {
    final events = <Object>[];
    final first = Completer<void>();
    final sub = stats.watchCurrent(trackUuids: const ['t-a']).listen(
      (v) {
        events.add(v);
        if (!first.isCompleted) first.complete();
      },
      onError: events.add,
    );
    await first.future;
    reads.pauseNext();
    await rename('t-a', 'New');
    await reads.reached.future;
    await sub.cancel();
    reads.release();
    await pumpEventQueue();
    expect(events, hasLength(1));
  });

  test('a failed read reaches the stream; the next change reads again',
      () async {
    final q = watch(stats.watchCurrent(trackUuids: const ['t-a']));
    await q.next;
    reads.failNext();
    await rename('t-a', 'First');
    await expectLater(q.next, throwsA(isA<StateError>()));
    await rename('t-a', 'Second');
    expect(titles(await q.next), {'t-a': 'Second'});
  });

  test('a rename updates the shown track in place', () async {
    final q = watch(stats.watchCurrent(trackUuids: const ['t-a', 't-b']));
    await q.next;
    await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('t-b')))
        .write(const TrackmetadataCompanion(title: Value('Renamed')));
    expect(titles(await q.next), {'t-a': 'Same', 't-b': 'Renamed'});
  });

  test('a removed album row makes that album unavailable; its artist stays',
      () async {
    final q = watch(stats.watchCurrent(
      artistIds: const [2],
      albumIds: const [10, 20],
    ));
    expect((await q.next).albums.keys, {10, 20});
    await db.customUpdate(
      'DELETE FROM albums WHERE id = 20',
      updates: {db.albums},
      updateKind: UpdateKind.delete,
    );
    final next = await q.next;
    expect(next.albums.keys, {10});
    expect(next.artists.keys, {2});
  });

  test('a history insert does not re-resolve (catalog tables only)', () async {
    final emissions = <CurrentStatsEntities>[];
    final sub = stats
        .watchCurrent(trackUuids: const ['t-a'])
        .listen(emissions.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(emissions, hasLength(1));
    await db.into(db.historyEvents).insert(
      HistoryEventsCompanion.insert(
        eventUuid: 'p-1',
        kind: 'play',
        entityType: 'track',
        entityRef: 't-a',
        occurredAt: 1,
        secondsPlayed: const Value(60),
        pendingUpload: false,
      ),
    );
    await pumpEventQueue();
    expect(emissions, hasLength(1));
  });

  test('currentOf: the shown entity as it resolves now, or null when it no '
      'longer resolves (the unavailable rule)', () async {
    final now = CurrentStatsEntities(
      tracks: {'t-a': _track('t-a', 'Renamed')},
      artists: {1: const ArtistUI(id: 1, name: 'Ann')},
      albums: {10: const AlbumUI(id: 10, artistId: 1, name: 'One')},
    );
    expect((now.currentOf(_track('t-a', 'Same'))! as TrackUI).title,
        'Renamed');
    expect(now.currentOf(_track('t-b', 'Same')), isNull,
        reason: 'same title, another uuid: not the shown track');
    expect((now.currentOf(const ArtistUI(id: 1, name: 'Old'))! as ArtistUI)
        .name, 'Ann');
    expect(now.currentOf(const ArtistUI(id: 10, name: 'x')), isNull,
        reason: 'artist 10 is not album 10');
    expect(now.currentOf(const AlbumUI(id: 10, artistId: 1)), isA<AlbumUI>());
    expect(now.currentOf(const AlbumUI(id: 1, artistId: 1)), isNull);
  });

  test('nothing shown: one empty emission', () async {
    final first = await stats.watchCurrent().first;
    expect(first.tracks, isEmpty);
    expect(first.artists, isEmpty);
    expect(first.albums, isEmpty);
  });
}

/// The emissions of a watch, read one at a time (no package:async here).
/// Pauses or fails the next SELECT reaching SQLite.
class _ReadControl extends QueryInterceptor {
  var _pause = false;
  var _fail = false;
  var reached = Completer<void>();
  var _release = Completer<void>();

  void pauseNext() {
    _pause = true;
    reached = Completer<void>();
    _release = Completer<void>();
  }

  void release() => _release.complete();
  void failNext() => _fail = true;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (_fail) {
      _fail = false;
      throw StateError('read failed');
    }
    if (_pause) {
      _pause = false;
      reached.complete();
      await _release.future;
    }
    return super.runSelect(executor, statement, args);
  }
}

class _Emissions {
  _Emissions(Stream<CurrentStatsEntities> stream) {
    _sub = stream.listen((value) {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(value);
      } else {
        _buffer.add(value);
      }
    }, onError: (Object e) {
      if (_waiting.isNotEmpty) _waiting.removeAt(0).completeError(e);
    });
  }

  late final StreamSubscription<CurrentStatsEntities> _sub;
  final _buffer = <CurrentStatsEntities>[];
  final _waiting = <Completer<CurrentStatsEntities>>[];

  Future<CurrentStatsEntities> get next {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<CurrentStatsEntities>();
    _waiting.add(c);
    return c.future.timeout(const Duration(seconds: 5),
        onTimeout: () => fail('no further emission'));
  }

  Future<void> cancel() => _sub.cancel();
}

TrackUI _track(String uuid, String title) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: title,
  artist: 'Ann',
  artistId: 1,
  albumId: 10,
  duration: 180,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);
