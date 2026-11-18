// Phase 9A.2a (spec §4 para 2 "opening the page, changing range or
// exporting does not itself create history"; SC-20, SC-27): the real
// controller over a real in-memory database and the real snapshot service,
// repository and freshness watcher. Opening, every range change and
// refresh leave history_events and local_counters exactly as they were,
// and "now" is the injected clock's.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';

import '../../helpers/fake_clock.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final clock = FakeClock(startUtcMs: DateTime.utc(2026, 11, 12, 12).millisecondsSinceEpoch);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
      ],
    );
    await db.into(db.historyEvents).insert(
      HistoryEventsCompanion.insert(
        eventUuid: 'ev-1',
        kind: 'play',
        entityType: 'track',
        entityRef: 'gone-track',
        occurredAt: DateTime.utc(2026, 11, 10).millisecondsSinceEpoch,
        secondsPlayed: const Value(95.5),
        pendingUpload: true,
      ),
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<List<Object?>> historyRows() async => [
    for (final r in await db.customSelect(
      'SELECT * FROM history_events ORDER BY local_id',
    ).get())
      r.data.toString(),
  ];

  Future<List<Object?>> counters() async => [
    for (final r in await db.customSelect(
      'SELECT key, value FROM local_counters ORDER BY key',
    ).get())
      r.data.toString(),
  ];

  /// Waits (bounded, no wall-clock sleep) until the controller settles.
  Future<void> untilSettled(ListeningStatsControls c) async {
    for (var i = 0; i < 200 && c.state is StatsLoading; i++) {
      await pumpEventQueue();
      await Future<void>.delayed(Duration.zero);
    }
    expect(c.state, isNot(isA<StatsLoading>()));
  }

  test('opening, changing range and refreshing create no history', () async {
    final rowsBefore = await historyRows();
    final countersBefore = await counters();

    final c = container.read(listeningStatsControllerFactoryProvider)();
    await untilSettled(c);
    final ready = c.state as StatsReady;
    expect(ready.hasHistory, isTrue);
    expect(ready.stats.capturedNowUtcMs, clock.nowUtcMs());
    expect(ready.stats.totals.listeningSeconds, 95.5);

    for (final range in c.ranges) {
      c.setRange(range);
      await untilSettled(c);
    }
    c.refresh();
    await untilSettled(c);
    expect(c.state, isA<StatsReady>());
    c.dispose();

    expect(await historyRows(), rowsBefore);
    expect(await counters(), countersBefore);
    expect(rowsBefore, hasLength(1));
  });

  test('an empty history loads as "no history", not as a failure', () async {
    await db.customStatement('DELETE FROM history_events');
    final c = container.read(listeningStatsControllerFactoryProvider)();
    await untilSettled(c);
    final ready = c.state as StatsReady;
    expect(ready.hasHistory, isFalse);
    expect(ready.stats.totals.listeningSeconds, 0);
    expect(await historyRows(), isEmpty);
    c.dispose();
    expect(c.range, StatsRange.last7Days);
  });
}
