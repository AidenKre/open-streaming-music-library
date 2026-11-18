import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import 'browse_harness.dart';
import 'fake_library_actions.dart';
import 'fake_track_selection_controls.dart';
import '../helpers/library_seed.dart' show SeedTrack, seedLibrary;

/// SC-17 selection mode on the Tracks browse body (8-U07 selection, 8-U09).
void main() {
  late AppDatabase db;
  late BrowseHarness h;
  late FakeTrackSelectionControls selection;
  late FakeLibraryActions actions;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'd1',
        title: 'Kept Song',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        downloaded: true,
        revision: 4,
      ),
      SeedTrack(
        uuid: 's1',
        title: 'Remote Song',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        trackNumber: 2,
        revision: 7,
      ),
    ]);
    h = await BrowseHarness.create(db);
    selection = FakeTrackSelectionControls();
    actions = FakeLibraryActions();
  });

  tearDown(() async {
    selection.dispose();
    await db.close();
    await h.dispose();
  });

  Future<void> pump(
    WidgetTester tester, {
    bool offline = false,
    bool selectionMode = true,
  }) async {
    await tester.pumpWidget(
      h.wrap(
        Scaffold(
          body: selectionMode
              ? TracksPage(browseAll: true, selection: selection)
              : const TracksPage(browseAll: true),
        ),
        offline: offline,
        overrides: [libraryActionsProvider.overrideWithValue(actions)],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  Finder rowOf(String title) =>
      find.ancestor(of: find.text(title), matching: find.byType(TrackTile));

  bool? checked(WidgetTester tester, String title) => tester
      .widget<Checkbox>(
        find.descendant(of: rowOf(title), matching: find.byType(Checkbox)),
      )
      .value;

  List<(String, int?)> pairs() => [
    for (final e in selection.selection.entries) (e.uuid, e.baseRevision),
  ];

  /// Nothing reached playback: no library action and no request.
  void expectNothingPlayed() {
    expect(actions.calls, isEmpty, reason: 'no libraryActions call');
    expect(h.audio.calls, isEmpty, reason: 'no PlaybackRequests.submit');
  }

  CursorPaginationMixin<TrackUI> pageState(WidgetTester tester) =>
      tester.state(find.byType(TracksPage)) as CursorPaginationMixin<TrackUI>;

  group('browse rows', () {
    testWidgets('a tap toggles the row with its revision and never plays', (
      tester,
    ) async {
      await pump(tester);
      expect(checked(tester, 'Remote Song'), isFalse);

      await tester.tap(find.text('Remote Song'));
      await tester.pumpAndSettle();
      expect(selection.calls, ['toggle s1']);
      expect(pairs(), [('s1', 7)]);
      expect(checked(tester, 'Remote Song'), isTrue);
      expect(checked(tester, 'Kept Song'), isFalse);

      await tester.tap(find.text('Remote Song'));
      await tester.pumpAndSettle();
      expect(selection.count, 0);
      expect(checked(tester, 'Remote Song'), isFalse);
      expectNothingPlayed();
      await teardownTree(tester);
    });

    testWidgets('every row has a checkbox and no action menu', (tester) async {
      await pump(tester);
      expect(find.byType(Checkbox), findsNWidgets(2));
      expect(find.byIcon(Icons.more_vert), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('offline, a row that cannot play is still selectable', (
      tester,
    ) async {
      await pump(tester, offline: true);
      // The chip switches on offline; off shows the unplayable row.
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      final tile = tester.widget<TrackTile>(rowOf('Remote Song'));
      expect(tile.isInteractive, isTrue);
      expect(tile.isDimmed, isFalse);

      await tester.tap(find.text('Remote Song'));
      await tester.pumpAndSettle();
      expect(pairs(), [('s1', 7)]);
      expect(checked(tester, 'Remote Song'), isTrue);
      expectNothingPlayed();
      await teardownTree(tester);
    });

    testWidgets('normal browse mode shows no checkbox and still plays', (
      tester,
    ) async {
      await pump(tester, selectionMode: false);
      expect(find.byType(Checkbox), findsNothing);
      await tester.tap(find.text('Kept Song'));
      await tester.pumpAndSettle();
      expect(actions.calls.single, startsWith('playQuery d1'));
      expect(selection.calls, isEmpty);
      await teardownTree(tester);
    });
  });

  // Owner decision 5 (2026-11-17), APP-OTHER-1 D5: a row tap whose playback
  // does not start shows the playback message as a short notice.
  group('a row tap that does not start playback says so', () {
    testWidgets('a browse row', (tester) async {
      actions.playOutcome = Failed(StateError('x'));
      await pump(tester, selectionMode: false);
      expect(find.text("Couldn't start playback."), findsNothing);
      await tester.tap(find.text('Kept Song'));
      await tester.pumpAndSettle();
      expect(actions.calls.single, startsWith('playQuery d1'));
      expect(find.text("Couldn't start playback."), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('an in-page search result row', (tester) async {
      actions.playOutcome = const RejectedUnplayableOffline();
      await pump(tester, selectionMode: false);
      await search(tester, 'Remote');
      expect(find.text('Nothing here plays offline.'), findsNothing);
      await tester.tap(find.text('Remote Song'));
      await tester.pumpAndSettle();
      expect(actions.calls.single, 'playFromList s1 @0 search');
      expect(find.text('Nothing here plays offline.'), findsOneWidget);
      await teardownTree(tester);
    });
  });

  group('the selection survives', () {
    testWidgets('growth of the browse window', (tester) async {
      await seedLibrary(db, [
        for (var i = 0; i < 200; i++)
          SeedTrack(
            uuid: 'bulk$i',
            title: 'Bulk ${i.toString().padLeft(3, '0')}',
            artistId: 2,
            artist: 'Bulk Artist',
            trackNumber: i + 1,
          ),
      ]);
      await pump(tester);
      final first = tester.widgetList<TrackTile>(find.byType(TrackTile)).first;
      final firstTitle = first.track.title!;
      await tester.tap(find.text(firstTitle));
      await tester.pumpAndSettle();
      expect(pageState(tester).paginatedItems.length, 50);

      for (var i = 0; i < 12; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -2000));
        await tester.pumpAndSettle();
      }
      expect(pageState(tester).paginatedItems.length, greaterThan(100));
      final deep = tester.widgetList<TrackTile>(find.byType(TrackTile)).last;
      await tester.tap(find.text(deep.track.title!));
      await tester.pumpAndSettle();
      expect(selection.selection.entries.map((e) => e.uuid), [
        first.track.uuidId,
        deep.track.uuidId,
      ]);

      pageState(tester).scrollController.jumpTo(0);
      await tester.pumpAndSettle();
      expect(checked(tester, firstTitle), isTrue);
      expectNothingPlayed();
      await teardownTree(tester);
    });

    testWidgets('a query change, and search rows toggle without playing', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('Kept Song'));
      await tester.pumpAndSettle();

      await search(tester, 'Remote');
      expect(find.text('Kept Song'), findsNothing);
      expect(checked(tester, 'Remote Song'), isFalse);
      await tester.tap(find.text('Remote Song'));
      await tester.pumpAndSettle();
      expect(checked(tester, 'Remote Song'), isTrue);

      await search(tester, 'Kept');
      expect(checked(tester, 'Kept Song'), isTrue);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(checked(tester, 'Kept Song'), isTrue);
      expect(checked(tester, 'Remote Song'), isTrue);
      expect(pairs(), [('d1', 4), ('s1', 7)]);
      expect(selection.calls, ['toggle d1', 'toggle s1']);
      expectNothingPlayed();
      await teardownTree(tester);
    });

    testWidgets('until clear, which unchecks every row', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Kept Song'));
      await tester.tap(find.text('Remote Song'));
      await tester.pumpAndSettle();
      expect(selection.count, 2);

      // The owning page's Clear selection.
      selection.clear();
      await tester.pumpAndSettle();
      expect(checked(tester, 'Kept Song'), isFalse);
      expect(checked(tester, 'Remote Song'), isFalse);
      expect(selection.count, 0);
      await teardownTree(tester);
    });
  });

  testWidgets('search keeps the 100 cap and its hint', (tester) async {
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
    await pump(tester);
    await search(tester, 'Many');

    final list = tester.widget<ListView>(find.byType(ListView));
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 100);
    expect(
      find.text('Showing the first 100 tracks — refine your search.'),
      findsOne,
    );
    expect(find.byType(Checkbox), findsWidgets);
    await teardownTree(tester);
  });

  // Boundary of the cap rule (`count >= limitPerType`): 99 matches fit under
  // the cap and show no hint; exactly 100 is "full" and shows it; 101 is
  // trimmed to 100 and shows it.
  for (final (matches, rows, hint) in [
    (99, 99, false),
    (100, 100, true),
    (101, 100, true),
  ]) {
    testWidgets('search with $matches matches shows $rows rows, '
        'hint ${hint ? 'shown' : 'hidden'}', (tester) async {
      await seedLibrary(db, [
        for (var i = 0; i < matches; i++)
          SeedTrack(
            uuid: 'b$i',
            title: 'Bound $i',
            artistId: 2,
            artist: 'Other',
            trackNumber: i,
          ),
      ]);
      await pump(tester);
      await search(tester, 'Bound');

      final list = tester.widget<ListView>(find.byType(ListView));
      final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
      expect(delegate.childCount, rows);
      expect(
        find.text('Showing the first 100 tracks — refine your search.'),
        hint ? findsOne : findsNothing,
      );
      expect(find.byType(Checkbox), findsWidgets);
      await teardownTree(tester);
    });
  }

  // Other-issues row 81 (U29-A-13): what the picker shows, not a search of
  // source files. Manage library adds deletion around this list; the list
  // itself (rows, selection, search results) offers no deletion control or
  // wording.
  testWidgets('selection mode shows no deletion control or wording', (
    tester,
  ) async {
    void expectNoDeletion(String when) {
      final texts = [
        for (final t in tester.widgetList<Text>(find.byType(Text)))
          (t.data ?? t.textSpan?.toPlainText() ?? '').toLowerCase(),
        for (final t in tester.widgetList<RichText>(find.byType(RichText)))
          t.text.toPlainText().toLowerCase(),
      ];
      expect(texts.where((t) => t.contains('delet')), isEmpty, reason: when);
      for (final icon in [
        Icons.delete,
        Icons.delete_outline,
        Icons.delete_forever,
        Icons.delete_sweep,
      ]) {
        expect(find.byIcon(icon), findsNothing, reason: '$when: $icon');
      }
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Tooltip &&
              (w.message ?? '').toLowerCase().contains('delet'),
        ),
        findsNothing,
        reason: when,
      );
    }

    await pump(tester);
    expect(find.byType(Checkbox), findsNWidgets(2));
    expectNoDeletion('rows');
    await tester.tap(find.text('Remote Song'));
    await tester.pumpAndSettle();
    expectNoDeletion('a row selected');
    await search(tester, 'Song');
    expect(find.byType(Checkbox), findsWidgets);
    expectNoDeletion('search results');
    await teardownTree(tester);
  });
}
