// Phase 9A.2a review r1 F1 (shell insets) and spec §3 para 3 ("Range
// changes … reset page scroll"): the page is pushed on a shell tab's
// navigator, so its last item must end above the bottom chrome, and a new
// range starts at the top.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';

import '../browse_harness.dart' show teardownTree;
import 'stats_page_harness.dart';

void main() {
  late StatsPageHarness h;
  setUp(() => h = StatsPageHarness());
  tearDown(() => h.close());

  final full = StatsReady(
    sevenDays(seconds: 3600, plays: 3, buckets: List.filled(8, 600)),
    hasHistory: true, pendingListens: 0,
  );

  testWidgets('the last item ends above the shell bottom chrome',
      (tester) async {
    const inset = 150.0;
    await h.open(tester, size: const Size(400, 800), bottomInset: inset);
    await h.show(tester, full, range: StatsRange.last7Days);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
    await tester.pumpAndSettle();
    final about = tester.getRect(find.text('About these numbers'));
    expect(about.bottom, lessThanOrEqualTo(800 - inset));
    await teardownTree(tester);
  });

  testWidgets('a range change starts the page at the top', (tester) async {
    await h.open(tester, size: const Size(400, 800));
    await h.show(tester, full, range: StatsRange.last7Days);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
    await tester.pumpAndSettle();
    expect(find.text('7 days').hitTestable(), findsNothing);
    await h.show(tester, full, range: StatsRange.last30Days);
    await tester.pumpAndSettle();
    expect(find.text('7 days').hitTestable(), findsOneWidget);
    await teardownTree(tester);
  });
}
