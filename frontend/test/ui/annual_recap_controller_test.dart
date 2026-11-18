// Phase 9C.1 S6 (spec §6 paragraphs 1–2; SC-10, SC-26): the annual recap
// page controller. The model service is faked with completers, so every
// ordering (late results, failures, dispose) is driven by hand.
// 9-R1-15: the cases for opening with a year and a token, with a token only
// and with a year only were removed with the dead token/year paths.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/services/annual_recap_service.dart';
import 'package:frontend/ui/annual_recap_controller.dart';

int utc(int y, [int m = 1, int d = 1, int h = 0]) =>
    DateTime.utc(y, m, d, h).millisecondsSinceEpoch;

HistorySnapshotToken token(int boundary, int nowMs, {Object key = 'k'}) =>
    HistorySnapshotToken(
      boundaryLocalId: boundary,
      historyContentVersion: 0,
      capturedNowUtcMs: nowMs,
      filterKey: key,
    );

/// A recap of [year] under [t] with [seconds] of listening in January.
AnnualRecap recapOf(int year, HistorySnapshotToken t, {double seconds = 0}) {
  final range = StatsRange.year(year);
  return AnnualRecap.fromStats(
    ListeningStats(
      range: range,
      window: range.resolve(t.capturedNowUtcMs),
      boundaryLocalId: t.boundaryLocalId,
      totals: ListeningTotals(
        listeningSeconds: seconds,
        qualifiedPlays: 0,
        uniqueTracks: 0,
        activeDays: 0,
      ),
      unavailable: const ListeningSubtotal(
        listeningSeconds: 0,
        qualifiedPlays: 0,
      ),
      futureTimestampCount: 0,
      overlongListenCount: 0,
      buckets: [
        ListeningBucket(
          startUtcMs: utc(year),
          endUtcMs: utc(year, 2),
          listeningSeconds: seconds,
        ),
      ],
      chartCapped: false,
      topTracks: const [],
      topArtists: const [],
      topAlbums: const [],
    ),
    t,
  );
}

class FakeRecapService implements AnnualRecapService {
  final snapshots =
      <({int? year, Completer<AnnualRecapSnapshot> done})>[];

  @override
  Future<AnnualRecapSnapshot> snapshot({int? year}) {
    final c = Completer<AnnualRecapSnapshot>();
    snapshots.add((year: year, done: c));
    return c.future;
  }

  // The controller reads only through snapshot().
  @override
  Future<AnnualRecap> load(int year, HistorySnapshotToken token) =>
      throw UnsupportedError('the controller must use snapshot()');

  @override
  Future<List<int>> years(HistorySnapshotToken token) =>
      throw UnsupportedError('the controller must use snapshot()');

  /// Answers a snapshot (the last by default) with a recap of [year] (default:
  /// the year it asked for) under [t]; [years] null = the list failed.
  void answer(
    HistorySnapshotToken t, {
    int? year,
    List<int>? years,
    double seconds = 0,
    int index = -1,
  }) {
    final s = index < 0 ? snapshots.last : snapshots[index];
    s.done.complete(
      AnnualRecapSnapshot(
        recap: recapOf(year ?? s.year!, t, seconds: seconds),
        years: years,
      ),
    );
  }
}

void main() {
  late FakeRecapService service;
  late ProviderContainer container;
  late AnnualRecapControls controller;
  late int notifications;

  final now = utc(2026, 3, 15, 12);

  AnnualRecapControls open() {
    final c = container.read(annualRecapControllerFactoryProvider)();
    c.addListener(() => notifications++);
    return c;
  }

  setUp(() {
    service = FakeRecapService();
    notifications = 0;
    container = ProviderContainer(
      overrides: [annualRecapServiceProvider.overrideWithValue(service)],
    );
  });

  tearDown(() {
    controller.dispose();
    container.dispose();
  });

  group('opening', () {
    test('one snapshot request for the current year; the captured UTC year '
        'is shown once it answers', () async {
      controller = open();
      expect(controller.loading, isTrue);
      expect(controller.recap, isNull);
      expect(controller.year, isNull);
      expect(service.snapshots, hasLength(1));
      expect(service.snapshots.single.year, isNull);

      final t = token(19, now);
      service.answer(t, year: 2026, years: [2026, 2025], seconds: 30);
      await pumpEventQueue();
      expect(service.snapshots, hasLength(1));
      expect(controller.year, 2026);
      expect(controller.loading, isFalse);
      expect(controller.failed, isFalse);
      expect(controller.recap!.year, 2026);
      expect(controller.recap!.token, same(t));
      expect(controller.years, [2026, 2025]);
      expect(notifications, greaterThan(0));
    });
  });

  group('changing the year and refreshing', () {
    late HistorySnapshotToken first;

    setUp(() async {
      first = token(19, now);
      controller = open();
      service.answer(first, year: 2026, years: [2026, 2025], seconds: 10);
      await pumpEventQueue();
    });

    test('another year shows at once and requests a snapshot of it',
        () async {
      controller.selectYear(2025);
      expect(controller.year, 2025);
      expect(controller.loading, isTrue);
      expect(controller.recap, isNull);
      expect(service.snapshots, hasLength(2));
      expect(service.snapshots.last.year, 2025);
      final second = token(21, now + 5000);
      service.answer(second, years: [2026, 2025]);
      await pumpEventQueue();
      expect(controller.recap!.year, 2025);
      expect(controller.recap!.token, same(second));
    });

    test('Refresh requests a new snapshot of the shown year', () async {
      controller.refresh();
      expect(controller.loading, isTrue);
      expect(service.snapshots, hasLength(2));
      expect(service.snapshots.last.year, 2026);
      final second = token(25, now + 9000);
      service.answer(second, years: [2026, 2025], seconds: 99);
      await pumpEventQueue();
      expect(controller.recap!.token, same(second));
      expect(controller.recap!.totals.listeningSeconds, 99);
    });

    test('a slower earlier year never replaces a later choice', () async {
      controller.selectYear(2025);
      controller.selectYear(2024);
      expect(service.snapshots.map((s) => s.year), [null, 2025, 2024]);
      // 2024 answers first, then the stale 2025 snapshot.
      service.answer(token(22, now), index: 2, years: [2026, 2025, 2024]);
      await pumpEventQueue();
      service.answer(token(21, now), index: 1, years: [2026, 2025, 2024]);
      await pumpEventQueue();
      expect(controller.year, 2024);
      expect(controller.recap!.year, 2024);
      expect(controller.recap!.token.boundaryLocalId, 22);
    });

    test('a snapshot answered after a newer choice is ignored', () async {
      controller.selectYear(2025);
      controller.selectYear(2024);
      final before = notifications;
      service.answer(token(21, now), index: 1, years: [2026, 2025]);
      await pumpEventQueue();
      expect(notifications, before);
      expect(controller.recap, isNull);
      expect(controller.loading, isTrue);
      service.answer(token(22, now), index: 2, years: [2026, 2025, 2024]);
      await pumpEventQueue();
      expect(controller.recap!.year, 2024);
    });
  });

  group('failure', () {
    test('a failed snapshot shows an error and retries the same year',
        () async {
      controller = open();
      service.answer(token(19, now), year: 2026, years: [2026, 2025]);
      await pumpEventQueue();
      controller.selectYear(2025);
      service.snapshots.last.done.completeError(StateError('disk'));
      await pumpEventQueue();
      expect(controller.failed, isTrue);
      expect(controller.loading, isFalse);
      expect(controller.recap, isNull);
      expect(controller.year, 2025);

      controller.retry();
      expect(controller.failed, isFalse);
      expect(controller.loading, isTrue);
      expect(service.snapshots, hasLength(3));
      expect(service.snapshots.last.year, 2025);
      service.answer(token(20, now), years: [2026, 2025]);
      await pumpEventQueue();
      expect(controller.failed, isFalse);
      expect(controller.recap!.year, 2025);
    });

    test('a failed first snapshot shows an error and retry asks for the '
        'current year again', () async {
      controller = open();
      service.snapshots.single.done.completeError(StateError('db'));
      await pumpEventQueue();
      expect(controller.failed, isTrue);
      expect(controller.loading, isFalse);
      expect(controller.recap, isNull);
      controller.retry();
      expect(service.snapshots, hasLength(2));
      expect(service.snapshots.last.year, isNull);
      service.answer(token(19, now), year: 2026, years: [2026]);
      await pumpEventQueue();
      expect(controller.recap!.year, 2026);
      expect(controller.failed, isFalse);
    });

    test('a failed year list keeps the recap and offers the shown year',
        () async {
      controller = open();
      service.answer(token(19, now), year: 2025, years: null);
      await pumpEventQueue();
      expect(controller.recap!.year, 2025);
      expect(controller.failed, isFalse);
      expect(controller.years, [2025]);
    });
  });

  group('years to choose from (review F1)', () {
    test('always include the shown year, newest first', () async {
      controller = open();
      service.answer(token(19, now), year: 2023, years: [2026, 2025]);
      await pumpEventQueue();
      expect(controller.years, [2026, 2025, 2023]);
    });

    test('a failed year list after a year change keeps the earlier list',
        () async {
      controller = open();
      service.answer(token(19, now), year: 2026, years: [2026, 2025, 2024]);
      await pumpEventQueue();
      controller.selectYear(2024);
      service.answer(token(20, now), years: null);
      await pumpEventQueue();
      expect(controller.recap!.year, 2024);
      expect(controller.years, [2026, 2025, 2024]);
    });
  });

  test('results arriving after dispose are dropped without notifying',
      () async {
    controller = open();
    controller.dispose();
    final before = notifications;
    service.answer(token(19, now), year: 2025, years: [2025]);
    await pumpEventQueue();
    expect(notifications, before);
  });
}
