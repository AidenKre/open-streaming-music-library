import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';

import '../browse_harness.dart';

/// Real repository (real DB) that counts search calls and records their args.
class _CountingRepo extends BrowseRepository {
  _CountingRepo(super.db);

  final queries = <String>[];
  final downloadedOnlyArgs = <bool>[];

  @override
  Future<LibrarySearchResults> search(
    String query, {
    Set<SearchType> types = const {
      SearchType.artists,
      SearchType.albums,
      SearchType.tracks,
    },
    int limitPerType = 5,
    bool downloadedOnly = false,
  }) {
    queries.add(query);
    downloadedOnlyArgs.add(downloadedOnly);
    return super.search(
      query,
      types: types,
      limitPerType: limitPerType,
      downloadedOnly: downloadedOnly,
    );
  }
}

/// Repository whose searches complete only when the test says so, to force
/// completion orders (stale guard, dispose mid-flight).
class _GatedRepo extends BrowseRepository {
  _GatedRepo(super.db);

  final pending = <String, Completer<void>>{};

  @override
  Future<LibrarySearchResults> search(
    String query, {
    Set<SearchType> types = const {
      SearchType.artists,
      SearchType.albums,
      SearchType.tracks,
    },
    int limitPerType = 5,
    bool downloadedOnly = false,
  }) async {
    final gate = pending[query] = Completer<void>();
    await gate.future;
    return super.search(
      query,
      types: types,
      limitPerType: limitPerType,
      downloadedOnly: downloadedOnly,
    );
  }

  void release(String query) => pending[query]!.complete();
}

class _ThrowingRepo extends BrowseRepository {
  _ThrowingRepo(super.db);

  @override
  Future<LibrarySearchResults> search(
    String query, {
    Set<SearchType> types = const {
      SearchType.artists,
      SearchType.albums,
      SearchType.tracks,
    },
    int limitPerType = 5,
    bool downloadedOnly = false,
  }) async => throw StateError('db closed');
}

const _debounce = Duration(milliseconds: 20);

/// Past the debounce, plus slack for the (real) DB query to complete.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  late AppDatabase db;
  var downloadedOnly = false;

  setUp(() async {
    downloadedOnly = false;
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'd1',
        title: 'Blue Kept',
        artistId: 1,
        artist: 'Blue Downloaded',
        downloaded: true,
      ),
      SeedTrack(
        uuid: 's1',
        title: 'Blue Remote',
        artistId: 2,
        artist: 'Blue Streaming',
      ),
      SeedTrack(
        uuid: 'r1',
        title: 'Red Thing',
        artistId: 3,
        artist: 'Red Artist',
      ),
    ]);
  });

  tearDown(() async => db.close());

  LibrarySearchController make(
    BrowseRepository repo, {
    Set<SearchType> types = const {SearchType.tracks},
    int limitPerType = 100,
  }) {
    final c = LibrarySearchController(
      repository: repo,
      types: types,
      limitPerType: limitPerType,
      downloadedOnly: () => downloadedOnly,
      debounce: _debounce,
    );
    addTearDown(() {
      try {
        c.dispose();
      } on FlutterError catch (_) {
        // Already disposed by the test itself.
      }
    });
    return c;
  }

  List<String> trackUuids(LibrarySearchController c) =>
      c.results.tracks.map((t) => t.uuidId).toList();

  test('default debounce is 300ms', () {
    final c = LibrarySearchController(
      repository: BrowseRepository(db),
      types: const {SearchType.tracks},
      limitPerType: 5,
      downloadedOnly: () => false,
    );
    expect(c.debounce, const Duration(milliseconds: 300));
    c.dispose();
  });

  test('starts inactive with empty results', () {
    final c = make(BrowseRepository(db));
    expect(c.isActive, isFalse);
    expect(c.isSearching, isFalse);
    expect(c.query, '');
    expect(c.results.tracks, isEmpty);
  });

  test('debounces a burst into one trimmed search of the last value', () async {
    final repo = _CountingRepo(db);
    final c = make(repo);

    c.onQueryChanged('B');
    c.onQueryChanged('Bl');
    c.onQueryChanged('  Blue ');
    expect(repo.queries, isEmpty, reason: 'nothing before the debounce');
    await _settle();

    expect(repo.queries, ['Blue']);
    expect(c.query, 'Blue');
    expect(c.isActive, isTrue);
    expect(trackUuids(c), unorderedEquals(['d1', 's1']));
  });

  test('isSearching is true while a fetch is in flight', () async {
    final repo = _GatedRepo(db);
    final c = make(repo);

    c.onQueryChanged('Blue');
    await Future<void>.delayed(_debounce * 2);
    expect(c.isSearching, isTrue);

    repo.release('Blue');
    await _settle();
    expect(c.isSearching, isFalse);
    expect(c.results.tracks, hasLength(2));
  });

  test('notifies listeners on state changes', () async {
    final c = make(BrowseRepository(db));
    var notifications = 0;
    c.addListener(() => notifications++);

    c.onQueryChanged('Blue');
    await _settle();
    expect(notifications, greaterThanOrEqualTo(2)); // searching → results
  });

  test('a stale completion never overwrites newer results', () async {
    final repo = _GatedRepo(db);
    final c = make(repo);

    c.onQueryChanged('Blue');
    await Future<void>.delayed(_debounce * 2); // "Blue" in flight
    c.onQueryChanged('Red');
    await Future<void>.delayed(_debounce * 2); // "Red" in flight

    repo.release('Red');
    await _settle();
    expect(trackUuids(c), ['r1']);

    repo.release('Blue'); // older request lands last
    await _settle();
    expect(trackUuids(c), ['r1']);
    expect(c.query, 'Red');
  });

  test('clear() is immediate, cancels the debounce and drops in-flight '
      'results', () async {
    final repo = _GatedRepo(db);
    final c = make(repo);

    c.onQueryChanged('Blue');
    await Future<void>.delayed(_debounce * 2); // in flight
    c.onQueryChanged('Bluer'); // pending debounce
    c.clear();

    expect(c.isActive, isFalse, reason: 'no debounce wait');
    expect(c.isSearching, isFalse);
    expect(c.results.tracks, isEmpty);

    repo.release('Blue');
    await _settle();
    expect(c.results.tracks, isEmpty);
    expect(repo.pending.keys, ['Blue'], reason: '"Bluer" never fired');
  });

  test(
    'clearing via an empty or whitespace query returns to inactive',
    () async {
      final c = make(BrowseRepository(db));
      c.onQueryChanged('Blue');
      await _settle();
      expect(c.isActive, isTrue);

      c.onQueryChanged('   ');
      await _settle();
      expect(c.isActive, isFalse);
      expect(c.results.tracks, isEmpty);
    },
  );

  test('committing the current query again does not re-fetch', () async {
    final repo = _CountingRepo(db);
    final c = make(repo);
    c.onQueryChanged('Blue');
    await _settle();
    c.onQueryChanged('Blue ');
    await _settle();
    expect(repo.queries, ['Blue']);
  });

  test('rerun() re-fetches now with the current downloadedOnly', () async {
    final repo = _CountingRepo(db);
    final c = make(repo);
    c.onQueryChanged('Blue');
    await _settle();
    expect(trackUuids(c), unorderedEquals(['d1', 's1']));

    downloadedOnly = true;
    await c.rerun();
    expect(repo.downloadedOnlyArgs, [false, true]);
    expect(trackUuids(c), ['d1']);
  });

  test('rerun() while inactive does not search', () async {
    final repo = _CountingRepo(db);
    final c = make(repo);
    await c.rerun();
    expect(repo.queries, isEmpty);
  });

  group('onDownloadStatusChanged', () {
    test(
      'download-filtered: re-runs so a deleted download drops out',
      () async {
        downloadedOnly = true;
        final repo = _CountingRepo(db);
        final c = make(repo);
        c.onQueryChanged('Blue');
        await _settle();
        expect(trackUuids(c), ['d1']);

        await db.update(db.tracks).write(clearedDownloadColumns);
        await c.onDownloadStatusChanged();
        expect(repo.queries, ['Blue', 'Blue']);
        expect(c.results.tracks, isEmpty);
      },
    );

    test('unfiltered: patches rows in place without re-searching', () async {
      final repo = _CountingRepo(db);
      final c = make(repo);
      c.onQueryChanged('Blue');
      await _settle();
      final s1 = c.results.tracks.firstWhere((t) => t.uuidId == 's1');
      expect(s1.isDownloaded, isFalse);

      await markDownloaded(db, 's1');
      await c.onDownloadStatusChanged();
      expect(repo.queries, ['Blue'], reason: 'patched, not re-searched');
      expect(
        c.results.tracks.firstWhere((t) => t.uuidId == 's1').isDownloaded,
        isTrue,
      );
    });

    test('inactive: does nothing', () async {
      final repo = _CountingRepo(db);
      final c = make(repo);
      await c.onDownloadStatusChanged();
      expect(repo.queries, isEmpty);
    });
  });

  group('isCapped', () {
    test('true when a requested type returns exactly limitPerType', () async {
      final c = make(BrowseRepository(db), limitPerType: 2);
      c.onQueryChanged('Blue');
      await _settle();
      expect(c.results.tracks, hasLength(2));
      expect(c.isCapped, isTrue);
    });

    test('false below the cap', () async {
      final c = make(BrowseRepository(db), limitPerType: 3);
      c.onQueryChanged('Blue');
      await _settle();
      expect(c.isCapped, isFalse);
    });
  });

  group('dispose', () {
    test('a pending debounce never fires', () async {
      final repo = _CountingRepo(db);
      final c = make(repo);
      c.onQueryChanged('Blue');
      c.dispose();
      await _settle();
      expect(repo.queries, isEmpty);
    });

    test('an in-flight completion is dropped without notifying', () async {
      final repo = _GatedRepo(db);
      final c = make(repo);
      var notifiedAfterDispose = false;
      c.onQueryChanged('Blue');
      await Future<void>.delayed(_debounce * 2);
      c.addListener(() => notifiedAfterDispose = true);
      c.dispose();

      repo.release('Blue');
      await _settle(); // would throw "used after dispose" if it notified
      expect(notifiedAfterDispose, isFalse);
    });

    test('a download-status patch landing after dispose is dropped', () async {
      final c = make(BrowseRepository(db));
      c.onQueryChanged('Blue');
      await _settle();
      final pending = c.onDownloadStatusChanged();
      c.dispose();
      await pending; // must not throw
    });
  });

  test('a failed search ends the in-flight state with empty results', () async {
    final c = make(_ThrowingRepo(db));
    c.onQueryChanged('Blue');
    await _settle();
    expect(c.isSearching, isFalse);
    expect(c.results.tracks, isEmpty);
    expect(c.isActive, isTrue);
  });
}
