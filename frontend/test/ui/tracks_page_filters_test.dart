import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/library_search_field.dart';
import 'package:frontend/ui/widgets/search_status.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import 'browse_harness.dart';

void main() {
  late AppDatabase db;
  late BrowseHarness h;

  setUp(() async {
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    // One album holding a downloaded and a streaming-only track, so the same
    // seed serves both the root tab and the album-detail sub-route.
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'd1',
        title: 'Kept Song',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        downloaded: true,
      ),
      SeedTrack(
        uuid: 's1',
        title: 'Remote Song',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        trackNumber: 2,
      ),
    ]);
    h = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await db.close();
    await h.dispose();
  });

  FilterChip chip(WidgetTester tester) =>
      tester.widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey));

  TrackTile tileFor(WidgetTester tester, String title) => tester.widget(
    find.ancestor(of: find.text(title), matching: find.byType(TrackTile)),
  );

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    bool offline = false,
    AppInfo appInfo = const AppInfo(),
  }) async {
    await tester.pumpWidget(h.wrap(page, offline: offline, appInfo: appInfo));
    await tester.pumpAndSettle();
  }

  Future<void> tapChip(WidgetTester tester) async {
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    await tester.pumpAndSettle();
  }

  Future<void> setOffline(WidgetTester tester, bool value) async {
    h.offline.set(value);
    await tester.pumpAndSettle();
  }

  const root = TracksPage(isRoot: true);
  const detail = Scaffold(body: TracksPage(artistId: 1, albumId: 10));

  CursorPaginationMixin<TrackUI> pageState(WidgetTester tester) =>
      tester.state(find.byType(TracksPage)) as CursorPaginationMixin<TrackUI>;

  group('root Tracks tab', () {
    testWidgets('online: chip off lists everything undimmed; on filters', (
      tester,
    ) async {
      await pump(tester, root);

      expect(chip(tester).selected, isFalse);
      expect(find.text('Kept Song'), findsOneWidget);
      expect(find.text('Remote Song'), findsOneWidget);
      expect(tileFor(tester, 'Remote Song').isDimmed, isFalse);

      await tapChip(tester);
      expect(find.text('Kept Song'), findsOneWidget);
      expect(find.text('Remote Song'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('offline: the chip switches on and filters (not dims)', (
      tester,
    ) async {
      await pump(tester, root, offline: true);

      expect(chip(tester).selected, isTrue);
      expect(find.text('Kept Song'), findsOneWidget);
      expect(
        find.text('Remote Song'),
        findsNothing,
        reason: 'the Tracks tab now filters offline instead of dimming',
      );
      await teardownTree(tester);
    });

    testWidgets('offline: chip off shows the full library, unplayable dimmed', (
      tester,
    ) async {
      await pump(tester, root, offline: true);
      expect(chip(tester).onSelected, isNotNull, reason: 'not locked');

      await tapChip(tester);
      expect(chip(tester).selected, isFalse);
      expect(find.text('Remote Song'), findsOneWidget);
      expect(tileFor(tester, 'Remote Song').isDimmed, isTrue);
      expect(tileFor(tester, 'Remote Song').isInteractive, isFalse);
      expect(tileFor(tester, 'Kept Song').isDimmed, isFalse);
      await teardownTree(tester);
    });

    testWidgets('the play queue follows the effective filter', (tester) async {
      await pump(tester, root);

      await tester.tap(find.text('Kept Song'));
      await tester.pumpAndSettle();
      expect(h.audio.calls.last, containsPair('downloadedOnly', false));

      await tapChip(tester);
      await tester.tap(find.text('Kept Song'));
      await tester.pumpAndSettle();
      expect(h.audio.calls.last, containsPair('method', 'playFromQueue'));
      expect(h.audio.calls.last, containsPair('downloadedOnly', true));
      await teardownTree(tester);
    });

    testWidgets('offline round trip restores the pre-offline choice', (
      tester,
    ) async {
      await pump(tester, root);

      await setOffline(tester, true);
      expect(chip(tester).selected, isTrue);
      expect(find.text('Remote Song'), findsNothing);
      await setOffline(tester, false);
      expect(chip(tester).selected, isFalse);
      expect(find.text('Remote Song'), findsOneWidget);

      await tapChip(tester);
      await setOffline(tester, true);
      await setOffline(tester, false);
      expect(chip(tester).selected, isTrue);
      expect(find.text('Remote Song'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('switching the chip off offline survives reconnecting', (
      tester,
    ) async {
      await pump(tester, root, offline: true);
      await tapChip(tester);

      await setOffline(tester, false);
      expect(chip(tester).selected, isFalse);
      expect(find.text('Remote Song'), findsOneWidget);
      await teardownTree(tester);
    });
  });

  group('album-detail sub-route (unchanged)', () {
    testWidgets('offline: no FilterBar; streaming-only rows stay, dimmed', (
      tester,
    ) async {
      await pump(tester, detail, offline: true);

      expect(find.byType(FilterBar), findsNothing);
      expect(find.text('Remote Song'), findsOneWidget);
      expect(tileFor(tester, 'Remote Song').isDimmed, isTrue);
      expect(tileFor(tester, 'Kept Song').isDimmed, isFalse);
      await teardownTree(tester);
    });

    testWidgets('a row tap never forces a downloaded-only queue', (
      tester,
    ) async {
      await pump(tester, detail);

      await tester.tap(find.text('Remote Song'));
      await tester.pumpAndSettle();
      expect(h.audio.calls.single, containsPair('downloadedOnly', false));
      expect(h.audio.calls.single, containsPair('sourceType', 'album'));
      await teardownTree(tester);
    });
  });

  group('filtered empty state', () {
    const message = 'No downloaded tracks yet.';

    Future<void> clearAllDownloads() async {
      await db.update(db.tracks).write(clearedDownloadColumns);
    }

    Future<void> clearLibrary() async {
      for (final t in ['trackmetadata', 'tracks', 'albums', 'artists']) {
        await db.customStatement('DELETE FROM $t');
      }
    }

    testWidgets('root: shown once a filtered window settles empty', (
      tester,
    ) async {
      await clearAllDownloads();
      await tester.pumpWidget(h.wrap(root, offline: true));
      expect(find.text(message), findsNothing, reason: 'still loading');

      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('root: not shown for an unfiltered empty library', (
      tester,
    ) async {
      await clearLibrary();
      await pump(tester, root);
      expect(find.text(message), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('detail: never shown (it dims rather than filters)', (
      tester,
    ) async {
      await clearAllDownloads();
      await pump(tester, detail, offline: true);
      expect(find.text(message), findsNothing);
      expect(find.text('Remote Song'), findsOneWidget);
      await teardownTree(tester);
    });
  });

  group('in-page search', () {
    Future<void> search(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
    }

    testWidgets('root shows a search field', (tester) async {
      await pump(tester, root);
      expect(find.widgetWithText(TextField, 'Search tracks'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('album detail shows no search field', (tester) async {
      await pump(tester, detail);
      expect(find.byType(TextField), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a query swaps the list for results and suspends browse', (
      tester,
    ) async {
      await pump(tester, root);
      await search(tester, 'Kept');

      expect(find.text('Kept Song'), findsOneWidget);
      expect(find.text('Remote Song'), findsNothing);
      expect(pageState(tester).isPaginationSuspended, isTrue);

      final dormant = List.of(pageState(tester).paginatedItems);
      await seedLibrary(db, const [
        SeedTrack(uuid: 'n1', title: 'Kept New', artistId: 1, artist: 'Artist'),
      ]);
      await tester.pumpAndSettle();
      expect(pageState(tester).paginatedItems, dormant);
      await teardownTree(tester);
    });

    testWidgets('clearing resumes browse from a fresh window', (tester) async {
      await pump(tester, root);
      await search(tester, 'Kept');
      // Written while browse sleeps: only a re-subscribed window shows it.
      await seedLibrary(db, const [
        SeedTrack(uuid: 'n1', title: 'New Song', artistId: 1, artist: 'Artist'),
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(pageState(tester).isPaginationSuspended, isFalse);
      expect(find.text('Kept Song'), findsOneWidget);
      expect(find.text('Remote Song'), findsOneWidget);
      expect(find.text('New Song'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('deleting the text (not the clear button) also returns to '
        'browse', (tester) async {
      await pump(tester, root);
      await search(tester, 'Kept');
      await search(tester, '');
      expect(pageState(tester).isPaginationSuspended, isFalse);
      expect(find.text('Remote Song'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('a chip toggled during search still applies after clearing', (
      tester,
    ) async {
      await pump(tester, root);
      await search(tester, 'Song');
      await tapChip(tester);
      expect(find.text('Remote Song'), findsNothing, reason: 'search re-ran');

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(chip(tester).selected, isTrue);
      expect(find.text('Kept Song'), findsOneWidget);
      expect(find.text('Remote Song'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('going offline during search still applies after clearing', (
      tester,
    ) async {
      await pump(tester, root);
      await search(tester, 'Song');
      await setOffline(tester, true);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(chip(tester).selected, isTrue);
      expect(find.text('Remote Song'), findsNothing);

      await setOffline(tester, false);
      expect(chip(tester).selected, isFalse);
      expect(find.text('Remote Song'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('the keyboard search action searches without the debounce', (
      tester,
    ) async {
      await pump(tester, root);
      await tester.showKeyboard(find.byType(TextField));
      tester.testTextInput.enterText('Kept');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle(); // no debounce-length pump
      expect(find.text('Remote Song'), findsNothing);
      expect(find.text('Kept Song'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('a spinner, not the no-match copy, until the first results '
        'land', (tester) async {
      final repo = _GatedSearchRepo(db);
      await tester.pumpWidget(h.wrap(root, repository: repo));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Kept');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('match'), findsNothing);

      repo.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Kept Song'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('a failed search says so instead of "No tracks match"', (
      tester,
    ) async {
      await tester.pumpWidget(
        h.wrap(root, repository: _GatedSearchRepo(db, fail: true)),
      );
      await tester.pumpAndSettle();
      await search(tester, 'Kept');
      expect(find.text(searchFailedMessage), findsOneWidget);
      expect(find.textContaining('No tracks match'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('no match explains itself, naming the Downloaded filter', (
      tester,
    ) async {
      await pump(tester, root);
      await search(tester, 'Nope');
      expect(find.text('No tracks match "Nope".'), findsOneWidget);

      await search(tester, 'Remote');
      await tapChip(tester);
      expect(find.text('No downloaded tracks match "Remote".'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('chip toggles and offline flips re-run the search', (
      tester,
    ) async {
      await pump(tester, root);
      await search(tester, 'Song');
      expect(find.text('Remote Song'), findsOneWidget);

      await tapChip(tester);
      expect(find.text('Remote Song'), findsNothing);
      await tapChip(tester);
      expect(find.text('Remote Song'), findsOneWidget);

      await setOffline(tester, true);
      expect(find.text('Remote Song'), findsNothing);
      expect(find.text('Kept Song'), findsOneWidget);
      expect(pageState(tester).isPaginationSuspended, isTrue);

      // Offline search can still cover the full library; rows that can't
      // play are dimmed, as in browse mode.
      await tapChip(tester);
      expect(find.text('Remote Song'), findsOneWidget);
      expect(tileFor(tester, 'Remote Song').isDimmed, isTrue);
      await teardownTree(tester);
    });

    testWidgets('online + unfiltered: a new download patches its row', (
      tester,
    ) async {
      await pump(tester, root);
      await search(tester, 'Song');
      expect(tileFor(tester, 'Remote Song').track.isDownloaded, isFalse);

      await markDownloaded(db, 's1');
      h.manager.downloadStatusVersion.value++;
      await tester.pumpAndSettle();
      expect(tileFor(tester, 'Remote Song').track.isDownloaded, isTrue);
      await teardownTree(tester);
    });

    testWidgets('filtered: a deleted download drops out of the results', (
      tester,
    ) async {
      await pump(tester, root);
      await tapChip(tester);
      await search(tester, 'Song');
      expect(find.text('Kept Song'), findsOneWidget);

      // Real file I/O: must run outside the widget test's fake-async zone.
      await tester.runAsync(() => h.manager.deleteDownload('d1'));
      await tester.pumpAndSettle();
      expect(find.text('Kept Song'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('tapping a result plays the result list in order', (
      tester,
    ) async {
      await pump(tester, root);
      await search(tester, 'Song');
      final shown = tester
          .widgetList<TrackTile>(find.byType(TrackTile))
          .map((t) => t.track.uuidId)
          .toList();

      await tester.tap(find.text('Remote Song'));
      await tester.pumpAndSettle();
      expect(h.audio.calls.last, {
        'method': 'playFromTrackList',
        'uuids': shown,
        'uuid': 's1',
        'sourceType': 'search',
      });
      await teardownTree(tester);
    });

    testWidgets('a full page of matches is capped at 100 with a hint', (
      tester,
    ) async {
      await seedLibrary(db, [
        for (var i = 0; i < 105; i++)
          SeedTrack(
            uuid: 'm$i',
            title: 'Many $i',
            artistId: 2,
            artist: 'Other',
            trackNumber: i,
          ),
      ]);
      await pump(tester, root);
      await search(tester, 'Many');

      final list = tester.widget<ListView>(find.byType(ListView));
      final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
      expect(delegate.childCount, 100);
      expect(find.textContaining('Showing the first 100 matches'), findsOne);
      await teardownTree(tester);
    });

    testWidgets('search rows keep the Convert… action online, not offline', (
      tester,
    ) async {
      const convertible = AppInfo(
        entities: {
          'track': EntityInfo(actions: ['convert']),
        },
        conversion: ConversionCapabilities(
          targets: [ConversionTargetInfo(codec: 'aac', isLossless: false)],
          bitratePresets: [256],
        ),
      );
      Future<void> openMenu(String title) async {
        await tester.tap(
          find.descendant(
            of: find.ancestor(
              of: find.text(title),
              matching: find.byType(TrackTile),
            ),
            matching: find.byIcon(Icons.more_vert),
          ),
        );
        await tester.pumpAndSettle();
      }

      // The same (downloaded, so tappable offline) row both times: only
      // offline mode may hide the action.
      await pump(tester, root, appInfo: convertible);
      await search(tester, 'Song');
      await openMenu('Kept Song');
      expect(find.text('Convert…'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5)); // dismiss the sheet
      await tester.pumpAndSettle();

      await setOffline(tester, true);
      await openMenu('Kept Song');
      expect(find.text('Play Next'), findsOneWidget, reason: 'menu is open');
      expect(find.text('Convert…'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await teardownTree(tester);
    });

    testWidgets('offline with the chip off, a dimmed result cannot start '
        'playback; a downloaded one plays the full result list', (
      tester,
    ) async {
      await pump(tester, root);
      await search(tester, 'Song');
      await setOffline(tester, true);
      await tapChip(tester); // off: the full library, from local metadata
      expect(chip(tester).selected, isFalse);
      expect(tileFor(tester, 'Remote Song').isInteractive, isFalse);

      await tester.tap(find.text('Remote Song'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(h.audio.calls, isEmpty);

      await tester.tap(find.text('Kept Song'));
      await tester.pumpAndSettle();
      // The stored list may hold streaming-only uuids; the real coordinator
      // skips them offline (`_startSessionWithOfflinePolicy`).
      expect(h.audio.calls.single['uuid'], 'd1');
      expect(h.audio.calls.single['uuids'], unorderedEquals(['d1', 's1']));
      await teardownTree(tester);
    });

    testWidgets('unmounting with a pending debounce leaks nothing', (
      tester,
    ) async {
      await pump(tester, root);
      await tester.enterText(find.byType(TextField), 'Kep');
      await teardownTree(tester);
    });
  });

  group('browse list restarts', () {
    testWidgets('a chip toggle while scrolled deep restarts at the top, not '
        'at a load-more spinner that never loads', (tester) async {
      await seedLibrary(db, [
        for (var i = 0; i < 200; i++)
          SeedTrack(
            uuid: 'bulk$i',
            title: 'Bulk ${i.toString().padLeft(3, '0')}',
            artistId: 2,
            artist: 'Bulk Artist',
            trackNumber: i + 1,
            downloaded: i.isEven,
          ),
      ]);
      await pump(tester, root);
      final list = find.byType(ListView);
      for (var i = 0; i < 12; i++) {
        await tester.drag(list, const Offset(0, -2000));
        await tester.pumpAndSettle();
      }
      final state = pageState(tester);
      expect(state.paginatedItems.length, greaterThan(100));
      expect(state.scrollController.offset, greaterThan(5000));

      await tapChip(tester);
      expect(state.scrollController.offset, 0);
      expect(state.paginatedItems.length, 50);
      // Scrolling still pages in more.
      await tester.drag(list, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(state.paginatedItems.length, greaterThan(50));
      await teardownTree(tester);
    });

    testWidgets('going offline with the chip already on keeps the list as '
        'is (no needless re-fetch)', (tester) async {
      await pump(tester, root);
      await tapChip(tester);
      final before = pageState(tester).paginatedItems;
      await setOffline(tester, true);
      expect(chip(tester).selected, isTrue);
      expect(identical(pageState(tester).paginatedItems, before), isTrue);
      await teardownTree(tester);
    });

    testWidgets('created offline and untouched: reconnecting switches the '
        'chip off and shows everything', (tester) async {
      await pump(tester, root, offline: true);
      expect(chip(tester).selected, isTrue);
      expect(find.text('Remote Song'), findsNothing);

      await setOffline(tester, false);
      expect(chip(tester).selected, isFalse);
      expect(find.text('Remote Song'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('filtered: deleting the last download shows the empty copy', (
      tester,
    ) async {
      await pump(tester, root);
      await tapChip(tester);
      expect(find.text('Kept Song'), findsOneWidget);

      await tester.runAsync(() => h.manager.deleteDownload('d1'));
      await tester.pumpAndSettle();
      expect(find.text('No downloaded tracks yet.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('the chip bar lines up with the search field, not centred', (
      tester,
    ) async {
      await pump(tester, root);
      final chipLeft = tester
          .getTopLeft(find.byKey(FilterBar.downloadedChipKey))
          .dx;
      final fieldLeft = tester.getTopLeft(find.byType(LibrarySearchField)).dx;
      expect((chipLeft - fieldLeft).abs(), lessThan(8));
      await teardownTree(tester);
    });
  });
}

/// The real repository, except [search] waits for [gate] (or throws).
class _GatedSearchRepo extends BrowseRepository {
  _GatedSearchRepo(super.db, {this.fail = false});

  final bool fail;
  final gate = Completer<void>();

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
    await gate.future;
    return super.search(
      query,
      types: types,
      limitPerType: limitPerType,
      downloadedOnly: downloadedOnly,
    );
  }
}
