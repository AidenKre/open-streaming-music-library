// Phase 6 §3 (See all), §7 (header, chip, refresh, retry, responsive grid,
// shell insets, no last-page spinner) / SC-26 / 6-U09, 6-G01 (unit halves):
// the See all page renders only what `SeeAllRecentsControls` says and
// forwards every input to it. Widget tests over a fake controller.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';
import 'package:frontend/ui/feed/see_all_recents_controller.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';

import '../browse_harness.dart';
import '../fake_see_all_recents_controls.dart';

TrackUI _track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Song $uuid',
  artist: 'Ann',
  artistId: 1,
  albumId: 2,
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

List<FeedEntity> _tracks(int n, {String prefix = 't'}) => [
  for (var i = 0; i < n; i++) TrackEntity(_track('$prefix$i')),
];

const _album = AlbumUI(id: 2, artistId: 1, name: 'Second', artist: 'Ann');
const _artist = ArtistUI(id: 1, name: 'Ann');

Finder _card(String key) => find.byKey(ValueKey(key));
final _chip = find.byKey(FilterBar.downloadedChipKey);
final _refresh = find.byTooltip('Refresh');
final _spinner = find.byType(CircularProgressIndicator);

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late FakeSeeAllRecentsControls fake;
  late List<bool> created;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    created = [];
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  /// Pumps a root page with a button that opens See all (so it has a back
  /// button), inside shell insets, and opens it.
  Future<void> pumpSeeAll(
    WidgetTester tester, {
    bool initialDownloaded = false,
    double bottomInset = 0,
    Size size = const Size(800, 1200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    fake = FakeSeeAllRecentsControls(initialDownloaded: initialDownloaded);
    await tester.pumpWidget(
      harness.wrap(
        // Like a shell tab: the insets sit above the tab's own navigator.
        ShellChromeInsets(
          top: 0,
          bottom: bottomInset,
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => openSeeAllRecents(
                      context,
                      initialDownloaded: initialDownloaded,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
        overrides: [
          seeAllRecentsControllerFactoryProvider.overrideWithValue(({
            required initialDownloaded,
          }) {
            created.add(initialDownloaded);
            return fake;
          }),
        ],
      ),
    );
    await tester.tap(find.text('open'));
    // Bounded: the loading spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('opening creates one controller with the given chip value; '
      'closing disposes it', (tester) async {
    await pumpSeeAll(tester, initialDownloaded: true);
    expect(created, [true]);
    expect(find.text('Recently played'), findsOneWidget);
    fake.show(entities: _tracks(1));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Recently played'), findsNothing);
    expect(fake.disposed, isTrue);
    await teardownTree(tester);
  });

  testWidgets('the chip shows the controller value and forwards taps; the '
      'refresh action forwards', (tester) async {
    await pumpSeeAll(tester, initialDownloaded: true);
    fake.show(entities: _tracks(2));
    await tester.pump();
    final chip = tester.widget<FilterChip>(_chip);
    expect(chip.selected, isTrue);
    await tester.tap(_chip);
    await tester.pump();
    expect(fake.chipTaps, [false]);
    await tester.tap(_refresh);
    await tester.pump();
    expect(fake.refreshes, 1);
    await teardownTree(tester);
  });

  testWidgets('loading shows a progress indicator and no cards',
      (tester) async {
    await pumpSeeAll(tester);
    expect(_spinner, findsOneWidget);
    expect(find.text('No recently played items'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('a settled empty snapshot says so; filtered empty says '
      '"No downloaded recents"', (tester) async {
    await pumpSeeAll(tester);
    fake.show(entities: const []);
    await tester.pump();
    expect(_spinner, findsNothing);
    expect(find.text('No recently played items'), findsOneWidget);
    fake.setDownloaded(true);
    fake.show(entities: const []);
    await tester.pump();
    expect(find.text('No downloaded recents'), findsOneWidget);
    expect(_chip, findsOneWidget, reason: 'the chip stays reachable');
    await teardownTree(tester);
  });

  testWidgets('a failed first page offers Retry', (tester) async {
    await pumpSeeAll(tester);
    fake.show(failed: true);
    await tester.pump();
    expect(_spinner, findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    expect(fake.retries, 1);
    await teardownTree(tester);
  });

  testWidgets('a failed next page keeps the cards and offers Retry at the end',
      (tester) async {
    await pumpSeeAll(tester);
    fake.show(entities: _tracks(3), hasMore: true, failed: true);
    await tester.pump();
    expect(_card('track:t0'), findsOneWidget);
    expect(_spinner, findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    expect(fake.retries, 1);
    await teardownTree(tester);
  });

  testWidgets('a trailing loader while more pages exist; none on the last '
      'page', (tester) async {
    await pumpSeeAll(tester);
    fake.show(entities: _tracks(3), hasMore: true);
    await tester.pump();
    expect(_spinner, findsOneWidget);
    fake.show(entities: _tracks(3));
    await tester.pump();
    expect(_spinner, findsNothing);
    await teardownTree(tester);
  });

  testWidgets('scrolling near the end asks for the next page', (tester) async {
    await pumpSeeAll(tester, size: const Size(400, 800));
    fake.show(entities: _tracks(50), hasMore: true);
    await tester.pump();
    await tester.pump();
    final before = fake.loadMores;
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
    await tester.pump();
    expect(fake.loadMores, greaterThan(before));
    await teardownTree(tester);
  });

  testWidgets('a short first page that does not fill the screen asks for '
      'more by itself', (tester) async {
    await pumpSeeAll(tester);
    fake.show(entities: _tracks(2), hasMore: true);
    await tester.pump();
    await tester.pump();
    expect(fake.loadMores, greaterThan(0));
    await teardownTree(tester);
  });

  // Review r1 #1: live updates can empty the loaded rows while more pages
  // exist; later pages must still fill the space (§7).
  testWidgets('no loaded rows left but more pages: asks for more and shows '
      'no empty message', (tester) async {
    await pumpSeeAll(tester);
    fake.show(entities: const [], hasMore: true);
    await tester.pump();
    await tester.pump();
    expect(fake.loadMores, greaterThan(0));
    expect(find.text('No recently played items'), findsNothing);
    expect(_spinner, findsOneWidget);
    await teardownTree(tester);
  });

  // Review r1 #2: a first page that came back expired is not "empty
  // history"; only the History changed notice is shown.
  testWidgets('an expired, empty snapshot shows History changed without an '
      'empty message', (tester) async {
    await pumpSeeAll(tester);
    fake.show(entities: const [], notice: SnapshotStaleness.historyChanged);
    await tester.pump();
    expect(find.text('History changed'), findsOneWidget);
    expect(find.text('No recently played items'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('New activity and History changed notices with Refresh',
      (tester) async {
    await pumpSeeAll(tester);
    fake.show(entities: _tracks(2), notice: SnapshotStaleness.newActivity);
    await tester.pump();
    expect(find.byType(NewActivityNotice), findsOneWidget);
    expect(find.text('New activity'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(NewActivityNotice),
        matching: find.text('Refresh'),
      ),
    );
    expect(fake.refreshes, 1);
    fake.show(entities: _tracks(2), notice: SnapshotStaleness.historyChanged);
    await tester.pump();
    expect(find.text('History changed'), findsOneWidget);
    fake.show(entities: _tracks(2));
    await tester.pump();
    expect(find.byType(NewActivityNotice), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('a responsive grid of shared card extents: more columns when '
      'wider, every card at most the rail card width', (tester) async {
    await pumpSeeAll(tester, size: const Size(400, 1200));
    fake.show(entities: _tracks(12));
    await tester.pump();
    final narrow = tester.getSize(_card('track:t0'));
    final context = tester.element(_card('track:t0'));
    final extent = FeedCardExtent.of(context);
    expect(narrow.width, lessThanOrEqualTo(FeedCardExtent.cardWidth));
    expect(narrow.height, extent.height);
    final narrowColumns = [
      for (var i = 0; i < 12; i++) tester.getTopLeft(_card('track:t$i')).dy,
    ].where((dy) => dy == tester.getTopLeft(_card('track:t0')).dy).length;

    tester.view.physicalSize = const Size(1200, 1200);
    await tester.pump();
    final wideColumns = [
      for (var i = 0; i < 12; i++) tester.getTopLeft(_card('track:t$i')).dy,
    ].where((dy) => dy == tester.getTopLeft(_card('track:t0')).dy).length;
    expect(wideColumns, greaterThan(narrowColumns));
    expect(
      tester.getSize(_card('track:t0')).width,
      lessThanOrEqualTo(FeedCardExtent.cardWidth),
    );
    await teardownTree(tester);
  });

  testWidgets('the last card ends above the shell bottom chrome',
      (tester) async {
    const inset = 150.0;
    await pumpSeeAll(tester, size: const Size(400, 800), bottomInset: inset);
    fake.show(entities: _tracks(30));
    await tester.pump();
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
    await tester.pumpAndSettle();
    final last = tester.getRect(_card('track:t29'));
    expect(last.bottom, lessThanOrEqualTo(800 - inset));
    await teardownTree(tester);
  });

  testWidgets('a new snapshot starts at the top', (tester) async {
    await pumpSeeAll(tester, size: const Size(400, 800));
    fake.show(entities: _tracks(30));
    await tester.pump();
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(_card('track:t0'), findsNothing);
    fake.show(entities: _tracks(30, prefix: 'n'), newSnapshot: true);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_card('track:n0')).dy, lessThan(400));
    await teardownTree(tester);
  });

  testWidgets('a live update keeps the scroll position', (tester) async {
    await pumpSeeAll(tester, size: const Size(400, 800));
    fake.show(entities: _tracks(30));
    await tester.pump();
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -1500));
    await tester.pumpAndSettle();
    final y = tester.getTopLeft(_card('track:t20')).dy;
    fake.show(entities: _tracks(30));
    await tester.pump();
    expect(tester.getTopLeft(_card('track:t20')).dy, y);
    await teardownTree(tester);
  });

  group('taps', () {
    testWidgets('a track plays through the controller', (tester) async {
      await pumpSeeAll(tester);
      fake.show(entities: _tracks(1));
      await tester.pump();
      await tester.tap(_card('track:t0'));
      await tester.pump();
      expect(fake.played, ['t0']);
      await teardownTree(tester);
    });

    testWidgets('an album opens its detail page only', (tester) async {
      await pumpSeeAll(tester);
      fake.show(entities: const [AlbumEntity(_album)]);
      await tester.pump();
      await tester.tap(_card('album:2'));
      await tester.pumpAndSettle();
      expect(find.byType(TracksPage), findsOneWidget);
      expect(fake.played, isEmpty);
      await teardownTree(tester);
    });

    testWidgets('an artist opens its detail page only', (tester) async {
      await pumpSeeAll(tester);
      fake.show(entities: const [ArtistEntity(_artist)]);
      await tester.pump();
      await tester.tap(_card('artist:1'));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumsPage), findsOneWidget);
      expect(fake.played, isEmpty);
      await teardownTree(tester);
    });
  });
}
