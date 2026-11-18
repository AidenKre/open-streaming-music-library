// Shared set-up of the statistics page widget tests: the page pushed on a
// navigator (so it has a back button) over a fake controller, with the
// history diagnostics the sync indicator observes supplied by the test.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/services/history/history_diagnostics.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';
import 'package:frontend/ui/listening_stats_page.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';

import '../fake_listening_stats_controls.dart';
import '../../helpers/listening_stats_builder.dart';

const day = 86400000;

/// 12 Nov 2026 14:03 UTC.
final capturedNow = DateTime.utc(2026, 11, 12, 14, 3).millisecondsSinceEpoch;

/// A 7-day snapshot (8 UTC day buckets) with the given totals.
ListeningStats sevenDays({
  double seconds = 0,
  int plays = 0,
  int tracks = 0,
  int days = 0,
  double unavailableSeconds = 0,
  int unavailablePlays = 0,
  int future = 0,
  List<double>? buckets,
  StatsRange range = StatsRange.last7Days,
  bool capped = false,
}) {
  final window = range.resolve(capturedNow);
  final plan = window.bucketPlan(
    earliestListenUtcMs: DateTime.utc(2020).millisecondsSinceEpoch,
  );
  final values = buckets ?? List<double>.filled(plan.spans.length, 0);
  return listeningStatsOf(
    range: range,
    window: window,
    boundaryLocalId: 10,
    seconds: seconds,
    qualifiedPlays: plays,
    uniqueTracks: tracks,
    activeDays: days,
    unavailableSeconds: unavailableSeconds,
    unavailablePlays: unavailablePlays,
    futureTimestampCount: future,
    buckets: [
      for (var i = 0; i < values.length && i < plan.spans.length; i++)
        ListeningBucket(
          startUtcMs: plan.spans[i].startUtcMs,
          endUtcMs: plan.spans[i].endUtcMs,
          listeningSeconds: values[i],
        ),
    ],
    chartCapped: capped,
  );
}

class StatsPageHarness {
  StatsPageHarness();

  final fake = FakeListeningStatsControls();
  int created = 0;
  final diagnostics = StreamController<HistoryDiagnostics>.broadcast();

  /// Pumps a root page with a button that pushes the statistics page, and
  /// opens it.
  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(800, 2400),
    double textScale = 1,
    double bottomInset = 0,
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          listeningStatsControllerFactoryProvider.overrideWithValue(() {
            created++;
            return fake;
          }),
          historyDiagnosticsProvider.overrideWith(
            (ref) => diagnostics.stream,
          ),
          ...overrides,
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          // Like a shell tab: the insets sit above the tab's own navigator.
          home: ShellChromeInsets(
            top: 0,
            bottom: bottomInset,
            child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ListeningStatsPage(),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> show(
    WidgetTester tester,
    ListeningStatsState state, {
    StatsRange? range,
    notice,
  }) async {
    if (notice == null) {
      fake.show(state, range: range);
    } else {
      fake.show(state, range: range, notice: notice);
    }
    await tester.pump();
  }

  Future<void> close() => diagnostics.close();
}

/// The text of the summary tile [id] (`time`, `plays`, `tracks`, `days`).
Finder summaryValue(String id, String text) => find.descendant(
  of: find.byKey(ValueKey('stats-summary-$id')),
  matching: find.text(text),
);

/// Every text under [root], in tree order.
List<String> textsUnder(WidgetTester tester, Finder root) => [
  for (final t in tester.widgetList<Text>(
    find.descendant(of: root, matching: find.byType(Text)),
  ))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];
