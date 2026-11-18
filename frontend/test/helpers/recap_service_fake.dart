// A fake AnnualRecapService whose snapshots the test answers by hand, and
// the recap and token it answers with (moved here from
// annual_recap_controller_test.dart, APP-TEST stage 2).
import 'dart:async';

import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/services/annual_recap_service.dart';

import 'listening_stats_builder.dart';

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
    listeningStatsOf(
      range: range,
      window: range.resolve(t.capturedNowUtcMs),
      boundaryLocalId: t.boundaryLocalId,
      seconds: seconds,
      buckets: [
        ListeningBucket(
          startUtcMs: utc(year),
          endUtcMs: utc(year, 2),
          listeningSeconds: seconds,
        ),
      ],
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
