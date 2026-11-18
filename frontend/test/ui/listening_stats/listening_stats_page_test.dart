// Phase 9A.2a (spec §4 para 1; brief "three states that must never be
// confused"; SC-26; review 9-U02 presentation): the statistics page renders
// only what `ListeningStatsControls` says and forwards every input to it.
//
//  * No listening history at all: zero summaries plus the empty copy.
//  * History, but none in the range: zeros shown as zeros, no copy, the
//    range still selectable.
//  * A failed load: an error with Retry, no zeros, the range kept.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';

import '../browse_harness.dart' show teardownTree;
import 'stats_page_harness.dart';

const _emptyCopy = 'Play music to start building your listening history';
const _errorCopy = 'Couldn’t load listening stats.';
final _spinner = find.byType(CircularProgressIndicator);
final _retry = find.widgetWithText(TextButton, 'Retry');

ChoiceChip _chip(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

void main() {
  late StatsPageHarness h;
  setUp(() => h = StatsPageHarness());
  tearDown(() => h.close());

  testWidgets('opening creates one controller; leaving disposes it',
      (tester) async {
    await h.open(tester);
    expect(h.created, 1);
    expect(find.text('Listening stats'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(h.fake.disposed, isTrue);
    await teardownTree(tester);
  });

  testWidgets('loading shows a spinner under a usable range selector',
      (tester) async {
    await h.open(tester);
    expect(_spinner, findsOneWidget);
    for (final label in ['7 days', '30 days', 'This year', 'All time']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
    }
    // The page opens on 7 days (sign-off DEV-9-15 item 9).
    expect(_chip(tester, '7 days').selected, isTrue);
    expect(_chip(tester, '30 days').selected, isFalse);
    expect(find.text(_emptyCopy), findsNothing);
    expect(find.text(_errorCopy), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('the range chips show the chosen range and forward taps',
      (tester) async {
    await h.open(tester);
    await h.show(tester, StatsReady(sevenDays(), hasHistory: true, pendingListens: 0),
        range: StatsRange.last7Days);
    expect(_chip(tester, '7 days').selected, isTrue);
    expect(_chip(tester, '30 days').selected, isFalse);
    await tester.tap(find.widgetWithText(ChoiceChip, 'All time'));
    await tester.pump();
    expect(h.fake.rangeTaps, [StatsRange.allTime]);
    await teardownTree(tester);
  });

  testWidgets('the Refresh action forwards', (tester) async {
    await h.open(tester);
    await h.show(tester, StatsReady(sevenDays(), hasHistory: true, pendingListens: 0));
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    expect(h.fake.refreshes, 1);
    await teardownTree(tester);
  });

  testWidgets('the four summaries show the snapshot\'s values',
      (tester) async {
    await h.open(tester);
    await h.show(
      tester,
      StatsReady(
        sevenDays(seconds: 3660.9, plays: 12, tracks: 5, days: 3),
        hasHistory: true, pendingListens: 0,
      ),
      range: StatsRange.last7Days,
    );
    expect(summaryValue('time', '1 h 1 min'), findsOneWidget);
    expect(summaryValue('plays', '12'), findsOneWidget);
    expect(summaryValue('tracks', '5'), findsOneWidget);
    expect(summaryValue('days', '3'), findsOneWidget);
    expect(find.text('Listening time'), findsWidgets);
    expect(find.text('Qualified plays'), findsOneWidget);
    expect(find.text('Unique tracks'), findsOneWidget);
    expect(find.text('Active days'), findsOneWidget);
    await teardownTree(tester);
  });

  group('three distinct states', () {
    testWidgets('no history at all: zeros and the empty copy',
        (tester) async {
      await h.open(tester);
      await h.show(tester, StatsReady(sevenDays(), hasHistory: false, pendingListens: 0));
      expect(find.text(_emptyCopy), findsOneWidget);
      expect(summaryValue('time', '0 min'), findsOneWidget);
      expect(summaryValue('plays', '0'), findsOneWidget);
      expect(summaryValue('tracks', '0'), findsOneWidget);
      expect(summaryValue('days', '0'), findsOneWidget);
      expect(find.text(_errorCopy), findsNothing);
      expect(_retry, findsNothing);
      expect(_spinner, findsNothing);
      await teardownTree(tester);
    });

    testWidgets('history but none in the range: zeros, no empty copy, the '
        'range still selectable', (tester) async {
      await h.open(tester);
      await h.show(tester, StatsReady(sevenDays(), hasHistory: true, pendingListens: 0),
          range: StatsRange.last7Days);
      expect(find.text(_emptyCopy), findsNothing);
      expect(summaryValue('time', '0 min'), findsOneWidget);
      expect(summaryValue('plays', '0'), findsOneWidget);
      expect(find.text(_errorCopy), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '30 days'));
      await tester.pump();
      expect(h.fake.rangeTaps, [StatsRange.last30Days]);
      await teardownTree(tester);
    });

    // Part B's shared notice sits inside the page's list, which already
    // ends above the shell's bottom chrome: the notice adds no second gap.
    testWidgets('a failed load inside the shell: the bottom chrome gap is '
        'added once, by the page', (tester) async {
      const inset = 150.0;
      await h.open(tester, bottomInset: inset);
      await h.show(tester, const StatsFailed(), range: StatsRange.thisUtcYear);
      final notice = tester.getRect(find.byType(LoadFailureNotice));
      final retry = tester.getRect(_retry);
      expect(notice.bottom - retry.bottom, 32,
          reason: "only the notice's own padding below Retry");
      await teardownTree(tester);
    });

    testWidgets('a failed load: an error with Retry, never zeros, the range '
        'kept', (tester) async {
      await h.open(tester);
      await h.show(tester, const StatsFailed(), range: StatsRange.thisUtcYear);
      expect(find.text(_errorCopy), findsOneWidget);
      expect(_retry, findsOneWidget);
      expect(find.byKey(const ValueKey('stats-summary-time')), findsNothing);
      expect(find.text('0 min'), findsNothing);
      expect(find.text(_emptyCopy), findsNothing);
      expect(_chip(tester, 'This year').selected, isTrue);
      await tester.tap(_retry);
      await tester.pump();
      expect(h.fake.retries, 1);
      expect(h.fake.rangeTaps, isEmpty);
      await teardownTree(tester);
    });
  });
}
