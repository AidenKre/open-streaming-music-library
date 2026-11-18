// Phase 9A.2b (spec §3 para 5, §4 paras 2–3; SC-10, SC-26; review 9-S06
// unit half, 9-U03): the "See all" ranking page renders only what
// `ListeningRankingControls` says, and the statistics page opens it with
// its own snapshot token.
//
//  * States: loading, a page (more to come), the last page, expired
//    (loaded cards kept, "This page is out of date. — Refresh", never an
//    empty-ranking message), failed (Retry; never an empty list), the
//    settled empty ranking, new listening activity.
//  * Ranks and numbers per card; same-title tracks are two cards (uuid).
//  * Taps: a track asks the controller to play it; an album or artist opens
//    its detail page; an unavailable card does nothing and prompts Refresh.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/listening_stats/listening_ranking_controller.dart';
import 'package:frontend/ui/listening_stats/listening_ranking_page.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';

import '../browse_harness.dart' show teardownTree;
import 'fake_listening_ranking_controls.dart';
import 'stats_model_fakes.dart' show tokenFor;
import 'top_lists_fixtures.dart';

void main() {
  late TopListsHarness h;
  late HistorySnapshotToken token;
  late FakeListeningRankingControls fake;
  final opened = <(StatsRankingKind, HistorySnapshotToken)>[];

  setUp(() async {
    h = TopListsHarness();
    await h.setUp();
    token = tokenFor(StatsRange.last30Days, attribution: 1);
    fake = FakeListeningRankingControls(StatsRankingKind.tracks, token);
    opened.clear();
  });
  tearDown(() => h.tearDown());

  List<Override> overrides() => [
    listeningRankingControllerFactoryProvider.overrideWithValue((kind, t) {
      opened.add((kind, t));
      return fake;
    }),
  ];

  /// Opens the See all page for [kind] directly.
  Future<void> openPage(WidgetTester tester,
      {StatsRankingKind kind = StatsRankingKind.tracks}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(h.browse.wrap(
      ListeningRankingPage(kind: kind, token: token),
      overrides: overrides(),
    ));
    await tester.pump();
  }

  Future<void> show(
    WidgetTester tester, {
    List<StatsRankedCard>? cards,
    bool hasMore = false,
    bool failed = false,
    bool expired = false,
    SnapshotStaleness notice = SnapshotStaleness.fresh,
  }) async {
    fake.show(
      cards: cards,
      hasMore: hasMore,
      failed: failed,
      expired: expired,
      notice: notice,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  final trackCards = lists().tracks;
  const nothingRanked = 'Nothing ranked in this range.';
  final retry = find.widgetWithText(TextButton, 'Retry');

  testWidgets('opening creates one controller for the kind and the given '
      'token; leaving disposes it', (tester) async {
    await openPage(tester);
    expect(opened, hasLength(1));
    expect(opened.single.$1, StatsRankingKind.tracks);
    expect(identical(opened.single.$2, token), isTrue);
    expect(find.text('Top tracks'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget, reason: 'the range shown');
    await teardownTree(tester);
    expect(fake.disposed, isTrue);
  });

  testWidgets('loading shows a spinner and no cards', (tester) async {
    await openPage(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(cardOf('track:t-a'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('a page: cards with rank and numbers; same-title tracks are '
      'two cards', (tester) async {
    await openPage(tester);
    await show(tester, cards: trackCards);
    expect(inCard('track:t-b', '#1'), findsOneWidget);
    expect(inCard('track:t-b', '1 h 1 min · 4 qualified plays'),
        findsOneWidget);
    expect(inCard('track:t-a', '#2'), findsOneWidget);
    expect(inCard('track:t-a', 'Under 1 min · 1 qualified play'),
        findsOneWidget);
    expect(find.text('Same'), findsNWidgets(2));
    expect(find.text(nothingRanked), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('more to come: a trailing loader, and a page that does not '
      'fill the screen asks for more', (tester) async {
    await openPage(tester);
    await show(tester, cards: trackCards, hasMore: true);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(fake.loadMores, greaterThan(0));
    await teardownTree(tester);
  });

  testWidgets('the last page: no loader, no further request', (tester) async {
    await openPage(tester);
    await show(tester, cards: trackCards);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(fake.loadMores, 0);
    await teardownTree(tester);
  });

  testWidgets('the settled empty ranking says so', (tester) async {
    await openPage(tester);
    await show(tester, cards: const []);
    expect(find.text(nothingRanked), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('expired: loaded cards stay, the page says history changed '
      'and offers Refresh; nothing else reloads', (tester) async {
    await openPage(tester);
    await show(tester,
        cards: trackCards,
        expired: true,
        notice: SnapshotStaleness.historyChanged);
    expect(find.text('This page is out of date.'), findsOneWidget);
    expect(cardOf('track:t-a'), findsOneWidget);
    expect(fake.refreshes, 0);
    await tester.tap(find.widgetWithText(TextButton, 'Refresh'));
    await tester.pump();
    expect(fake.refreshes, 1);
    await teardownTree(tester);
  });

  testWidgets('expired before any page: no empty-ranking message',
      (tester) async {
    await openPage(tester);
    await show(tester,
        cards: const [],
        expired: true,
        notice: SnapshotStaleness.historyChanged);
    expect(find.text('This page is out of date.'), findsOneWidget);
    expect(find.text(nothingRanked), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('a failed first page is an error with Retry, not an empty '
      'ranking', (tester) async {
    await openPage(tester);
    await show(tester, failed: true);
    expect(find.text('Couldn’t load.'), findsOneWidget);
    expect(find.text(nothingRanked), findsNothing);
    await tester.tap(retry);
    await tester.pump();
    expect(fake.retries, 1);
    await teardownTree(tester);
  });

  testWidgets('a failed later page keeps the cards and offers Retry at the '
      'end', (tester) async {
    await openPage(tester);
    await show(tester, cards: trackCards, hasMore: true, failed: true);
    expect(cardOf('track:t-b'), findsOneWidget);
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.pump();
    expect(fake.retries, 1);
    await teardownTree(tester);
  });

  testWidgets('new listening activity: a notice with Refresh, cards '
      'unchanged', (tester) async {
    await openPage(tester);
    await show(tester,
        cards: trackCards, notice: SnapshotStaleness.newActivity);
    expect(find.text('New listening activity'), findsOneWidget);
    expect(cardOf('track:t-b'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Refresh'));
    await tester.pump();
    expect(fake.refreshes, 1);
    await teardownTree(tester);
  });

  testWidgets('a track tap asks the controller to play it', (tester) async {
    await openPage(tester);
    await show(tester, cards: trackCards);
    await tester.tap(inCard('track:t-a', 'Same'));
    await tester.pumpAndSettle();
    expect(fake.played, ['t-a']);
    expect(h.browse.audio.calls, isEmpty);
    await teardownTree(tester);
  });

  // Owner decision 5 (2026-11-17), APP-OTHER-1 D5: a track tap whose
  // playback does not start shows the playback message as a notice.
  testWidgets('a track tap that does not start playback says so', (
    tester,
  ) async {
    fake.playOutcome = const RejectedUnplayableOffline();
    await openPage(tester);
    await show(tester, cards: trackCards);
    expect(find.text('Nothing here plays offline.'), findsNothing);
    await tester.tap(inCard('track:t-a', 'Same'));
    await tester.pumpAndSettle();
    expect(fake.played, ['t-a']);
    expect(find.text('Nothing here plays offline.'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('an album tap opens the album', (tester) async {
    fake = FakeListeningRankingControls(StatsRankingKind.albums, token);
    await openPage(tester, kind: StatsRankingKind.albums);
    await show(tester, cards: lists().albums);
    expect(find.text('Top albums'), findsOneWidget);
    await tester.tap(inCard('album:20', 'Two'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Two'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('an artist tap opens the artist', (tester) async {
    fake = FakeListeningRankingControls(StatsRankingKind.artists, token);
    await openPage(tester, kind: StatsRankingKind.artists);
    await show(tester, cards: lists().artists);
    expect(find.text('Top artists'), findsOneWidget);
    await tester.tap(inCard('artist:1', 'Ann'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Ann'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('an unavailable card says so, does not play, and the page '
      'prompts Refresh', (tester) async {
    await openPage(tester);
    await show(tester, cards: lists(tAUnavailable: true).tracks);
    expect(inCard('track:t-a', 'No longer available'), findsOneWidget);
    expect(inCard('track:t-a', '#2'), findsOneWidget);
    await tester.tap(inCard('track:t-a', 'Same'));
    await tester.pumpAndSettle();
    expect(fake.played, isEmpty);
    expect(find.text('Some items are no longer available'), findsOneWidget);
    await teardownTree(tester);
  });

  group('from the statistics page', () {
    testWidgets('See all opens the ranking of that list with the page\'s '
        'snapshot token', (tester) async {
      h.fake.snapshotToken = token;
      fake = FakeListeningRankingControls(StatsRankingKind.artists, token);
      await h.open(tester, lists(), overrides: overrides());
      await tester.tap(find.descendant(
          of: section('artists'), matching: find.text('See all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(opened, hasLength(1));
      expect(opened.single.$1, StatsRankingKind.artists);
      expect(identical(opened.single.$2, token), isTrue,
          reason: 'the same snapshot as the top list');
      expect(find.widgetWithText(AppBar, 'Top artists'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('each non-empty list has See all; an empty one has none',
        (tester) async {
      h.fake.snapshotToken = token;
      await h.open(tester, emptyLists, overrides: overrides());
      expect(find.text('See all'), findsNothing);
      await teardownTree(tester);
    });
  });

  // O-332-13: the cell height (statsRankedCardHeight) leaves room for the
  // rank and numbers lines at large text sizes.
  for (final scale in [2.0, 3.0]) {
    testWidgets('a ranked card at text scale $scale fits its cell',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(h.browse.wrap(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: ListeningRankingPage(
              kind: StatsRankingKind.tracks,
              token: token,
            ),
          ),
        ),
        overrides: overrides(),
      ));
      await tester.pump();
      await show(tester, cards: trackCards);
      expect(tester.takeException(), isNull);
      expect(inCard('track:t-b', '#1'), findsOneWidget);
      expect(inCard('track:t-b', '1 h 1 min · 4 qualified plays'),
          findsOneWidget);
      await teardownTree(tester);
    });
  }

  // O-332-13: a new snapshot (a refresh) shows the ranking from its top.
  testWidgets('a new snapshot starts the grid at the top', (tester) async {
    await openPage(tester);
    final many = [
      for (var i = 1; i <= 60; i++)
        card(ArtistUI(id: i, name: 'Artist $i'), i, 60.0 * (61 - i), 1),
    ];
    await show(tester, cards: many);
    final position = tester
        .state<ScrollableState>(find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        ))
        .position;
    position.jumpTo(800);
    await tester.pump();
    expect(position.pixels, 800);

    fake.show(cards: many, epoch: 1);
    await tester.pump();
    await tester.pump();
    expect(position.pixels, 0);
    await teardownTree(tester);
  });
}
