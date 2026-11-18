// Phase 8 review r1 (8-R1-22, SP-UX-01(a), U29-B-01): a browse list whose
// local query failed says so and offers Retry. It never claims "No
// downloaded ... yet.", never shows a blank list and never disables Play
// with "No tracks to play." (spec §6: "Empty library, no matches and
// local-query failure have distinct states; Retry retains selection/query";
// SC-25: never claim none when the answer is unknown). Going offline turns
// the Downloaded chip on (Phase 3 D12): a failure stays a failure there.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/downloaded_tracks_page.dart';
import 'package:frontend/ui/tracks_page.dart';

import 'browse_harness.dart';
import 'fake_track_selection_controls.dart';

const _failed = "Couldn't load your library.";

/// Every browse window fails until [fail] is cleared.
class _FailingRepo extends BrowseRepository {
  _FailingRepo(super.db);

  bool fail = true;

  Stream<T> _or<T>(Stream<T> Function() real) =>
      fail ? Stream<T>.error(StateError('disk I/O error')) : real();

  @override
  Stream<List<TrackUI>> watchTracks({
    AlbumScope? album,
    int? limit,
    bool downloadedOnly = false,
  }) => _or(
    () => super.watchTracks(
      album: album,
      limit: limit,
      downloadedOnly: downloadedOnly,
    ),
  );

  @override
  Stream<List<AlbumUI>> watchAlbums({
    int? artistId,
    int? limit,
    bool downloadedOnly = false,
    bool offline = false,
  }) => _or(
    () => super.watchAlbums(
      artistId: artistId,
      limit: limit,
      downloadedOnly: downloadedOnly,
      offline: offline,
    ),
  );

  @override
  Stream<List<ArtistUI>> watchArtists({
    int? limit,
    bool downloadedOnly = false,
    bool offline = false,
  }) => _or(
    () => super.watchArtists(
      limit: limit,
      downloadedOnly: downloadedOnly,
      offline: offline,
    ),
  );
}

/// A tracks window the test drives.
class _DrivenRepo extends BrowseRepository {
  _DrivenRepo(super.db);
  final controller = StreamController<List<TrackUI>>.broadcast();

  @override
  Stream<List<TrackUI>> watchTracks({
    AlbumScope? album,
    int? limit,
    bool downloadedOnly = false,
  }) => controller.stream;
}

TrackUI _track(String uuid, String title) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  revision: 1,
  title: title,
  duration: 60,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

void main() {
  late AppDatabase db;
  late BrowseHarness h;
  late _FailingRepo repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    h = await BrowseHarness.create(db);
    repo = _FailingRepo(db);
  });

  tearDown(() async {
    await h.dispose();
    await db.close();
  });

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    bool offline = false,
    BrowseRepository? repository,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      h.wrap(
        Scaffold(body: page),
        offline: offline,
        repository: repository ?? repo,
      ),
    );
    // A driven window has not emitted yet: its loader never settles.
    settle ? await tester.pumpAndSettle() : await tester.pump();
  }

  Finder retry() => find.widgetWithText(TextButton, 'Retry');

  group('Tracks', () {
    testWidgets('chip off: a failure is shown with Retry, not a blank list; '
        'Retry loads', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 's1', title: 'Song', artistId: 1, artist: 'A'),
      ]);
      await pump(tester, const TracksPage(browseAll: true));
      expect(find.text(_failed), findsOneWidget);
      expect(retry(), findsOneWidget);
      expect(find.textContaining('disk I/O'), findsNothing);

      repo.fail = false;
      await tester.tap(retry());
      await tester.pumpAndSettle();
      expect(find.text('Song'), findsOneWidget);
      expect(find.text(_failed), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('chip on (offline): a failure is not "No downloaded tracks '
        'yet."; after Retry, a loaded empty window is', (tester) async {
      await pump(tester, const TracksPage(browseAll: true), offline: true);
      expect(find.text(_failed), findsOneWidget);
      expect(retry(), findsOneWidget);
      expect(find.text('No downloaded tracks yet.'), findsNothing);

      repo.fail = false;
      await tester.tap(retry());
      await tester.pumpAndSettle();
      expect(find.text(_failed), findsNothing);
      expect(find.text('No downloaded tracks yet.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('selection mode with the chip on (Manage library): failure '
        'with Retry, selection kept', (tester) async {
      final selection = FakeTrackSelectionControls();
      addTearDown(selection.dispose);
      selection.toggle(_track('kept', 'Kept'));
      await pump(
        tester,
        TracksPage(browseAll: true, selection: selection),
        offline: true,
      );
      expect(find.text(_failed), findsOneWidget);
      expect(retry(), findsOneWidget);
      expect(find.text('No downloaded tracks yet.'), findsNothing);
      expect(selection.selection.entries.map((e) => e.uuid), ['kept']);
      await teardownTree(tester);
    });

    testWidgets('a failure after rows loaded keeps them and offers Retry '
        '(no silent cut-off)', (tester) async {
      final driven = _DrivenRepo(db);
      addTearDown(driven.controller.close);
      await pump(
        tester,
        const TracksPage(browseAll: true),
        repository: driven,
        settle: false,
      );
      driven.controller.add([_track('t1', 'First')]);
      await tester.pump();
      driven.controller.addError(StateError('disk I/O error'));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
      expect(find.text(_failed), findsOneWidget);
      expect(retry(), findsOneWidget);
      await teardownTree(tester);
    });
  });

  // Review r1 R5: right after Retry, before the window answers, the page is
  // loading: it never claims empty for a frame.
  testWidgets('right after Retry the page is loading, not empty',
      (tester) async {
    final driven = _DrivenRepo(db);
    addTearDown(driven.controller.close);
    await pump(
      tester,
      const TracksPage(browseAll: true),
      offline: true,
      repository: driven,
      settle: false,
    );
    driven.controller.addError(StateError('disk I/O error'));
    await tester.pump();
    expect(find.text(_failed), findsOneWidget);
    await tester.tap(retry());
    await tester.pump();
    expect(find.text('No downloaded tracks yet.'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    driven.controller.add(const []);
    await tester.pumpAndSettle();
    expect(find.text('No downloaded tracks yet.'), findsOneWidget);
    await teardownTree(tester);
  });

  group('Albums', () {
    testWidgets('root, chip on: a failure is not "No downloaded albums yet."',
        (tester) async {
      await pump(tester, const AlbumsPage(browseAll: true), offline: true);
      expect(find.text(_failed), findsOneWidget);
      expect(retry(), findsOneWidget);
      expect(find.text('No downloaded albums yet.'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('root, chip off: a failure is shown, not a blank grid',
        (tester) async {
      await pump(tester, const AlbumsPage(browseAll: true));
      expect(find.text(_failed), findsOneWidget);
      expect(retry(), findsOneWidget);
      await teardownTree(tester);
    });

    // Review r2 8-R2-05(d): Retry is tapped, not only shown.
    testWidgets('root, chip off: Retry loads the albums', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(
          uuid: 's1',
          title: 'Song',
          artistId: 1,
          artist: 'Somebody',
          albumId: 10,
          album: 'Retried Album',
        ),
      ]);
      await pump(tester, const AlbumsPage(browseAll: true));
      expect(find.text(_failed), findsOneWidget);
      expect(find.text('Retried Album'), findsNothing);

      repo.fail = false;
      await tester.tap(retry());
      await tester.pumpAndSettle();
      expect(find.text(_failed), findsNothing);
      expect(find.text('Retried Album'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('root, chip on: after Retry a loaded empty grid is "No '
        'downloaded albums yet."', (tester) async {
      await pump(tester, const AlbumsPage(browseAll: true), offline: true);
      expect(find.text(_failed), findsOneWidget);

      repo.fail = false;
      await tester.tap(retry());
      await tester.pumpAndSettle();
      expect(find.text(_failed), findsNothing);
      expect(find.text('No downloaded albums yet.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets("an artist's album grid: a failure never disables Play with "
        '"No tracks to play."', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 's1', title: 'Song', artistId: 1, artist: 'A'),
      ]);
      await pump(tester, const AlbumsPage(artistId: 1));
      expect(find.text(_failed), findsOneWidget);
      expect(find.text('No tracks to play.'), findsNothing);
      await teardownTree(tester);
    });
  });

  group('Artists', () {
    testWidgets('going offline turns the chip on: the failure stays a '
        'failure, never "No downloaded artists yet."', (tester) async {
      await pump(tester, const ArtistsPage(browseAll: true));
      expect(find.text(_failed), findsOneWidget);
      h.offline.set(true);
      await tester.pumpAndSettle();
      expect(find.text(_failed), findsOneWidget);
      expect(retry(), findsOneWidget);
      expect(find.text('No downloaded artists yet.'), findsNothing);
      await teardownTree(tester);
    });

    // Review r2 8-R2-05(d): Retry is tapped, not only shown.
    testWidgets('chip off: Retry loads the artists', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 's1', title: 'Song', artistId: 1, artist: 'Retried Artist'),
      ]);
      await pump(tester, const ArtistsPage(browseAll: true));
      expect(find.text(_failed), findsOneWidget);
      expect(find.text('Retried Artist'), findsNothing);

      repo.fail = false;
      await tester.tap(retry());
      await tester.pumpAndSettle();
      expect(find.text(_failed), findsNothing);
      expect(find.text('Retried Artist'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('chip on (offline): after Retry a loaded empty list is "No '
        'downloaded artists yet."', (tester) async {
      await pump(tester, const ArtistsPage(browseAll: true), offline: true);
      expect(find.text(_failed), findsOneWidget);

      repo.fail = false;
      await tester.tap(retry());
      await tester.pumpAndSettle();
      expect(find.text(_failed), findsNothing);
      expect(find.text('No downloaded artists yet.'), findsOneWidget);
      await teardownTree(tester);
    });
  });

  group('Downloaded page', () {
    testWidgets('a failure is not "No downloaded tracks yet."; Retry loads',
        (tester) async {
      await tester.pumpWidget(
        h.wrap(const DownloadedTracksPage(), repository: repo),
      );
      await tester.pumpAndSettle();
      expect(find.text(_failed), findsOneWidget);
      expect(find.text('No downloaded tracks yet.'), findsNothing);

      repo.fail = false;
      await tester.tap(retry());
      await tester.pumpAndSettle();
      expect(find.text(_failed), findsNothing);
      expect(find.text('No downloaded tracks yet.'), findsOneWidget);
      await teardownTree(tester);
    });
  });
}
