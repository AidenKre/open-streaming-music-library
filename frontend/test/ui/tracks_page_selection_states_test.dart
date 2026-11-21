// 8B.1c S11: what the Manage library selection body adds to 8B.1a's mode
// (spec §6 para 3: "Empty library, no matches and local-query failure have
// distinct states; Retry retains selection/query"; "Rows show
// title/artist/album, UUID disambiguation if needed"; 8B.1a review R1-3).
// The owner's word (2026-11-17) replaces the disambiguation: no track ID
// is shown. Normal browse is unchanged.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/library_sync_status_view.dart';

import 'browse_harness.dart';
import 'fake_track_selection_controls.dart';
import '../helpers/library_seed.dart' show SeedTrack, seedLibrary;
import '../helpers/server_binding.dart' show seedTestBinding;

/// A repository whose browse window fails until [fail] is cleared.
class _FailingBrowseRepo extends BrowseRepository {
  _FailingBrowseRepo(super.db);

  bool fail = true;
  int watches = 0;

  @override
  Stream<List<TrackUI>> watchTracks({
    AlbumScope? album,
    int? limit,
    bool downloadedOnly = false,
  }) {
    watches++;
    if (fail) return Stream.error(StateError('disk I/O error'));
    return super.watchTracks(
      album: album,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
  }
}

/// A repository whose browse stream the test drives.
class _DrivenBrowseRepo extends BrowseRepository {
  _DrivenBrowseRepo(super.db);
  final controller = StreamController<List<TrackUI>>.broadcast();

  @override
  Stream<List<TrackUI>> watchTracks({
    AlbumScope? album,
    int? limit,
    bool downloadedOnly = false,
  }) => controller.stream;
}

const _notSynced = 'Your library has not synced to this device yet.';

const _twinA = 'aaaa1111-0000-4000-8000-000000000001';
const _twinB = 'bbbb2222-0000-4000-8000-000000000002';

void main() {
  late AppDatabase db;
  late BrowseHarness h;
  late FakeTrackSelectionControls selection;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    h = await BrowseHarness.create(db);
    selection = FakeTrackSelectionControls();
  });

  tearDown(() async {
    selection.dispose();
    await h.dispose();
    await db.close();
  });

  /// [sync]: the library sync's state (default: none ran yet). A running
  /// sync shows an endless progress bar, so the page is pumped, not
  /// settled.
  Future<void> pump(
    WidgetTester tester, {
    bool selectionMode = true,
    BrowseRepository? repository,
    TrackSyncState? sync,
    bool offline = false,
  }) async {
    await tester.pumpWidget(
      h.wrap(
        Scaffold(
          body: selectionMode
              ? TracksPage(browseAll: true, selection: selection)
              : const TracksPage(browseAll: true),
        ),
        repository: repository,
        offline: offline,
      ),
    );
    if (sync != null) {
      // The harness's stub sync; its state is what a sync would publish.
      ProviderScope.containerOf(tester.element(find.byType(TracksPage)))
          .read(trackSyncProvider.notifier)
          .state = AsyncData(sync);
    }
    if (sync?.librarySyncing ?? false) {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    } else {
      await tester.pumpAndSettle();
    }
  }

  group('empty library', () {
    testWidgets('selection mode says the library is empty', (tester) async {
      await tester.runAsync(() => seedTestBinding(db, reconciled: true));
      await pump(tester);
      expect(find.text('Your library is empty.'), findsOneWidget);
      await teardownTree(tester);
    });

    // An empty device library is not an empty library while its
    // sync runs or after it failed (a failed sign-in sync leaves it empty).
    testWidgets('after a failed library sync it says the sync failed, not '
        'that the library is empty', (tester) async {
      // A complete sync finished on this device: only the sync's own state
      // keeps the sentence away.
      await tester.runAsync(() => seedTestBinding(db, reconciled: true));
      await pump(
        tester,
        sync: const TrackSyncState(error: 'boom', libraryError: 'boom'),
      );
      expect(find.text("Couldn't sync your library."), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      expect(find.text('Your library is empty.'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('while the library syncs it says so, not that the library '
        'is empty', (tester) async {
      // A complete sync finished on this device: only the sync's own state
      // keeps the sentence away.
      await tester.runAsync(() => seedTestBinding(db, reconciled: true));
      await pump(
        tester,
        sync: const TrackSyncState(isSyncing: true, librarySyncing: true),
      );
      expect(find.text('Syncing your library…'), findsOneWidget);
      expect(find.text('Your library is empty.'), findsNothing);
      expect(find.text(_notSynced), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a server that looks restored gets its own line, not that '
        'the library is empty', (tester) async {
      // A complete sync finished on this device: only the sync's own state
      // keeps the sentence away.
      await tester.runAsync(() => seedTestBinding(db, reconciled: true));
      await pump(
        tester,
        sync: const TrackSyncState(
          error: 'regressed',
          libraryError: 'regressed',
          libraryServerRestored: true,
        ),
      );
      expect(
        find.text(LibrarySyncStatusView.serverRestoredMessage),
        findsOneWidget,
      );
      expect(find.text('Your library is empty.'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('after a library sync that found nothing it says the '
        'library is empty', (tester) async {
      await tester.runAsync(() => seedTestBinding(db, reconciled: true));
      await pump(tester, sync: const TrackSyncState());
      expect(find.text('Your library is empty.'), findsOneWidget);
      expect(find.text("Couldn't sync your library."), findsNothing);
      expect(find.text('Syncing your library…'), findsNothing);
      expect(find.text(_notSynced), findsNothing);
      await teardownTree(tester);
    });

    // A relaunch while the server cannot be reached: a new sync state, no
    // sync running, no error, and no complete library sync on this device.
    // The area says so (it was blank); nothing to press, since a sync
    // starts by itself once the server is reachable.
    testWidgets('with no complete library sync on this device it says the '
        'library has not synced yet, not that it is empty', (tester) async {
      await tester.runAsync(() => seedTestBinding(db));
      await pump(tester, sync: const TrackSyncState());
      expect(find.text(_notSynced), findsOneWidget);
      expect(find.text('Your library is empty.'), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('with no sign-in record at all it says the library has not '
        'synced yet', (tester) async {
      await pump(tester);
      expect(find.text(_notSynced), findsOneWidget);
      expect(find.text('Your library is empty.'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a first library sync that failed says so, not that the '
        'library has not synced', (tester) async {
      await tester.runAsync(() => seedTestBinding(db));
      await pump(
        tester,
        sync: const TrackSyncState(error: 'boom', libraryError: 'boom'),
      );
      expect(find.text("Couldn't sync your library."), findsOneWidget);
      expect(find.text(_notSynced), findsNothing);
      await teardownTree(tester);
    });

    // Offline after a failed first sync, once the person turns off the
    // Downloaded filter that going offline turned on.
    testWidgets('offline with no complete library sync, Downloaded off: it '
        'says the library has not synced yet', (tester) async {
      await tester.runAsync(() => seedTestBinding(db));
      await pump(
        tester,
        offline: true,
        sync: const TrackSyncState(error: 'boom', libraryError: 'boom'),
      );
      expect(find.text('No downloaded tracks yet.'), findsOneWidget);
      expect(find.text(_notSynced), findsNothing);
      await tester.tap(find.text('Downloaded'));
      await tester.pumpAndSettle();
      expect(find.text(_notSynced), findsOneWidget);
      expect(find.text('Your library is empty.'), findsNothing);
      await teardownTree(tester);
    });

    // A complete sync finished earlier; a later one failed, then offline.
    // The library did sync to this device, so the sentence would be untrue.
    testWidgets('offline after a later sync failed, with a complete sync '
        'before it, Downloaded off: no "has not synced" sentence',
        (tester) async {
      await tester.runAsync(() => seedTestBinding(db, reconciled: true));
      await pump(
        tester,
        offline: true,
        sync: const TrackSyncState(error: 'boom', libraryError: 'boom'),
      );
      await tester.tap(find.text('Downloaded'));
      await tester.pumpAndSettle();
      expect(find.text(_notSynced), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('offline with downloads and no complete library sync, the '
        'Downloaded filter lists them', (tester) async {
      await tester.runAsync(() => seedTestBinding(db));
      await seedLibrary(db, const [
        SeedTrack(
            uuid: 'd1', title: 'Kept', artistId: 1, artist: 'A',
            downloaded: true),
      ]);
      await pump(tester, offline: true, sync: const TrackSyncState());
      expect(find.text('Kept'), findsOneWidget);
      expect(find.text(_notSynced), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('once the first library sync finishes with nothing, it says '
        'the library is empty', (tester) async {
      await tester.runAsync(() => seedTestBinding(db));
      await pump(
        tester,
        sync: const TrackSyncState(isSyncing: true, librarySyncing: true),
      );
      expect(find.text('Syncing your library…'), findsOneWidget);
      expect(find.text('Your library is empty.'), findsNothing);
      expect(find.text(_notSynced), findsNothing);
      // The sync's final page stores the marker; then the sync ends.
      await tester.runAsync(() => db.customStatement(
          'UPDATE server_binding SET catalog_reconciled_at_binding = 1'));
      ProviderScope.containerOf(tester.element(find.byType(TracksPage)))
          .read(trackSyncProvider.notifier)
          .state = const AsyncData(TrackSyncState());
      await tester.pumpAndSettle();
      expect(find.text('Your library is empty.'), findsOneWidget);
      expect(find.text(_notSynced), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('normal browse is unchanged (no such text)', (tester) async {
      await pump(tester, selectionMode: false);
      expect(find.text('Your library is empty.'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a library with tracks shows no empty text', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 's1', title: 'Song', artistId: 1, artist: 'A'),
      ]);
      await pump(tester);
      expect(find.text('Song'), findsOneWidget);
      expect(find.text('Your library is empty.'), findsNothing);
      await teardownTree(tester);
    });
  });

  group('a local query failure', () {
    testWidgets('shows a failure with Retry, distinct from empty; Retry '
        'loads and keeps the selection', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 's1', title: 'Song', artistId: 1, artist: 'A'),
      ]);
      final repo = _FailingBrowseRepo(db);
      selection.toggle(
        TrackUI(
          uuidId: 'kept',
          createdAt: 0,
          lastUpdated: 0,
          revision: 3,
          title: 'Kept',
          duration: 60,
          bitrateKbps: 320,
          sampleRateHz: 44100,
          channels: 2,
          hasAlbumArt: false,
        ),
      );
      await pump(tester, repository: repo);
      expect(find.text("Couldn't load your library."), findsOneWidget);
      expect(find.text('Your library is empty.'), findsNothing);
      expect(find.text('Song'), findsNothing);
      // The error text never leaks the cause.
      expect(find.textContaining('disk I/O'), findsNothing);

      repo.fail = false;
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Song'), findsOneWidget);
      expect(find.text("Couldn't load your library."), findsNothing);
      expect(selection.selection.entries.map((e) => e.uuid), ['kept']);
      expect(selection.calls, ['toggle kept'], reason: 'Retry keeps it');
      await teardownTree(tester);
    });
  });

  // The owner, 2026-11-17: "We should never reveal track ids to users."
  // Rows that read the same are not told apart by an ID.
  group('no track ID', () {
    testWidgets('rows that would read the same show no ID', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(
          uuid: _twinA,
          title: 'Same',
          artistId: 1,
          artist: 'A',
          albumId: 1,
          album: 'X',
        ),
        SeedTrack(
          uuid: _twinB,
          title: 'Same',
          artistId: 1,
          artist: 'A',
          albumId: 1,
          album: 'X',
          trackNumber: 2,
        ),
        SeedTrack(
          uuid: 'cccc3333-unique',
          title: 'Other',
          artistId: 1,
          artist: 'A',
          albumId: 1,
          album: 'X',
          trackNumber: 3,
        ),
      ]);
      await pump(tester);
      expect(find.text('Same'), findsNWidgets(2));
      expect(find.text('Other'), findsOneWidget);
      expect(find.textContaining('ID '), findsNothing);
      expect(find.textContaining('aaaa1111'), findsNothing);
      expect(find.textContaining('bbbb2222'), findsNothing);
      expect(find.textContaining('cccc3333'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('normal browse shows no ids', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(uuid: _twinA, title: 'Same', artistId: 1, artist: 'A'),
        SeedTrack(
          uuid: _twinB,
          title: 'Same',
          artistId: 1,
          artist: 'A',
          trackNumber: 2,
        ),
      ]);
      await pump(tester, selectionMode: false);
      expect(find.textContaining('aaaa1111'), findsNothing);
      await teardownTree(tester);
    });
  });

  group('review r1', () {
    testWidgets('a later successful window clears the failure', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 's1', title: 'Song', artistId: 1, artist: 'A'),
      ]);
      final rows = await BrowseRepository(db).getTracksByUuids(['s1']);
      final repo = _DrivenBrowseRepo(db);
      await tester.pumpWidget(
        h.wrap(
          Scaffold(body: TracksPage(browseAll: true, selection: selection)),
          repository: repo,
        ),
      );
      await tester.pump(); // subscribed; nothing emitted yet
      repo.controller.addError(StateError('busy'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load your library."), findsOneWidget);
      repo.controller.add(rows);
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load your library."), findsNothing);
      expect(find.text('Song'), findsOneWidget);
      await teardownTree(tester);
      await repo.controller.close();
    });

    testWidgets('downloaded look-alike rows keep their download badges and '
        'show no ID', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(
          uuid: _twinA,
          title: 'Same',
          artistId: 1,
          artist: 'A',
          downloaded: true,
        ),
        SeedTrack(
          uuid: _twinB,
          title: 'Same',
          artistId: 1,
          artist: 'A',
          trackNumber: 2,
          downloaded: true,
        ),
      ]);
      await pump(tester);
      expect(find.textContaining('ID '), findsNothing);
      expect(find.textContaining('aaaa1111'), findsNothing);
      expect(find.byIcon(Icons.download_done), findsNWidgets(2));
      await teardownTree(tester);
    });
  });
}
