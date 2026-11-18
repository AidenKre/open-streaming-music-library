// Phase 9A.2b (spec §4 paras 2–3, §2 "Top tracks/artists/albums", §3 para
// 3; SC-05, SC-06, SC-26; decision O13; review 9-U03, 9-U11): the top lists
// on the statistics page, rendered from `ListeningStatsControls.topLists`.
//
//  * Three titled lists of Phase 4 cards, each with its rank and the
//    snapshot's listening time (the one formatter, rounded down) and
//    qualified plays; no percentage anywhere (O13: none without a stated
//    denominator).
//  * Same-title tracks are two cards, told apart by uuid.
//  * Taps: a track asks the controller to play it (nothing else is
//    requested); an album or artist opens its detail page.
//  * An unavailable card keeps its rank and numbers, is not tappable and has
//    no menu; the page prompts a refresh.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';

import '../browse_harness.dart' show teardownTree;
import 'top_lists_fixtures.dart';

void main() {
  late TopListsHarness h;
  setUp(() async {
    h = TopListsHarness();
    await h.setUp();
  });
  tearDown(() => h.tearDown());

  List<String> texts(WidgetTester tester, Finder root) => [
    for (final t in tester.widgetList<Text>(
      find.descendant(of: root, matching: find.byType(Text)),
    ))
      t.data ?? t.textSpan?.toPlainText() ?? '',
  ];

  testWidgets('three titled lists in snapshot order, each card with its rank '
      'and numbers', (tester) async {
    await h.open(tester, lists());
    for (final (id, title) in [
      ('tracks', 'Top tracks'),
      ('artists', 'Top artists'),
      ('albums', 'Top albums'),
    ]) {
      expect(find.descendant(of: section(id), matching: find.text(title)),
          findsOneWidget, reason: id);
    }
    expect(inCard('track:t-b', '#1'), findsOneWidget);
    expect(inCard('track:t-b', '1 h 1 min · 4 qualified plays'),
        findsOneWidget);
    expect(inCard('track:t-a', '#2'), findsOneWidget);
    expect(inCard('track:t-a', 'Under 1 min · 1 qualified play'),
        findsOneWidget);
    expect(inCard('artist:2', '#1'), findsOneWidget);
    expect(inCard('artist:1', 'Under 1 min · 1 qualified play'),
        findsOneWidget);
    expect(inCard('album:20', '1 h 1 min · 4 qualified plays'),
        findsOneWidget);
    // Snapshot order within a list.
    final tracks = texts(tester, section('tracks'));
    expect(tracks.indexOf('#1'), lessThan(tracks.indexOf('#2')));
    expect(tester.getTopLeft(cardOf('track:t-b')).dx,
        lessThan(tester.getTopLeft(cardOf('track:t-a')).dx));
    await teardownTree(tester);
  });

  testWidgets('same-title tracks are two cards, one per uuid', (tester) async {
    await h.open(tester, lists());
    expect(cardOf('track:t-a'), findsOneWidget);
    expect(cardOf('track:t-b'), findsOneWidget);
    expect(find.descendant(of: section('tracks'), matching: find.text('Same')),
        findsNWidgets(2));
    await teardownTree(tester);
  });

  testWidgets('no percentage is shown', (tester) async {
    await h.open(tester, lists());
    final all = texts(tester, find.byKey(const ValueKey('stats-content')));
    expect(all.where((t) => t.contains('%')), isEmpty);
    await teardownTree(tester);
  });

  testWidgets('a track tap asks the controller to play that one track; '
      'nothing else is requested', (tester) async {
    await h.open(tester, lists());
    expect(h.fake.played, isEmpty);
    await tester.tap(inCard('track:t-b', 'Same'));
    await tester.pumpAndSettle();
    expect(h.fake.played, ['t-b']);
    expect(h.browse.audio.calls, isEmpty,
        reason: 'the page submits nothing itself');
    await teardownTree(tester);
  });

  // Owner decision 5 (2026-11-17), APP-OTHER-1 D5: a track tap whose
  // playback does not start shows the playback message as a notice.
  testWidgets('a track tap that does not start playback says so', (
    tester,
  ) async {
    h.fake.playOutcome = Failed(StateError('x'));
    await h.open(tester, lists());
    expect(find.text("Couldn't start playback."), findsNothing);
    await tester.tap(inCard('track:t-b', 'Same'));
    await tester.pumpAndSettle();
    expect(h.fake.played, ['t-b']);
    expect(find.text("Couldn't start playback."), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('an album tap opens the album', (tester) async {
    await h.open(tester, lists());
    await tester.tap(inCard('album:10', 'One'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'One'), findsOneWidget);
    expect(h.fake.played, isEmpty);
    expect(h.browse.audio.calls, isEmpty);
    await teardownTree(tester);
  });

  testWidgets('an artist tap opens the artist', (tester) async {
    await h.open(tester, lists());
    await tester.tap(inCard('artist:2', 'Bea'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Bea'), findsOneWidget);
    expect(h.browse.audio.calls, isEmpty);
    await teardownTree(tester);
  });

  testWidgets('a track card carries the shared menu (Get Info)',
      (tester) async {
    await h.open(tester, lists());
    await tester.longPress(inCard('track:t-b', 'Same'));
    await tester.pumpAndSettle();
    expect(find.text('Get Info'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('an unavailable card keeps its rank and numbers, says so, does '
      'not play and has no menu', (tester) async {
    await h.open(tester, lists(tAUnavailable: true));
    expect(inCard('track:t-a', '#2'), findsOneWidget);
    expect(inCard('track:t-a', 'Under 1 min · 1 qualified play'),
        findsOneWidget);
    expect(inCard('track:t-a', 'No longer available'), findsOneWidget);
    expect(opacityOf(tester, 'track:t-a'), lessThan(1));
    await tester.tap(inCard('track:t-a', 'Same'));
    await tester.pumpAndSettle();
    expect(h.fake.played, isEmpty);
    await tester.longPress(inCard('track:t-a', 'Same'));
    await tester.pumpAndSettle();
    expect(find.text('Get Info'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('an unavailable card prompts a refresh', (tester) async {
    await h.open(tester, lists(tAUnavailable: true));
    expect(find.text('Some items are no longer available'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Refresh').first);
    await tester.pump();
    expect(h.fake.refreshes, 1);
    await teardownTree(tester);
  });

  testWidgets('with nothing unavailable there is no such prompt',
      (tester) async {
    await h.open(tester, lists());
    expect(find.text('Some items are no longer available'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('one notice at a time: a history change wins over the '
      'unavailable prompt', (tester) async {
    await h.open(tester, lists(tAUnavailable: true));
    h.fake.show(h.fake.state, notice: SnapshotStaleness.historyChanged);
    await tester.pumpAndSettle();
    expect(find.text('This page is out of date.'), findsOneWidget);
    expect(find.text('Some items are no longer available'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('an empty list says none in this range', (tester) async {
    await h.open(tester, emptyLists);
    for (final id in ['tracks', 'artists', 'albums']) {
      expect(
          find.descendant(
              of: section(id), matching: find.text('None in this range.')),
          findsOneWidget,
          reason: id);
    }
    await teardownTree(tester);
  });

  testWidgets('loading and failed states show no top lists', (tester) async {
    await h.open(tester, null, state: const StatsLoading());
    expect(section('tracks'), findsNothing);
    h.fake.show(const StatsFailed());
    await tester.pumpAndSettle();
    expect(section('tracks'), findsNothing);
    await teardownTree(tester);
  });
}
