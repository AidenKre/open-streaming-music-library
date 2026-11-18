// Phase 9A.2a (spec §3 para 3 "background changes do not reorder rankings
// under a tap … Maintain current total snapshot until refresh"; SC-10
// "New listening activity — Refresh"; spec §4 sync freshness/pending-upload
// indicator): the stale notice only offers a refresh, and what is on
// screen stays exactly as it was until the user takes it. The sync
// indicator observes the history diagnostics and claims nothing while
// they are unknown.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/services/history/history_diagnostics.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';

import '../browse_harness.dart' show teardownTree;
import 'stats_page_harness.dart';

final _content = find.byKey(const ValueKey('stats-content'));

void main() {
  late StatsPageHarness h;
  setUp(() => h = StatsPageHarness());
  tearDown(() => h.close());

  group('stale notice', () {
    testWidgets('new plays: "New listening activity" with Refresh, and the '
        'shown values do not change', (tester) async {
      final ready = StatsReady(
        sevenDays(seconds: 4000, plays: 7, tracks: 3, days: 2,
            buckets: [0, 1, 2, 3, 4, 5, 6, 7]),
        hasHistory: true, pendingListens: 0,
      );
      await h.open(tester);
      await h.show(tester, ready, range: StatsRange.last7Days);
      expect(find.byType(NewActivityNotice), findsNothing);
      final before = textsUnder(tester, _content);
      expect(before, isNotEmpty);

      await h.show(tester, ready,
          range: StatsRange.last7Days, notice: SnapshotStaleness.newActivity);
      final notice = find.byType(NewActivityNotice);
      expect(notice, findsOneWidget);
      expect(
        find.descendant(of: notice, matching: find.text('New listening activity')),
        findsOneWidget,
      );
      expect(textsUnder(tester, _content), before,
          reason: 'the notice never changes or reorders what is shown');
      expect(h.fake.refreshes, 0, reason: 'it never refreshes by itself');

      await tester.tap(
        find.descendant(of: notice, matching: find.text('Refresh')),
      );
      await tester.pump();
      expect(h.fake.refreshes, 1);
      await teardownTree(tester);
    });

    testWidgets('a changed history says so', (tester) async {
      await h.open(tester);
      await h.show(tester, StatsReady(sevenDays(), hasHistory: true, pendingListens: 0),
          notice: SnapshotStaleness.historyChanged);
      expect(
        find.descendant(
          of: find.byType(NewActivityNotice),
          matching: find.text('This page is out of date.'),
        ),
        findsOneWidget,
      );
      await teardownTree(tester);
    });
  });

  group('sync indicator', () {
    Future<void> diagnose(WidgetTester tester, HistoryDiagnostics d) async {
      h.diagnostics.add(d);
      await tester.pump();
      await tester.pump();
    }

    StatsReady ready({int pending = 0}) =>
        StatsReady(sevenDays(), hasHistory: true, pendingListens: pending);

    testWidgets('the snapshot\'s unsent listens are counted and said to be '
        'included (review r1 F2)', (tester) async {
      await h.open(tester);
      await h.show(tester, ready(pending: 3));
      // Known from the snapshot even before the diagnostics arrive.
      expect(
        find.text('Includes 3 listens from this device not uploaded yet.'),
        findsOneWidget,
      );
      await h.show(tester, ready(pending: 1));
      expect(
        find.text('Includes 1 listen from this device not uploaded yet.'),
        findsOneWidget,
      );
      await teardownTree(tester);
    });

    testWidgets('unsent clicks are not reported as listens (review r1 F2)',
        (tester) async {
      await h.open(tester);
      await h.show(tester, ready());
      await diagnose(tester, const HistoryDiagnostics(pending: 4));
      expect(find.textContaining('Includes'), findsNothing);
      expect(
        find.text('All listens from this device are uploaded.'),
        findsOneWidget,
      );
      await teardownTree(tester);
    });

    testWidgets('everything uploaded is said only when known', (tester) async {
      await h.open(tester);
      await h.show(tester, ready());
      // Diagnostics not known yet: no claim either way.
      expect(find.textContaining('uploaded'), findsNothing);
      await diagnose(tester, const HistoryDiagnostics());
      expect(
        find.text('All listens from this device are uploaded.'),
        findsOneWidget,
      );
      await teardownTree(tester);
    });

    testWidgets('a sync problem warns that other devices may be missing',
        (tester) async {
      await h.open(tester);
      await h.show(tester, ready());
      for (final d in const [
        HistoryDiagnostics(lastError: 'boom'),
        HistoryDiagnostics(quarantined: 2),
        HistoryDiagnostics(frozenListens: 1), // review r1 F3
        HistoryDiagnostics(listenError: 'x'), // review r1 F3
      ]) {
        await diagnose(tester, d);
        expect(find.textContaining('may be missing'), findsOneWidget);
        expect(find.textContaining('are uploaded'), findsNothing);
      }
      await diagnose(tester, const HistoryDiagnostics());
      expect(find.textContaining('may be missing'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a server without history sync: only this device',
        (tester) async {
      await h.open(tester);
      await h.show(tester, ready());
      await diagnose(
        tester,
        const HistoryDiagnostics(waitingForServerSupport: true),
      );
      expect(find.textContaining('only this device'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('a failed diagnostics read claims nothing', (tester) async {
      await h.open(tester);
      await h.show(tester, ready());
      h.diagnostics.addError(StateError('db'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('uploaded'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a diagnostics error after a value drops the old claim '
        '(review r1 F6)', (tester) async {
      await h.open(tester);
      await h.show(tester, ready());
      await diagnose(tester, const HistoryDiagnostics());
      expect(find.textContaining('are uploaded'), findsOneWidget);
      h.diagnostics.addError(StateError('db'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('are uploaded'), findsNothing);
      await teardownTree(tester);
    });
  });
}
