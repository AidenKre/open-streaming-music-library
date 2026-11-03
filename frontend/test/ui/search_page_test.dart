import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';
import 'package:frontend/ui/widgets/search_status.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/library_card.dart';
import 'package:frontend/ui/widgets/track_card.dart';

import 'browse_harness.dart';
import 'fake_library_search_controls.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await _seedSearchData(db);
    tempDir = await Directory.systemTemp.createTemp('search-page-test');
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets(
    'search artist and album cards expose queue actions on long press',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            localCoverArtStoreProvider.overrideWithValue(coverStore),
          ],
          child: const MaterialApp(home: SearchPage()),
        ),
      );

      await tester.enterText(find.byType(TextField), 'Search');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(ArtistCard), findsOneWidget);
      expect(find.byType(AlbumCard), findsOneWidget);

      await tester.longPress(find.byType(ArtistCard));
      await tester.pumpAndSettle();

      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Add to Queue'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 4A.3: rails are taller than the old rows; bring the album into view.
      await tester.ensureVisible(find.byType(AlbumCard));
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Add to Queue'), findsOneWidget);
    },
  );

  group('shared search primitive (regressions)', () {
    late AppDatabase libDb;
    late BrowseHarness h;

    setUp(() async {
      initCoverArtCache(CoverArtCacheManager.noop());
      libDb = AppDatabase(NativeDatabase.memory());
      // Seven tracks match "Blue" by title only; artist/album names don't,
      // so the Songs rail is the only one on screen.
      await seedLibrary(libDb, [
        for (var i = 1; i <= 7; i++)
          SeedTrack(
            uuid: 'b$i',
            title: 'Blue $i',
            artistId: i,
            artist: 'Artist $i',
            downloaded: i == 1,
          ),
      ]);
      h = await BrowseHarness.create(libDb);
    });

    tearDown(() async {
      await libDb.close();
      await h.dispose();
    });

    Future<void> search(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
    }

    String fieldText(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    FilterChip chip(WidgetTester tester) =>
        tester.widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey));

    Finder inFeed(Finder f) =>
        find.descendant(of: find.byType(SectionedFeedView), matching: f);

    /// Tap a song and return the list it played, in queue order.
    Future<List<String>> playedListFrom(
      WidgetTester tester,
      String title,
    ) async {
      await tester.tap(find.text(title));
      await tester.pump();
      final call = h.audio.calls.last;
      expect(call['method'], 'playFromTrackList');
      expect(call['sourceType'], 'search');
      return (call['uuids'] as List).cast<String>();
    }

    testWidgets('the field stays above scrolled results, keeping its text '
        'and never taking focus back', (tester) async {
      // Matches in all three rails make the results taller than the 600px
      // test viewport. The field used to be the results list's first child:
      // scrolled away it was disposed (losing its text), and rebuilt it
      // autofocused again, reopening the keyboard. 4A.3: the header still
      // sits above the feed (never scrolls with it).
      await seedLibrary(libDb, [
        for (var i = 1; i <= 6; i++)
          SeedTrack(
            uuid: 'z$i',
            title: 'Zed Song $i',
            artistId: 100 + i,
            artist: 'Zed Artist $i',
            albumId: 100 + i,
            album: 'Zed Album $i',
          ),
      ]);
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Zed');
      expect(find.byType(ArtistCard), findsWidgets);
      FocusManager.instance.primaryFocus
          ?.unfocus(); // e.g. after opening a result
      await tester.pump();

      final feed = find.byType(CustomScrollView);
      await tester.drag(feed, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.byType(ArtistCard), findsNothing, reason: 'scrolled away');
      expect(fieldText(tester), 'Zed');
      expect(find.byTooltip('Clear search'), findsOneWidget);

      await tester.drag(feed, const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'Zed');
      expect(find.byType(ArtistCard), findsWidgets);
      expect(
        tester.testTextInput.isVisible,
        isFalse,
        reason: 'the dismissed keyboard stays dismissed',
      );
      await teardownTree(tester);
    });

    testWidgets('the keyboard search action searches without the debounce', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.textInputAction, TextInputAction.search);

      await tester.showKeyboard(find.byType(TextField));
      tester.testTextInput.enterText('Blue');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(); // one frame: the search starts
      await tester.pump(); // ... and lands
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.byType(TrackCard), findsWidgets);
      // The debounce timer from typing was cancelled; nothing re-runs.
      await tester.pump(const Duration(milliseconds: 350));
      expect(await playedListFrom(tester, 'Blue 1'), hasLength(7));
      await teardownTree(tester);
    });

    // 4A.3: a failure offers Retry (was copy only).
    testWidgets('a failed search says so with Retry, not "No results match"', (
      tester,
    ) async {
      final repo = _FlakySearchRepo(libDb)..fail = true;
      await tester.pumpWidget(h.wrap(const SearchPage(), repository: repo));
      await search(tester, 'Blue');
      expect(find.text(searchFailedMessage), findsOneWidget);
      expect(find.textContaining('No results match'), findsNothing);

      repo.fail = false;
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(find.text(searchFailedMessage), findsNothing);
      expect(find.byType(TrackCard), findsWidgets);
      expect(fieldText(tester), 'Blue', reason: 'query kept');
      await teardownTree(tester);
    });

    // 4A.3: songs are a rail of cards; the cap is 100, so all 7 play
    // (was the 5 visible rows).
    // Audit 4A(c) #2: the fixture makes FTS rank differ from insertion
    // and title order, so only a rank-ordered queue passes (the old cap-5
    // test pinned the exact shown order; this keeps that strength).
    testWidgets('tapping a song plays the capped results in rank order', (
      tester,
    ) async {
      await seedLibrary(libDb, const [
        // Inserted last, ranks first (more "blue" in a short title).
        SeedTrack(uuid: 'zz', title: 'Blue Blue', artistId: 90, artist: 'Q'),
        // Long title: ranks last; sorts first by title.
        SeedTrack(
          uuid: 'aa',
          title: 'A blue title that is much longer',
          artistId: 91,
          artist: 'R',
        ),
      ]);
      final ranked = [
        for (final t in (await tester.runAsync(
          () => BrowseRepository(
            libDb,
          ).search('Blue', types: {SearchType.tracks}, limitPerType: 100),
        ))!.tracks)
          t.uuidId,
      ];
      final titles =
          (await tester.runAsync(
                () => libDb
                    .customSelect('SELECT uuid_id, title FROM trackmetadata')
                    .get(),
              ))!
              .map((r) => (r.read<String>('uuid_id'), r.read<String>('title')))
              .toList();
      final insertion = [for (final r in titles) r.$1];
      final byTitle = [...titles]
        ..sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
      expect(ranked, hasLength(9));
      expect(
        ranked,
        isNot(insertion),
        reason: 'precondition: rank != insertion',
      );
      expect(
        ranked,
        isNot([for (final r in byTitle) r.$1]),
        reason: 'precondition: rank != title order',
      );

      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      await tester.tap(find.text('Blue 3'));
      await tester.pump();
      expect(h.audio.calls.single, {
        'method': 'playFromTrackList',
        'uuids': ranked,
        'uuid': 'b3',
        'sourceType': 'search',
      });
      await teardownTree(tester);
    });

    testWidgets('an artist result opens that artist\'s albums', (tester) async {
      await seedLibrary(libDb, [
        const SeedTrack(
          uuid: 'q1',
          title: 'Quiet One',
          artistId: 50,
          artist: 'Quasar',
          albumId: 50,
          album: 'Nebula',
        ),
      ]);
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Quasar');
      await tester.tap(find.byType(ArtistCard));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Quasar'), findsOneWidget);
      expect(tester.widget<AlbumsPage>(find.byType(AlbumsPage)).artistId, 50);
      await teardownTree(tester);
    });

    Future<void> seedNebula({required bool singles}) async {
      await seedLibrary(libDb, [
        const SeedTrack(
          uuid: 'n1',
          title: 'Orbit',
          artistId: 60,
          artist: 'Nova',
          albumId: 60,
          album: 'Nebula',
        ),
      ]);
      await (libDb.update(libDb.albums)..where((a) => a.id.equals(60))).write(
        AlbumsCompanion(isSingleGrouping: Value(singles)),
      );
    }

    testWidgets('an album result opens its tracks', (tester) async {
      await seedNebula(singles: false);
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Nebula');
      await tester.tap(find.byType(AlbumCard));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Nebula'), findsOneWidget);
      final page = tester.widget<TracksPage>(find.byType(TracksPage));
      expect((page.artistId, page.albumId), (60, 60));
      await teardownTree(tester);
    });

    testWidgets('a singles grouping opens titled "<artist> - Singles"', (
      tester,
    ) async {
      await seedNebula(singles: true);
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Nebula');
      await tester.tap(find.byType(AlbumCard));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Nova - Singles'), findsOneWidget);
      await teardownTree(tester);
    });

    // 4A.3: the Downloaded chip replaces the forced offline badge (SC-09
    // autoApply: offline turns it on, reconnecting undoes only that).
    testWidgets('coming back online re-runs the query unfiltered', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage(), offline: true));
      await search(tester, 'Blue');
      expect(chip(tester).selected, isTrue);
      expect(find.byType(DownloadedOnlyBadge), findsNothing);
      expect(await playedListFrom(tester, 'Blue 1'), ['b1']);

      h.offline.set(false);
      await tester.pumpAndSettle();
      expect(chip(tester).selected, isFalse);
      expect(await playedListFrom(tester, 'Blue 1'), hasLength(7));
      await teardownTree(tester);
    });

    testWidgets('a chip the user chose survives a reconnect', (tester) async {
      await tester.pumpWidget(h.wrap(const SearchPage(), offline: true));
      await search(tester, 'Blue');
      await tester.tap(find.byKey(FilterBar.downloadedChipKey)); // OFF
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FilterBar.downloadedChipKey)); // ON, mine
      await tester.pumpAndSettle();
      h.offline.set(false);
      await tester.pumpAndSettle();
      expect(chip(tester).selected, isTrue);
      expect(await playedListFrom(tester, 'Blue 1'), ['b1']);
      await teardownTree(tester);
    });

    testWidgets('offline with the chip off searches the whole library: '
        'remote songs are dimmed and their tap is blocked', (tester) async {
      await tester.pumpWidget(h.wrap(const SearchPage(), offline: true));
      await search(tester, 'Blue');
      await tester.tap(find.byKey(FilterBar.downloadedChipKey)); // OFF
      await tester.pumpAndSettle();
      expect(chip(tester).selected, isFalse);
      final remote = tester.widget<LibraryCard>(
        find.ancestor(
          of: find.text('Blue 2'),
          matching: find.byType(LibraryCard),
        ),
      );
      expect(remote.dimmed, isTrue);
      expect(remote.onTap, isNull);
      // The downloaded one still plays — just itself and the others the
      // list holds; the coordinator skips what it can't play.
      final local = tester.widget<LibraryCard>(
        find.ancestor(
          of: find.text('Blue 1'),
          matching: find.byType(LibraryCard),
        ),
      );
      expect(local.dimmed, isFalse);
      await teardownTree(tester);
    });

    testWidgets('the user turning the chip on re-runs downloaded-only', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(await playedListFrom(tester, 'Blue 1'), ['b1']);

      await search(tester, 'Nope');
      expect(
        inFeed(find.text('No downloaded results match "Nope".')),
        findsOneWidget,
      );
      await teardownTree(tester);
    });

    // 4A.3 copy: no "reconnect" advice (was 'No downloaded results match
    // "Blue". Reconnect to the server to search the full library.').
    testWidgets('offline, deleting the only downloaded match empties the '
        'results with the downloaded copy', (tester) async {
      await tester.pumpWidget(h.wrap(const SearchPage(), offline: true));
      await search(tester, 'Blue');
      expect(find.text('Blue 1'), findsOneWidget);

      await tester.runAsync(() => h.manager.deleteDownload('b1'));
      await tester.pumpAndSettle();
      expect(find.byType(TrackCard), findsNothing);
      expect(
        inFeed(find.text('No downloaded results match "Blue".')),
        findsOneWidget,
      );
      expect(find.textContaining('Reconnect'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('no match, chip off: "No results match"', (tester) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Nope');
      expect(inFeed(find.text('No results match "Nope".')), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('blank: the instruction, no rails or hints', (tester) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await tester.pumpAndSettle();
      expect(inFeed(find.text('Search your library')), findsOneWidget);
      expect(find.byType(LibraryCard), findsNothing);
      expect(find.textContaining('Showing the first'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('the clear button returns to the blank state immediately', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      expect(find.byType(TrackCard), findsWidgets);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pump(); // one frame — no debounce wait
      expect(find.byType(TrackCard), findsNothing);
      expect(fieldText(tester), isEmpty);
      expect(
        find.textContaining('No results match'),
        findsNothing,
        reason: 'cleared means out of search mode, not an empty search',
      );
      expect(inFeed(find.text('Search your library')), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('going offline mid-query re-runs it downloaded-only', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      expect(await playedListFrom(tester, 'Blue 1'), hasLength(7));

      h.offline.set(true);
      await tester.pumpAndSettle();
      expect(chip(tester).selected, isTrue);
      expect(find.byType(TrackCard), findsOneWidget);
      expect(find.text('Blue 1'), findsOneWidget);
      await teardownTree(tester);
    });

    // Whether the controller patches or re-searches is pinned by its unit
    // tests; this checks the page wiring delivers the event.
    testWidgets('online, a new download updates its card', (tester) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      TrackCard card() => tester.widget(
        find.ancestor(
          of: find.text('Blue 2'),
          matching: find.byType(TrackCard),
        ),
      );
      expect(card().track.isDownloaded, isFalse);

      await markDownloaded(libDb, 'b2');
      h.manager.downloadStatusVersion.value++;
      await tester.pumpAndSettle();
      expect(card().track.isDownloaded, isTrue);
      await teardownTree(tester);
    });

    testWidgets('rails are Artists, Albums, Songs in that order; empty types '
        'are omitted', (tester) async {
      await seedLibrary(libDb, [
        const SeedTrack(
          uuid: 'r1',
          title: 'Rhombus Song',
          artistId: 70,
          artist: 'Rhombus Artist',
          albumId: 70,
          album: 'Rhombus Album',
        ),
      ]);
      // Tall enough for all three rails (slivers build lazily).
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Rhombus');
      double y(String t) => tester.getTopLeft(inFeed(find.text(t))).dy;
      expect(y('Artists'), lessThan(y('Albums')));
      expect(y('Albums'), lessThan(y('Songs')));

      await search(tester, 'Blue'); // songs only
      expect(inFeed(find.text('Songs')), findsOneWidget);
      expect(inFeed(find.text('Artists')), findsNothing);
      expect(inFeed(find.text('Albums')), findsNothing);
      await teardownTree(tester);
    });

    // Audit 4A(a) m5: a new committed query's rails start at the beginning.
    testWidgets('a new query resets a rail scrolled for the previous one', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      final rail = find.byKey(
        const PageStorageKey<String>('feed.rail.search.songs'),
      );
      await tester.drag(rail, const Offset(-300, 0));
      await tester.pumpAndSettle();
      ScrollPosition pos() => tester
          .state<ScrollableState>(
            find.descendant(of: rail, matching: find.byType(Scrollable)).first,
          )
          .position;
      expect(pos().pixels, greaterThan(0));
      await search(tester, 'Blu');
      expect(pos().pixels, 0);
      await teardownTree(tester);
    });

    // Re-audit 4A #3/#6: every commit or filter change starts the rails at
    // their beginning, including a return to an earlier query.
    for (final change in ['earlier query again', 'chip toggle']) {
      testWidgets('rails restart after: $change', (tester) async {
        await tester.pumpWidget(h.wrap(const SearchPage()));
        await search(tester, 'Blue');
        final rail = find.byKey(
          const PageStorageKey<String>('feed.rail.search.songs'),
        );
        ScrollPosition pos() => tester
            .state<ScrollableState>(
              find
                  .descendant(of: rail, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        await tester.drag(rail, const Offset(-300, 0));
        await tester.pumpAndSettle();
        expect(pos().pixels, greaterThan(0));
        if (change == 'chip toggle') {
          // Same query; the filter changes twice (ON then OFF again).
          await tester.tap(find.byKey(FilterBar.downloadedChipKey));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(FilterBar.downloadedChipKey));
          await tester.pumpAndSettle();
        } else {
          await search(tester, 'Blu');
          await tester.drag(rail, const Offset(-300, 0));
          await tester.pumpAndSettle();
          await search(tester, 'Blue');
        }
        expect(pos().pixels, 0);
        await teardownTree(tester);
      });
    }

    testWidgets('never autofocuses; focusSearchField focuses it', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autofocus, isFalse);
      expect(field.focusNode!.hasFocus, isFalse);

      tester.state<SearchPageState>(find.byType(SearchPage)).focusSearchField();
      await tester.pump();
      expect(field.focusNode!.hasFocus, isTrue);
      await teardownTree(tester);
    });
  });

  group('state table (fake controller)', () {
    late AppDatabase libDb;
    late BrowseHarness h;
    late FakeLibrarySearchControls fake;

    setUp(() async {
      initCoverArtCache(CoverArtCacheManager.noop());
      libDb = AppDatabase(NativeDatabase.memory());
      h = await BrowseHarness.create(libDb);
    });

    tearDown(() async {
      await libDb.close();
      await h.dispose();
    });

    Future<void> pump(WidgetTester tester, {bool offline = false}) async {
      await tester.pumpWidget(
        h.wrap(
          const SearchPage(),
          offline: offline,
          overrides: [
            librarySearchControllerFactoryProvider.overrideWith(
              (ref) =>
                  ({
                    required types,
                    required limitPerType,
                    required downloadedOnly,
                  }) => fake = FakeLibrarySearchControls(
                    types: types,
                    limitPerType: limitPerType,
                    downloadedOnly: downloadedOnly,
                  ),
            ),
          ],
        ),
      );
      await tester.pump();
    }

    Finder inFeed(Finder f) =>
        find.descendant(of: find.byType(SectionedFeedView), matching: f);

    List<ArtistUI> artists(int n) => [
      for (var i = 0; i < n; i++) ArtistUI(id: i + 1, name: 'Ar $i'),
    ];
    List<AlbumUI> albums(int n) => [
      for (var i = 0; i < n; i++)
        AlbumUI(id: i + 1, name: 'Al $i', artistId: 1, artist: 'X'),
    ];
    List<TrackUI> tracks(int n) => [
      for (var i = 0; i < n; i++)
        TrackUI(
          uuidId: 't$i',
          createdAt: 0,
          lastUpdated: 0,
          revision: 1,
          title: 'So $i',
          duration: 1,
          bitrateKbps: null,
          sampleRateHz: 44100,
          channels: 2,
          hasAlbumArt: false,
        ),
    ];

    testWidgets('asks for all three types at 100 each', (tester) async {
      await pump(tester);
      expect(fake.types, SearchType.values.toSet());
      expect(fake.limitPerType, 100);
      await teardownTree(tester);
    });

    testWidgets('the controller reads the chip: offline starts it on', (
      tester,
    ) async {
      await pump(tester, offline: true);
      expect(fake.downloadedOnly(), isTrue);
      await teardownTree(tester);
    });

    for (final (type, noun) in [
      (SearchType.artists, 'artists'),
      (SearchType.albums, 'albums'),
      (SearchType.tracks, 'songs'),
    ]) {
      for (final n in [99, 100, 101]) {
        testWidgets('$noun: $n results ${n >= 100 ? 'shows' : 'no'} hint', (
          tester,
        ) async {
          await pump(tester);
          fake.show(
            query: 'q',
            results: (
              artists: type == SearchType.artists ? artists(n) : const [],
              albums: type == SearchType.albums ? albums(n) : const [],
              tracks: type == SearchType.tracks ? tracks(n) : const [],
            ),
          );
          await tester.pump();
          final hint = 'Showing the first 100 $noun — refine your search.';
          expect(find.text(hint), n >= 100 ? findsOneWidget : findsNothing);
          // Type-local: no other type's hint.
          expect(
            find.textContaining('Showing the first'),
            n >= 100 ? findsOneWidget : findsNothing,
          );
          await teardownTree(tester);
        });
      }
    }

    testWidgets('first query loading: progress, no no-result copy', (
      tester,
    ) async {
      await pump(tester);
      fake.show(query: 'q', searching: true);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('match'), findsNothing);
      expect(inFeed(find.text('Search your library')), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('updating: existing rails stay, with progress', (tester) async {
      await pump(tester);
      fake.show(
        query: 'q',
        results: (artists: artists(2), albums: const [], tracks: const []),
      );
      await tester.pump();
      fake.show(query: 'qq', searching: true);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Ar 0'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('a failure with kept results shows the error above them; '
        'Retry goes to the controller with the current chip', (tester) async {
      await pump(tester);
      fake.show(
        query: 'q',
        failed: true,
        results: (artists: artists(1), albums: const [], tracks: const []),
      );
      await tester.pump();
      expect(find.text(searchFailedMessage), findsOneWidget);
      expect(find.text('Ar 0'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      expect(fake.calls.last, 'retry downloadedOnly=false');
      await teardownTree(tester);
    });

    testWidgets('typed but not yet committed: no instruction, no copy', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'Blu');
      await tester.pump();
      expect(fake.calls.last, 'changed:Blu');
      expect(inFeed(find.text('Search your library')), findsNothing);
      expect(find.textContaining('match'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a chip tap re-runs with the new filter; download events '
        'reach the controller', (tester) async {
      await pump(tester);
      fake.show(query: 'q');
      await tester.pump();
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pump();
      expect(fake.calls.last, 'rerun downloadedOnly=true');
      h.manager.downloadStatusVersion.value++;
      await tester.pump();
      expect(fake.calls.last, 'downloads');
      await teardownTree(tester);
    });

    testWidgets('the controller is disposed with the page', (tester) async {
      await pump(tester);
      await teardownTree(tester);
      expect(fake.disposed, isTrue);
    });
  });
}

Future<void> _seedSearchData(AppDatabase db) async {
  await db.batch((batch) {
    batch.insert(
      db.artists,
      const ArtistsCompanion(id: Value(1), name: Value('Search Artist')),
    );
    batch.insert(
      db.albums,
      const AlbumsCompanion(
        id: Value(1),
        name: Value('Search Album'),
        artistId: Value(1),
        year: Value(2024),
        isSingleGrouping: Value(false),
      ),
    );
    batch.insert(
      db.tracks,
      const TracksCompanion(
        uuidId: Value('track-search-1'),
        createdAt: Value(1),
        lastUpdated: Value(1),
      ),
    );
    batch.insert(
      db.trackmetadata,
      const TrackmetadataCompanion(
        uuidId: Value('track-search-1'),
        title: Value('Search Song'),
        artist: Value('Search Artist'),
        album: Value('Search Album'),
        albumArtist: Value('Search Artist'),
        artistId: Value(1),
        albumId: Value(1),
        year: Value(2024),
        date: Value('2024-01-01'),
        genre: Value('Rock'),
        trackNumber: Value(1),
        discNumber: Value(1),
        codec: Value('flac'),
        duration: Value(180.0),
        bitrateKbps: Value(320.0),
        sampleRateHz: Value(44100),
        channels: Value(2),
        hasAlbumArt: Value(false),
      ),
    );
  });

  await db.rebuildFtsIndexes();
}

/// Throws while [fail], as a corrupt FTS index would.
class _FlakySearchRepo extends BrowseRepository {
  _FlakySearchRepo(super.db);

  bool fail = false;

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
    if (fail) throw StateError('fts index corrupt');
    return super.search(
      query,
      types: types,
      limitPerType: limitPerType,
      downloadedOnly: downloadedOnly,
    );
  }
}
