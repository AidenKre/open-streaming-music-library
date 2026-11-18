// Phase 6 §3 "Offline chip OFF" (6-U09 card semantics, 6-R04 unit half):
// offline with the Home chip OFF, remote-only recents stay visible; a
// remote-only track dims and can't play or queue but keeps Get info; an
// album or artist card stays navigable and shows the unavailable state when
// none of its members plays offline (a partly downloaded one plays,
// DEV-6-02). Availability is the shared `playbackAvailabilityProvider`
// (SC-06) over real Drift download counts; the controller is faked.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/tracks_page.dart';

import '../browse_harness.dart';
import '../../helpers/fake_home_controls.dart' show FakeHomeControls;
import '../../helpers/library_seed.dart' show SeedTrack, seedLibrary;

TrackUI _track(String uuid, {bool downloaded = false}) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Song $uuid',
  artist: 'Ann',
  artistId: 1,
  albumId: 1,
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
  filePath: downloaded ? '/downloads/$uuid.flac' : null,
);

void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  // Artist 1 "Ann": album 1 "Remote" (r1, r2: nothing downloaded).
  // Artist 2 "Bea": album 2 "Partial" (p1 downloaded, p2 not).
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    await seedLibrary(db, const [
      SeedTrack(uuid: 'r1', title: 'Song r1', artistId: 1, artist: 'Ann',
          albumId: 1, album: 'Remote'),
      SeedTrack(uuid: 'r2', title: 'Song r2', artistId: 1, artist: 'Ann',
          albumId: 1, album: 'Remote', trackNumber: 2),
      SeedTrack(uuid: 'p1', title: 'Song p1', artistId: 2, artist: 'Bea',
          albumId: 2, album: 'Partial', downloaded: true),
      SeedTrack(uuid: 'p2', title: 'Song p2', artistId: 2, artist: 'Bea',
          albumId: 2, album: 'Partial', trackNumber: 2),
    ]);
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<FakeHomeControls> pumpHome(
    WidgetTester tester,
    List<FeedEntity> entities,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = FakeHomeControls(HomeRecentsReady(entities));
    await tester.pumpWidget(
      harness.wrap(
        const HomePage(),
        offline: true,
        overrides: [homeControlsProvider.overrideWithValue(fake)],
      ),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  double opacityOf(WidgetTester tester, String key) => tester
      .widget<Opacity>(
        find
            .descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Opacity),
            )
            .first,
      )
      .opacity;

  ListTile menuTile(WidgetTester tester, String label) => tester.widget(
    find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
  );

  testWidgets('the chip stays OFF and remote-only recents stay visible',
      (tester) async {
    final fake = await pumpHome(tester, [
      TrackEntity(_track('r1')),
      const AlbumEntity(AlbumUI(id: 1, artistId: 1, name: 'Remote')),
    ]);
    expect(fake.filters.downloaded, isFalse);
    expect(find.text('Song r1'), findsOneWidget);
    expect(find.text('Remote'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('a remote-only track dims, does not play, keeps Get info',
      (tester) async {
    final fake = await pumpHome(tester, [
      TrackEntity(_track('r1')),
      TrackEntity(_track('p1', downloaded: true)),
    ]);
    expect(opacityOf(tester, 'track:r1'), lessThan(1));
    expect(opacityOf(tester, 'track:p1'), 1);

    await tester.tap(find.text('Song r1'));
    await tester.pump();
    expect(fake.played, isEmpty);
    await tester.tap(find.text('Song p1'));
    await tester.pump();
    expect(fake.played, ['p1']);

    await tester.longPress(find.text('Song r1'));
    await tester.pumpAndSettle();
    expect(menuTile(tester, 'Get Info').enabled, isTrue);
    expect(menuTile(tester, 'Play Next').enabled, isFalse);
    expect(menuTile(tester, 'Add to Queue').enabled, isFalse);
    await teardownTree(tester);
  });

  testWidgets('an album with nothing playable offline shows the unavailable '
      'state and still opens', (tester) async {
    await pumpHome(tester, [
      const AlbumEntity(
        AlbumUI(id: 1, artistId: 1, name: 'Remote', artist: 'Ann'),
      ),
      const AlbumEntity(
        AlbumUI(id: 2, artistId: 2, name: 'Partial', artist: 'Bea'),
      ),
    ]);
    expect(opacityOf(tester, 'album:1'), lessThan(1));
    // Partly downloaded: plays offline (DEV-6-02), not dimmed.
    expect(opacityOf(tester, 'album:2'), 1);

    await tester.tap(find.text('Remote'));
    await tester.pumpAndSettle();
    expect(find.byType(TracksPage), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('an artist with nothing playable offline shows the unavailable '
      'state and still opens', (tester) async {
    await pumpHome(tester, [
      const ArtistEntity(ArtistUI(id: 1, name: 'Ann')),
      const ArtistEntity(ArtistUI(id: 2, name: 'Bea')),
    ]);
    expect(opacityOf(tester, 'artist:1'), lessThan(1));
    expect(opacityOf(tester, 'artist:2'), 1);

    await tester.tap(find.byKey(const ValueKey('artist:1')));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumsPage), findsOneWidget);
    await teardownTree(tester);
  });
}
