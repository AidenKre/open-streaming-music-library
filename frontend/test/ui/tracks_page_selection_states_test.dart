// 8B.1c S11: what the Manage library selection body adds to 8B.1a's mode
// (spec §6 para 3: "Empty library, no matches and local-query failure have
// distinct states; Retry retains selection/query"; "Rows show
// title/artist/album, UUID disambiguation if needed"; 8B.1a review R1-3).
// Normal browse is unchanged.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/tracks_page.dart';

import 'browse_harness.dart';
import 'fake_track_selection_controls.dart';
import '../helpers/library_seed.dart' show SeedTrack, seedLibrary;

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

  Future<void> pump(
    WidgetTester tester, {
    bool selectionMode = true,
    BrowseRepository? repository,
  }) async {
    await tester.pumpWidget(
      h.wrap(
        Scaffold(
          body: selectionMode
              ? TracksPage(browseAll: true, selection: selection)
              : const TracksPage(browseAll: true),
        ),
        repository: repository,
      ),
    );
    await tester.pumpAndSettle();
  }

  group('empty library', () {
    testWidgets('selection mode says the library is empty', (tester) async {
      await pump(tester);
      expect(find.text('Your library is empty.'), findsOneWidget);
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

  group('UUID disambiguation', () {
    testWidgets('rows that would read the same show a short id; others '
        'none', (tester) async {
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
      expect(find.textContaining('aaaa1111'), findsOneWidget);
      expect(find.textContaining('bbbb2222'), findsOneWidget);
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

    testWidgets('a downloaded look-alike row keeps its download badge next '
        'to its id', (tester) async {
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
      expect(find.textContaining('aaaa1111'), findsOneWidget);
      expect(find.byIcon(Icons.download_done), findsNWidgets(2));
      await teardownTree(tester);
    });
  });
}
