// Phase 9A.1 (spec §3, review 9-U07): statistics are SQL aggregates over the
// existing history index, never a Dart-side scan of events. The query plans
// are printed as evidence (9A.1c measures the 100k fixture).
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

import 'listening_stats_workbook.dart';

/// Records every SELECT reaching SQLite with its arguments and row count.
class _Recorder extends QueryInterceptor {
  final selects = <({String sql, List<Object?> args, int rows})>[];
  bool on = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await super.runSelect(executor, statement, args);
    if (on) selects.add((sql: statement, args: args, rows: rows.length));
    return rows;
  }
}

void main() {
  final workbook = Workbook.load();
  late AppDatabase db;
  late _Recorder recorder;
  late ListeningStatsRepository repo;
  final now = workbook.cases.first.capturedNowMs;

  setUp(() async {
    recorder = _Recorder();
    db = AppDatabase(NativeDatabase.memory().interceptWith(recorder));
    await workbook.seed(db);
    repo = ListeningStatsRepository(db, BrowseRepository(db));
  });

  tearDown(() => db.close());

  /// 2000 more listens of the workbook tracks in the last 30 days.
  Future<void> seedMany() => db.batch((b) {
    final tracks = ['t-a', 't-b', 't-c', 't-d', 't-e', 't-gone'];
    for (var i = 0; i < 2000; i++) {
      b.insert(
        db.historyEvents,
        HistoryEventsCompanion.insert(
          eventUuid: 'bulk-$i',
          kind: 'play',
          entityType: 'track',
          entityRef: tracks[i % tracks.length],
          occurredAt: now - 1000 - i * 1200000,
          secondsPlayed: const Value(31.0),
          trackLength: const Value(200.0),
          pendingUpload: false,
        ),
      );
    }
  });

  Future<List<({String sql, List<Object?> args, int rows})>> record(
    StatsRange range,
  ) async {
    recorder
      ..selects.clear()
      ..on = true;
    await repo.load(range, 1 << 40, now);
    recorder.on = false;
    return List.of(recorder.selects);
  }

  for (final (name, range) in [
    ('30 days', StatsRange.last30Days),
    ('year 2025', StatsRange.year(2025)),
    ('all time', StatsRange.allTime),
  ]) {
    test('$name: a fixed number of grouped queries, none returning events '
        '(no Dart-side scan, no per-card lookup)', () async {
      final small = await record(range);
      await seedMany();
      final large = await record(range);
      expect(large.length, small.length,
          reason: 'statement count does not grow with history');
      for (final s in large) {
        expect(s.rows, lessThanOrEqualTo(31),
            reason: 'at most one row per bucket or ranked entity:\n${s.sql}');
      }
    });
  }

  test('every history query uses the existing kind/occurred_at index', () async {
    await seedMany();
    final statements = await record(StatsRange.last30Days);
    final history = statements.where((s) => s.sql.contains('history_events'));
    expect(history, isNotEmpty);
    for (final s in history) {
      final plan = await db
          .customSelect(
            'EXPLAIN QUERY PLAN ${s.sql}',
            variables: [for (final a in s.args) Variable(a)],
          )
          .get();
      final details = [for (final r in plan) r.read<String>('detail')];
      // Evidence for the progress log and 9A.1b's index decision.
      // ignore: avoid_print
      print('PLAN ${s.sql}\n  ${details.join('\n  ')}');
      expect(
        details.any(
          (d) =>
              d.contains('history_events') &&
              d.contains('idx_history_events_kind_occurred'),
        ),
        isTrue,
        reason: 'history_events read through the kind index:\n$details',
      );
      expect(
        details.where((d) => d.startsWith('SCAN history_events')),
        isEmpty,
        reason: 'no full table scan of history_events:\n$details',
      );
    }
  });
}
