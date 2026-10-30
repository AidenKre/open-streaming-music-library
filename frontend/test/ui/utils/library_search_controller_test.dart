import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';

import '../browse_harness.dart';

// Every test runs under `testWidgets` for its fake clock: `tester.pump(d)`
// advances the debounce timer exactly, with no wall-clock sleeps. Scheduling
// and race tests use [_ScriptedRepo], whose every call (search or download
// patch) completes only when the test completes it, with a snapshot the test
// chose. The real-FTS group at the bottom checks the controller against the
// real repository.

TrackUI _track(String uuid, {String? filePath, int revision = 1}) => TrackUI(
  uuidId: uuid,
  filePath: filePath,
  createdAt: 0,
  lastUpdated: 0,
  revision: revision,
  title: uuid,
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

LibrarySearchResults _tracks(List<TrackUI> tracks) =>
    (artists: const <ArtistUI>[], albums: const [], tracks: tracks);

class _SearchCall {
  _SearchCall(this.query, this.types, this.limitPerType, this.downloadedOnly);
  final String query;
  final Set<SearchType> types;
  final int limitPerType;
  final bool downloadedOnly;
  final _done = Completer<LibrarySearchResults>();
  void complete(List<TrackUI> tracks) => _done.complete(_tracks(tracks));
  void completeWith(LibrarySearchResults results) => _done.complete(results);
  void fail(Object error) => _done.completeError(error);
}

class _PatchCall {
  _PatchCall(this.input);
  final List<TrackUI> input;
  final _done = Completer<List<TrackUI>>();
  void complete(List<TrackUI> tracks) => _done.complete(tracks);
  void fail(Object error) => _done.completeError(error);
}

/// Each call is gated independently (two searches for the same query are two
/// gates), so tests can force any completion order.
class _ScriptedRepo extends BrowseRepository {
  _ScriptedRepo(super.db);

  final searches = <_SearchCall>[];
  final patches = <_PatchCall>[];

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
    final call = _SearchCall(query, types, limitPerType, downloadedOnly);
    searches.add(call);
    return call._done.future;
  }

  @override
  Future<List<TrackUI>> withFreshDownloadState(List<TrackUI> tracks) {
    final call = _PatchCall(tracks);
    patches.add(call);
    return call._done.future;
  }
}

const _debounce = Duration(milliseconds: 300);

void main() {
  late AppDatabase db;
  var downloadedOnly = false;

  setUp(() {
    downloadedOnly = false;
    db = AppDatabase(NativeDatabase.memory());
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

  List<String> uuids(LibrarySearchController c) =>
      c.results.tracks.map((t) => t.uuidId).toList();

  /// Commit [query] through the debounce and leave its search in flight.
  Future<void> commit(
    WidgetTester tester,
    LibrarySearchController c,
    String query,
  ) async {
    c.onQueryChanged(query);
    await tester.pump(_debounce);
  }

  testWidgets('default debounce is 300ms', (tester) async {
    final c = make(_ScriptedRepo(db));
    expect(c.debounce, _debounce);
  });

  testWidgets('starts inactive with empty results', (tester) async {
    final c = make(_ScriptedRepo(db));
    expect(c.isActive, isFalse);
    expect(c.isSearching, isFalse);
    expect(c.query, '');
    expect(c.results.tracks, isEmpty);
  });

  group('debounce', () {
    testWidgets('fires at 300ms, not at 299ms', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      c.onQueryChanged('Blue');
      await tester.pump(const Duration(milliseconds: 299));
      expect(repo.searches, isEmpty);
      expect(c.isActive, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(repo.searches.map((s) => s.query), ['Blue']);
      expect(c.isActive, isTrue);
      expect(c.isSearching, isTrue);
    });

    testWidgets('each keystroke restarts the timer; the last value is '
        'searched, trimmed', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      c.onQueryChanged('B');
      await tester.pump(const Duration(milliseconds: 200));
      c.onQueryChanged('Bl');
      await tester.pump(const Duration(milliseconds: 200));
      c.onQueryChanged('  Blue ');
      await tester.pump(const Duration(milliseconds: 299));
      expect(repo.searches, isEmpty, reason: '699ms in, but never 300 quiet');
      await tester.pump(const Duration(milliseconds: 1));
      expect(repo.searches.map((s) => s.query), ['Blue']);
      expect(c.query, 'Blue');
    });

    testWidgets('a commit equal to the current (trimmed) query does not '
        're-fetch', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches.single.complete([_track('a')]);
      await tester.pump();
      await commit(tester, c, 'Blue ');
      expect(repo.searches, hasLength(1));
    });

    testWidgets('whitespace-only input commits "" through the debounce and '
        'returns to inactive', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches.single.complete([_track('a')]);
      await tester.pump();

      c.onQueryChanged('   ');
      await tester.pump(const Duration(milliseconds: 299));
      expect(c.isActive, isTrue, reason: 'not before the debounce');
      await tester.pump(const Duration(milliseconds: 1));
      expect(c.isActive, isFalse);
      expect(c.results.tracks, isEmpty);
      expect(repo.searches, hasLength(1), reason: 'no search for ""');
    });

    testWidgets('an older fetch landing while a newer query is still '
        'debouncing shows its own results', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      c.onQueryChanged('Blues'); // pending, not committed
      repo.searches.single.complete([_track('blue')]);
      await tester.pump();
      // "Blue" is still the committed query, so its results are current.
      expect(c.query, 'Blue');
      expect(uuids(c), ['blue']);
      await tester.pump(_debounce);
      expect(repo.searches.map((s) => s.query), ['Blue', 'Blues']);
    });
  });

  group('lifecycle', () {
    testWidgets('isSearching is true only while the fetch is in flight, and '
        'listeners hear both edges', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      final seen = <(bool, int)>[];
      c.addListener(() => seen.add((c.isSearching, c.results.tracks.length)));

      await commit(tester, c, 'Blue');
      expect(c.isSearching, isTrue);
      repo.searches.single.complete([_track('a'), _track('b')]);
      await tester.pump();
      expect(c.isSearching, isFalse);
      expect(seen, [(true, 0), (false, 2)]);
    });

    testWidgets('previous results stay visible while the next query loads', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('a')]);
      await tester.pump();
      await commit(tester, c, 'Red');
      expect(c.isSearching, isTrue);
      expect(uuids(c), ['a']);
    });

    testWidgets('a failed search ends the in-flight state with empty results', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches.single.fail(StateError('db closed'));
      await tester.pump();
      expect(c.isSearching, isFalse);
      expect(c.results.tracks, isEmpty);
      expect(c.isActive, isTrue);
      expect(c.failed, isTrue, reason: 'not to be shown as "no matches"');
    });

    testWidgets('failed clears on the next search that succeeds, and on '
        'clear()', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches.last.fail(StateError('db closed'));
      await tester.pump();
      expect(c.failed, isTrue);

      await commit(tester, c, 'Red');
      repo.searches.last.complete([]);
      await tester.pump();
      expect(c.failed, isFalse, reason: 'a real empty result');

      await commit(tester, c, 'Green');
      repo.searches.last.fail(StateError('db closed'));
      await tester.pump();
      c.clear();
      expect(c.failed, isFalse);
    });
  });

  group('submit()', () {
    testWidgets('commits now and cancels the pending debounce', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      c.onQueryChanged('Blu');
      c.submit('  Blue ');
      expect(c.query, 'Blue');
      expect(repo.searches.single.query, 'Blue');
      await tester.pump(_debounce * 2);
      expect(repo.searches, hasLength(1), reason: '"Blu" never commits');
    });

    testWidgets('the query already committed does not search again', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      c.submit('Blue');
      expect(repo.searches, hasLength(1));
    });
  });

  group('clear()', () {
    testWidgets('is immediate and cancels a pending debounce', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches.single.complete([_track('a')]);
      await tester.pump();
      c.onQueryChanged('Bluer'); // pending

      c.clear();
      expect(c.isActive, isFalse, reason: 'no debounce wait');
      expect(c.isSearching, isFalse);
      expect(c.results.tracks, isEmpty);
      await tester.pump(_debounce * 2);
      expect(repo.searches, hasLength(1), reason: '"Bluer" never fired');
      expect(c.isActive, isFalse);
    });

    testWidgets('drops an in-flight search that lands afterwards', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      c.clear();
      repo.searches.single.complete([_track('a')]);
      await tester.pump();
      expect(c.isActive, isFalse);
      expect(c.isSearching, isFalse);
      expect(c.results.tracks, isEmpty);
    });

    testWidgets('before anything was committed is a silent no-op', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      var notified = 0;
      c.addListener(() => notified++);
      c.onQueryChanged('Bl'); // pending only
      c.clear();
      await tester.pump(_debounce * 2);
      expect(repo.searches, isEmpty);
      expect(notified, 0);
    });

    testWidgets('then the same query again searches afresh', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('a')]);
      await tester.pump();
      c.clear();
      await commit(tester, c, 'Blue');
      expect(repo.searches, hasLength(2));
      repo.searches[1].complete([_track('b')]);
      await tester.pump();
      expect(uuids(c), ['b']);
    });
  });

  group('stale completions (generation guard)', () {
    testWidgets('an older search landing last never overwrites newer results', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      await commit(tester, c, 'Red');

      repo.searches[1].complete([_track('red')]);
      await tester.pump();
      expect(uuids(c), ['red']);
      repo.searches[0].complete([_track('blue')]);
      await tester.pump();
      expect(uuids(c), ['red']);
      expect(c.query, 'Red');
      expect(c.isSearching, isFalse);
    });

    testWidgets('an older search landing first is dropped while the newer '
        'one loads', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      await commit(tester, c, 'Red');
      repo.searches[0].complete([_track('blue')]);
      await tester.pump();
      expect(c.results.tracks, isEmpty, reason: 'older generation dropped');
      expect(c.isSearching, isTrue, reason: '"Red" is still loading');
      repo.searches[1].complete([_track('red')]);
      await tester.pump();
      expect(uuids(c), ['red']);
    });

    testWidgets('same query, filter changed: the unfiltered run landing last '
        'is dropped', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      downloadedOnly = true;
      unawaited(c.rerun());
      expect(repo.searches.map((s) => (s.query, s.downloadedOnly)), [
        ('Blue', false),
        ('Blue', true),
      ]);

      repo.searches[1].complete([_track('dl', filePath: '/x')]);
      await tester.pump();
      repo.searches[0].complete([_track('dl', filePath: '/x'), _track('rm')]);
      await tester.pump();
      expect(uuids(c), ['dl']);
    });

    testWidgets('rerun() re-fetches now with the current downloadedOnly', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('a')]);
      await tester.pump();
      downloadedOnly = true;
      unawaited(c.rerun());
      expect(repo.searches, hasLength(2), reason: 'no debounce for rerun');
      expect(repo.searches[1].downloadedOnly, isTrue);
    });

    testWidgets('rerun() while a different query is still debouncing: both '
        'run and the newer query wins', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches.last.complete([_track('blue')]);
      await tester.pump();

      c.onQueryChanged('Red'); // not yet committed
      downloadedOnly = true;
      unawaited(c.rerun()); // e.g. the chip toggled mid-typing
      expect(repo.searches.last.query, 'Blue');
      expect(repo.searches.last.downloadedOnly, isTrue);
      await tester.pump(_debounce);
      expect(repo.searches.last.query, 'Red');

      repo.searches.last.complete([_track('red')]);
      repo.searches[1].complete([_track('blue')]); // the rerun lands last
      await tester.pump();
      expect(uuids(c), ['red']);
    });

    testWidgets('rerun() while inactive does not search', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await c.rerun();
      expect(repo.searches, isEmpty);
    });
  });

  group('onDownloadStatusChanged', () {
    testWidgets('download-filtered: re-searches instead of patching', (
      tester,
    ) async {
      downloadedOnly = true;
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('a', filePath: '/a')]);
      await tester.pump();

      unawaited(c.onDownloadStatusChanged());
      expect(repo.patches, isEmpty);
      expect(repo.searches, hasLength(2));
      repo.searches[1].complete([]);
      await tester.pump();
      expect(c.results.tracks, isEmpty);
    });

    testWidgets('unfiltered: patches the current rows in place', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('a'), _track('b')]);
      await tester.pump();

      unawaited(c.onDownloadStatusChanged());
      expect(repo.searches, hasLength(1), reason: 'patched, not re-searched');
      expect(repo.patches.single.input.map((t) => t.uuidId), ['a', 'b']);
      repo.patches.single.complete([_track('a'), _track('b', filePath: '/b')]);
      await tester.pump();
      expect(uuids(c), ['a', 'b']);
      expect(c.results.tracks[1].isDownloaded, isTrue);
    });

    testWidgets('inactive: does nothing', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await c.onDownloadStatusChanged();
      expect(repo.searches, isEmpty);
      expect(repo.patches, isEmpty);
    });

    testWidgets('a patch landing after a newer query is dropped', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('blue')]);
      await tester.pump();
      unawaited(c.onDownloadStatusChanged());
      await commit(tester, c, 'Red');
      repo.searches[1].complete([_track('red')]);
      await tester.pump();

      repo.patches.single.complete([_track('blue', filePath: '/b')]);
      await tester.pump();
      expect(uuids(c), ['red']);
    });

    testWidgets('a patch landing after clear() is dropped', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('blue')]);
      await tester.pump();
      unawaited(c.onDownloadStatusChanged());
      c.clear();
      repo.patches.single.complete([_track('blue', filePath: '/b')]);
      await tester.pump();
      expect(c.isActive, isFalse);
      expect(c.results.tracks, isEmpty);
    });

    testWidgets('a download event while a search is in flight cannot '
        'overwrite that search\'s results with the old rows', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('blue')]);
      await tester.pump();
      await commit(tester, c, 'Red'); // in flight
      unawaited(c.onDownloadStatusChanged()); // a download finished meanwhile
      expect(repo.patches, isEmpty, reason: 'nothing patches the old rows');

      repo.searches.last.complete([_track('red')]);
      await tester.pump();
      expect(c.query, 'Red');
      expect(uuids(c), ['red'], reason: '"Blue" rows must not come back');
      expect(c.isSearching, isFalse);

      // "Red" may have read the old download state, so the event is
      // handled once it lands: a patch of the *new* rows.
      expect(repo.patches.single.input.map((t) => t.uuidId), ['red']);
      repo.patches.single.complete([_track('red', filePath: '/r')]);
      await tester.pump();
      expect(c.results.tracks.single.isDownloaded, isTrue);
    });

    testWidgets('a burst of events during a search cannot starve it: the '
        'results land, then one follow-up re-search', (tester) async {
      downloadedOnly = true;
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      for (var i = 0; i < 5; i++) {
        unawaited(c.onDownloadStatusChanged());
      }
      expect(repo.searches, hasLength(1), reason: 'not restarted');

      repo.searches[0].complete([_track('a', filePath: '/a')]);
      await tester.pump();
      expect(uuids(c), ['a'], reason: 'the first search\'s results land');
      expect(repo.searches, hasLength(2), reason: 'one follow-up for five');
      expect(c.isSearching, isTrue);

      repo.searches[1].complete([]);
      await tester.pump();
      expect(c.results.tracks, isEmpty);
      expect(repo.searches, hasLength(2));
      expect(c.isSearching, isFalse);
    });

    testWidgets('an event during a search that a newer query replaces is '
        'not replayed: the newer search read the DB later', (tester) async {
      downloadedOnly = true;
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      unawaited(c.onDownloadStatusChanged());
      await commit(tester, c, 'Red');
      repo.searches[1].complete([_track('red', filePath: '/r')]);
      repo.searches[0].complete([]);
      await tester.pump();
      expect(uuids(c), ['red']);
      expect(repo.searches, hasLength(2));
    });

    testWidgets('two overlapping patches: the older read landing last does '
        'not undo the newer one', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('a', filePath: '/a')]);
      await tester.pump();

      unawaited(c.onDownloadStatusChanged()); // read while still downloaded
      unawaited(c.onDownloadStatusChanged()); // read after the delete
      expect(repo.patches, hasLength(2));
      repo.patches[1].complete([_track('a')]);
      await tester.pump();
      expect(c.results.tracks.single.isDownloaded, isFalse);
      repo.patches[0].complete([_track('a', filePath: '/a')]);
      await tester.pump();
      expect(
        c.results.tracks.single.isDownloaded,
        isFalse,
        reason: 'a deleted download must not be resurrected',
      );
    });

    testWidgets('a newer patch failing does not discard an older one that '
        'succeeded', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('a')]);
      await tester.pump();

      unawaited(c.onDownloadStatusChanged());
      unawaited(c.onDownloadStatusChanged());
      repo.patches[1].fail(StateError('db closed'));
      await tester.pump();
      repo.patches[0].complete([_track('a', filePath: '/a')]);
      await tester.pump();
      expect(c.results.tracks.single.isDownloaded, isTrue);
    });

    testWidgets('overlapping patches landing in order both apply', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('a')]);
      await tester.pump();

      unawaited(c.onDownloadStatusChanged());
      unawaited(c.onDownloadStatusChanged());
      repo.patches[0].complete([_track('a', filePath: '/a')]);
      await tester.pump();
      expect(c.results.tracks.single.isDownloaded, isTrue);
      repo.patches[1].complete([_track('a')]);
      await tester.pump();
      expect(c.results.tracks.single.isDownloaded, isFalse);
    });

    testWidgets('a failed patch keeps the rows and is not an unhandled '
        'error', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches[0].complete([_track('a')]);
      await tester.pump();

      // The pages fire this without awaiting it.
      unawaited(c.onDownloadStatusChanged());
      repo.patches.single.fail(StateError('db closed'));
      await tester.pump();
      expect(uuids(c), ['a']);
      expect(c.isSearching, isFalse);
      // testWidgets fails the test on an uncaught async error.
    });
  });

  group('isCapped', () {
    testWidgets('true when a requested type returns exactly limitPerType', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo, limitPerType: 2);
      await commit(tester, c, 'Blue');
      expect(repo.searches.single.limitPerType, 2);
      repo.searches.single.complete([_track('a'), _track('b')]);
      await tester.pump();
      expect(c.isCapped, isTrue);
    });

    testWidgets('false below the cap', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo, limitPerType: 3);
      await commit(tester, c, 'Blue');
      repo.searches.single.complete([_track('a'), _track('b')]);
      await tester.pump();
      expect(c.isCapped, isFalse);
    });

    testWidgets('ignores types that were not requested', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo, types: {SearchType.artists}, limitPerType: 1);
      await commit(tester, c, 'Blue');
      expect(repo.searches.single.types, {SearchType.artists});
      // A full page of a type nobody asked for (only artists were).
      repo.searches.single.complete([_track('a')]);
      await tester.pump();
      expect(c.isCapped, isFalse);
    });

    testWidgets('multi-type: any one requested type at the cap', (
      tester,
    ) async {
      const artist = ArtistUI(id: 1, name: 'A');
      const two = [artist, ArtistUI(id: 2, name: 'B')];
      for (final (artists, tracks, capped) in [
        (two, [_track('a')], true),
        (const [artist], [_track('a'), _track('b')], true),
        (const [artist], [_track('a')], false),
      ]) {
        final repo = _ScriptedRepo(db);
        final c = make(repo, types: SearchType.values.toSet(), limitPerType: 2);
        await commit(tester, c, 'Blue');
        repo.searches.single.completeWith((
          artists: artists,
          albums: const [],
          tracks: tracks,
        ));
        await tester.pump();
        expect(c.isCapped, capped, reason: '$artists / $tracks');
      }
    });
  });

  group('dispose', () {
    testWidgets('a pending debounce never fires', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      c.onQueryChanged('Blue');
      c.dispose();
      await tester.pump(_debounce * 2);
      expect(repo.searches, isEmpty);
    });

    testWidgets('an in-flight completion is dropped without notifying', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      var notifiedAfterDispose = false;
      c.addListener(() => notifiedAfterDispose = true);
      c.dispose();

      // Would throw "used after being disposed" if it notified.
      repo.searches.single.complete([_track('a')]);
      await tester.pump();
      expect(notifiedAfterDispose, isFalse);
    });

    testWidgets('dispose cancels the debounce timer outright', (tester) async {
      final c = make(_ScriptedRepo(db));
      c.onQueryChanged('Blue');
      c.dispose();
      // testWidgets fails the test if a timer is still pending here.
    });

    testWidgets('calls after dispose are silent no-ops', (tester) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches.single.complete([_track('a')]);
      await tester.pump();
      c.dispose();

      // Each would throw "used after being disposed" or leave a timer.
      c.submit('Red');
      c.clear();
      await c.rerun();
      await c.onDownloadStatusChanged();
      c.onQueryChanged('Red'); // last: nothing after it may cancel a timer
      expect(repo.searches, hasLength(1));
      expect(repo.patches, isEmpty);
    });

    testWidgets('a download-status patch landing after dispose is dropped', (
      tester,
    ) async {
      final repo = _ScriptedRepo(db);
      final c = make(repo);
      await commit(tester, c, 'Blue');
      repo.searches.single.complete([_track('a')]);
      await tester.pump();
      final pending = c.onDownloadStatusChanged();
      c.dispose();
      repo.patches.single.complete([_track('a', filePath: '/a')]);
      await pending; // must not throw
    });
  });

  // The controller over the real repository and in-memory FTS: the
  // scheduling above is proven with fakes; this checks the wiring.
  group('with the real repository', () {
    setUp(() async {
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
        SeedTrack(uuid: 'r1', title: 'Red Thing', artistId: 3, artist: 'Red'),
      ]);
    });

    /// Drives drift's microtask/zero-timer work under the fake clock until
    /// [done]; bounded, and fails rather than hangs.
    Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 50 && !done(); i++) {
        await tester.pump(Duration.zero);
      }
      expect(done(), isTrue, reason: 'condition not reached in 50 pumps');
    }

    testWidgets('a debounced query returns the matching tracks', (
      tester,
    ) async {
      final c = make(BrowseRepository(db));
      await commit(tester, c, 'blu');
      await pumpUntil(tester, () => !c.isSearching);
      expect(uuids(c), unorderedEquals(['d1', 's1']));
    });

    testWidgets('rerun() with downloadedOnly narrows to downloads', (
      tester,
    ) async {
      final c = make(BrowseRepository(db));
      await commit(tester, c, 'Blue');
      await pumpUntil(tester, () => !c.isSearching);
      downloadedOnly = true;
      unawaited(c.rerun());
      await pumpUntil(tester, () => !c.isSearching);
      expect(uuids(c), ['d1']);
    });

    testWidgets('a real delete: filtered re-search drops the row; unfiltered '
        'patch keeps it with cleared fields', (tester) async {
      final c = make(BrowseRepository(db));
      await commit(tester, c, 'Blue');
      await pumpUntil(tester, () => !c.isSearching);
      await db.update(db.tracks).write(clearedDownloadColumns);

      unawaited(c.onDownloadStatusChanged());
      await pumpUntil(
        tester,
        () => c.results.tracks.every((t) => !t.isDownloaded),
      );
      expect(uuids(c), unorderedEquals(['d1', 's1']));

      downloadedOnly = true;
      unawaited(c.onDownloadStatusChanged());
      await pumpUntil(tester, () => !c.isSearching);
      expect(c.results.tracks, isEmpty);
    });
  });
}
